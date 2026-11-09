"""Tests for the streaming speech client (htts_stream): gains, limiter, gate, FIFO and the full run.

The end-to-end tests talk to a small in-process HTTP server that streams chunked PCM the way the
real tts-server does (and can stall, go silent, die or run away), and read the FIFO like mpv.
"""

import array  # Typed sample buffers for the test tones.
import errno  # EAGAIN of the non-blocking FIFO reader.
import http.server  # The in-process fake tts-server.
import math  # Sine tones and decibel maths.
import os  # FIFOs and file descriptors.
import stat  # Telling a regular file from a FIFO.
import threading  # Server and FIFO reader threads.
import time  # Delays and timing limits.

import htts_stream  # The module under test (lib/py is on the path via conftest).
import pytest  # Test framework.


def tone(seconds, amplitude=0.3, rate=24000):
    """Build raw s16le tone samples.

    Args:
        seconds: Length of the tone.
        amplitude: Peak amplitude 0..1 (0 gives silence).
        rate: Sample rate.

    Returns:
        array('h') of samples.
    """
    # A 220 Hz sine: speech-like enough for the loudness maths and clearly non-silent.
    return array.array("h", [
        int(amplitude * 32767 * math.sin(2 * math.pi * 220 * i / rate))
        for i in range(int(rate * seconds))])


class FakeServer:
    """In-process HTTP server answering /v1/audio/speech with a configurable PCM stream."""

    def __init__(self, samples, mode="ok", first_delay=0.0, frame_gap=0.0):
        """Start serving on a free loopback port.

        Args:
            samples: array('h') of audio to stream.
            mode: ok | http500 | die (cut after half) | hang (stop after half, keep open).
            first_delay: Seconds before the first byte.
            frame_gap: Seconds between 80 ms frames.

        Returns:
            None.
        """
        # The behaviour switches the handler reads for every request.
        self.samples, self.mode = samples, mode
        self.first_delay, self.frame_gap = first_delay, frame_gap
        # Set when a write failed because the client closed the connection.
        self.client_gone = threading.Event()
        owner = self

        class Handler(http.server.BaseHTTPRequestHandler):
            """Request handler bound to the owning FakeServer."""

            def log_message(self, *_args):
                """Silence the default access log."""

            def do_POST(self):
                """Stream the configured answer."""
                self.rfile.read(int(self.headers.get("Content-Length", "0")))
                owner.stream(self)

        # Port 0 lets the kernel pick a free port, so parallel test runs never collide.
        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.port = self.httpd.server_address[1]
        # A daemon thread dies with the test run even if a test forgets close().
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def stream(self, handler):
        """Write the answer for one request.

        Args:
            handler: The request handler to write to.

        Returns:
            None.
        """
        time.sleep(self.first_delay)
        # An error envelope instead of audio, like the real server before the first frame.
        if self.mode == "http500":
            # The envelope is small, so one Content-Length response carries it.
            payload = b'{"error":"boom"}'
            handler.send_response(500)
            handler.send_header("Content-Length", str(len(payload)))
            handler.end_headers()
            # Body last, then nothing more to say for this request.
            handler.wfile.write(payload)
            return
        # A good answer: headers first, then audio of unknown length as chunks.
        handler.send_response(200)
        handler.send_header("Transfer-Encoding", "chunked")
        handler.end_headers()
        # One 80 ms frame (1920 samples, two bytes each) per HTTP chunk.
        data = self.samples.tobytes()
        step = 1920 * 2
        # One 80 ms frame per chunk; a write error means the client closed the connection.
        for offset in range(0, len(data), step):
            frame = data[offset:offset + step]
            # Chunked framing: hex length, CRLF, data, CRLF.
            try:
                handler.wfile.write(b"%x\r\n" % len(frame) + frame + b"\r\n")
                handler.wfile.flush()
            except OSError:
                # The client closed the connection: remember it for the test and stop.
                self.client_gone.set()
                return
            # Halfway through, the failure modes strike.
            if offset + step >= len(data) // 2 and self.mode in ("die", "hang"):
                # die: close without the terminating chunk; hang: just stop sending.
                if self.mode == "die":
                    handler.connection.close()
                else:
                    time.sleep(30)
                return
            # The gap between frames makes the stream arrive in "real time".
            time.sleep(self.frame_gap)
        # The zero-length chunk ends a complete stream.
        handler.wfile.write(b"0\r\n\r\n")

    def close(self):
        """Stop the server.

        Returns:
            None.
        """
        self.httpd.shutdown()
        self.httpd.server_close()


class FifoReader:
    """Reads a FIFO on a thread, like mpv does, and records what arrived."""

    def __init__(self, path):
        """Open the read end (non-blocking, so no writer is needed yet) and start reading.

        Args:
            path: FIFO path.

        Returns:
            None.
        """
        # Opening non-blocking succeeds without a writer, which is what mpv relies on.
        self.fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
        self.data = bytearray()
        # eof is set when the writer closed after having written; stop ends the thread early.
        self.eof = threading.Event()
        self.stop = False
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()

    def run(self):
        """Read until the writer closed after having written, or until stopped.

        Returns:
            None.
        """
        seen_data = False
        # Non-blocking reads: EAGAIN = nothing yet; b"" after data = the writer closed.
        while not self.stop:
            try:
                chunk = os.read(self.fd, 65536)
            except OSError as error:
                # EAGAIN only means "nothing yet"; any other error ends the reader.
                if error.errno != errno.EAGAIN:
                    break
                chunk = None
            # Data is recorded; an empty read after data means the writer closed.
            if chunk:
                self.data.extend(chunk)
                seen_data = True
            elif chunk == b"" and seen_data:
                # The writer closed its end: report end-of-file and stop.
                self.eof.set()
                break
            # Polling at 5 ms keeps the reader responsive without a busy loop.
            time.sleep(0.005)

    def close(self):
        """Stop reading and close the read end.

        Returns:
            None.
        """
        self.stop = True
        # The reader thread must be gone before its descriptor is closed.
        self.thread.join(timeout=2)
        os.close(self.fd)


def run_args(tmp_path, port, **overrides):
    """Build the helper's parsed arguments for a run against the fake server.

    Args:
        tmp_path: Directory for the entry, body and gain table.
        port: Server port.
        **overrides: Option values replacing the defaults (e.g. runaway_seconds).

    Returns:
        The parsed namespace.
    """
    # The helper only forwards the body file to the server, whose content is irrelevant here.
    body = tmp_path / "body.json"
    body.write_text("{}", encoding="utf-8")
    argv = ["stream", str(tmp_path / "s00000.pcm"), "--port", str(port), "--body", str(body),
            "--voice", "ryan", "--gains", str(tmp_path / "gains"), "--start-timeout", "1",
            "--idle-timeout", "1"]
    args = htts_stream.parse_args(argv)
    # Overrides replace parsed values (floats for timeouts, flags) without re-parsing strings.
    for key, value in overrides.items():
        setattr(args, key, value)
    return args


def read_copy(entry):
    """Read the finished copy, failing (instead of blocking) when the entry is still a FIFO.

    Args:
        entry: Playlist entry path.

    Returns:
        The file content as bytes.
    """
    # Opening a FIFO for reading would hang the test run forever, so the type is checked first.
    assert stat.S_ISREG(os.stat(entry).st_mode), "entry was not replaced by the copy"
    with open(entry, "rb") as handle:
        return handle.read()


def rms_db(samples):
    """Return the RMS level of samples in dBFS.

    Args:
        samples: array('h').

    Returns:
        Level in dB relative to full scale.
    """
    energy = sum(v * v for v in samples) / len(samples) / 32768.0 ** 2
    return 10 * math.log10(energy)


def test_gain_table_roundtrip_and_blending(tmp_path):
    """Gains are stored per voice, the first value is taken as is, later ones are averaged."""
    path = str(tmp_path / "state" / "gains")
    # No file yet: an empty table, and the first measurement is stored as is.
    assert htts_stream.read_gains(path) == {}
    assert htts_stream.learn_gain(path, "ryan", 8.0) == 8.0
    # Half-way between the stored 8 dB and the new 4 dB measurement.
    assert htts_stream.learn_gain(path, "ryan", 4.0) == pytest.approx(6.0)
    # A second voice has its own entry, and the file keeps both.
    assert htts_stream.learn_gain(path, "aiden", -3.0) == -3.0
    assert htts_stream.read_gains(path) == {"ryan": 6.0, "aiden": -3.0}


def test_gain_table_ignores_garbage_and_clamps(tmp_path):
    """A damaged line costs one voice, not the table; stored gains stay within the file gate's range."""
    path = tmp_path / "gains"
    path.write_text("ryan\t5.5\nbroken line\nlili\tnot-a-number\n", encoding="utf-8")
    # Only the well-formed line survives.
    assert htts_stream.read_gains(str(path)) == {"ryan": 5.5}
    # Extreme measurements are clamped to the file gate's range.
    assert htts_stream.learn_gain(str(path), "loud", 99.0) == htts_stream.htts_wav.MAX_GAIN_DB
    assert htts_stream.learn_gain(str(path), "soft", -99.0) == htts_stream.htts_wav.MIN_GAIN_DB


def test_unwritable_state_directory_is_not_fatal(tmp_path):
    """Learning is an optimisation: a read-only state path must not raise."""
    blocker = tmp_path / "file"
    blocker.write_text("x", encoding="utf-8")
    # The "directory" of the gain file is a regular file, so makedirs fails.
    htts_stream.write_gains(str(blocker / "gains"), {"ryan": 1.0})


def gain_args(tmp_path, voice="de-thorsten", default_gain_db=htts_stream.DEFAULT_GAIN_DB,
              no_gain=False):
    """Build the parsed command line that first_use_gain reads.

    Args:
        tmp_path: pytest temporary directory (holds the gain table).
        voice: Voice name.
        default_gain_db: Value of ``--default-gain-db``.
        no_gain: Value of ``--no-gain``.

    Returns:
        The parsed namespace.
    """
    # The same parser the command line uses, so flag names cannot drift apart.
    argv = ["stream", str(tmp_path / "entry"), "--port", "1", "--body", "b", "--voice", voice,
            "--gains", str(tmp_path / "gains"), f"--default-gain-db={default_gain_db}"]
    return htts_stream.parse_args(argv + (["--no-gain"] if no_gain else []))


def test_first_use_gain_prefers_learned_then_calibrated_then_builtin(tmp_path):
    """Learned value > the voice's calibrated gain_db > +6 dB."""
    # Nothing learned: the calibrated gain passed by the caller is used.
    assert htts_stream.first_use_gain(gain_args(tmp_path, default_gain_db=10.4)) == 10.4
    # Without a calibrated gain the built-in default applies.
    assert htts_stream.first_use_gain(gain_args(tmp_path)) == htts_stream.DEFAULT_GAIN_DB == 6.0
    # A learned value wins over the calibrated one.
    htts_stream.learn_gain(str(tmp_path / "gains"), "de-thorsten", 3.0)
    assert htts_stream.first_use_gain(gain_args(tmp_path, default_gain_db=10.4)) == 3.0
    # Another voice is not affected by it.
    assert htts_stream.first_use_gain(gain_args(tmp_path, voice="en-lj", default_gain_db=1.7)) == 1.7


def test_first_use_gain_is_zero_without_normalisation_and_rejects_nonsense(tmp_path):
    """--no-gain plays untouched; nan, inf and absurd values never reach the samples."""
    # Normalisation off: no gain at all, whatever else is given.
    assert htts_stream.first_use_gain(gain_args(tmp_path, default_gain_db=9, no_gain=True)) == 0.0
    # A number that is not finite falls back to the built-in default.
    for text in ("nan", "inf", "-inf"):
        assert htts_stream.first_use_gain(gain_args(tmp_path, default_gain_db=text)) == 6.0
    # Finite but extreme values are held to the file gate's bounds.
    assert htts_stream.first_use_gain(gain_args(tmp_path, default_gain_db=80)) == 14.0
    assert htts_stream.first_use_gain(gain_args(tmp_path, default_gain_db=-80)) == -12.0


def test_scale_samples_gain_and_limiter():
    """Gain doubles small samples; loud ones are compressed, never wrapped or clipped hard."""
    quiet = array.array("h", [1000, -1000])
    # Zero gain returns the samples untouched; +6.02 dB doubles them.
    assert list(htts_stream.scale_samples(quiet, 0.0)) == [1000, -1000]
    boosted = htts_stream.scale_samples(quiet, 6.0206)
    assert abs(boosted[0] - 2000) <= 1 and abs(boosted[1] + 2000) <= 1
    # +12 dB on loud samples would overflow 16 bits without the limiter.
    loud = array.array("h", [20000, -20000, 32767, -32768])
    limited = htts_stream.scale_samples(loud, 12.0)
    assert all(-32768 <= v <= 32767 for v in limited)
    # Symmetric and monotonic: louder in, louder (or equal) out.
    assert limited[0] == -limited[1] and limited[2] >= limited[0] > htts_stream.LIMITER_KNEE


def test_gate_holds_silence_and_releases_it_with_the_speech():
    """Leading silence is held back and delivered in front of the first audible block."""
    gate = htts_stream.AudibleGate()
    silence = array.array("h", [0] * 2400)
    # Silence alone is held back.
    assert len(gate.push(silence)) == 0
    # The first audible block releases the silence in front of it, in order.
    speech = tone(0.1)
    released = gate.push(speech)
    assert len(released) == len(silence) + len(speech)
    # Open now: later blocks pass through unchanged.
    assert len(gate.push(silence)) == len(silence)


def test_gate_gives_up_on_long_silence():
    """More than the hold time of pure silence means a silent render."""
    gate = htts_stream.AudibleGate()
    # 20 blocks of 0.1 s are twice the 1 s hold limit.
    block = array.array("h", [0] * 2400)
    with pytest.raises(htts_stream.StreamFailure):
        for _ in range(20):
            gate.push(block)


def test_tee_streams_into_a_late_reader_and_replaces_the_fifo(tmp_path):
    """Audio written before mpv attaches is flushed first; finish() swaps the FIFO for the copy."""
    entry = str(tmp_path / "s00000.pcm")
    os.mkfifo(entry)
    tee = htts_stream.Tee(entry)
    # The first audio is written before any reader exists (mpv still starting).
    tee.write(b"\x01\x00" * 100)
    reader = FifoReader(entry)
    # The next write attaches the reader and flushes the backlog in front of the new data.
    tee.write(b"\x02\x00" * 100)
    tee.finish()
    assert reader.eof.wait(3)
    # The reader saw both blocks in order, then end-of-file.
    assert bytes(reader.data) == b"\x01\x00" * 100 + b"\x02\x00" * 100
    reader.close()
    assert os.path.isfile(entry) and not os.path.exists(entry + ".part")
    assert read_copy(entry) == b"\x01\x00" * 100 + b"\x02\x00" * 100


def test_tee_survives_a_reader_that_left(tmp_path):
    """When mpv closes its end early the copy still completes and nothing raises."""
    entry = str(tmp_path / "s00000.pcm")
    os.mkfifo(entry)
    tee = htts_stream.Tee(entry)
    # The reader is attached from the start, like an mpv that opened the FIFO at once.
    reader = FifoReader(entry)
    # One block reaches the reader, then the reader leaves (mpv skipped or stopped).
    tee.write(b"\x01\x00" * 50)
    time.sleep(0.1)
    reader.close()
    # Writing on must neither raise nor lose data in the copy.
    tee.write(b"\x02\x00" * 50)
    tee.write(b"\x03\x00" * 50)
    # Finishing swaps the copy in; all 300 bytes must be in it (checked below).
    tee.finish()
    assert len(read_copy(entry)) == 300


def test_tee_abort_removes_the_partial_copy(tmp_path):
    """An aborted stream leaves no copy; the FIFO name stays for the caller to remove."""
    entry = str(tmp_path / "s00000.pcm")
    os.mkfifo(entry)
    # A Tee that never received audio is aborted.
    tee = htts_stream.Tee(entry)
    tee.abort()
    # The partial copy is gone, while the FIFO name is left for the caller to remove.
    assert not os.path.exists(entry + ".part")
    assert os.path.exists(entry)


def test_full_run_plays_applies_gain_and_learns(tmp_path):
    """A complete stream reaches the FIFO with the default gain and teaches the voice's gain."""
    # A quiet tone (-29 dBFS) makes the applied and the learned gain easy to read off.
    samples = tone(1.2, amplitude=0.05)
    server = FakeServer(samples)
    entry = str(tmp_path / "s00000.pcm")
    os.mkfifo(entry)
    # The reader plays the role of mpv.
    reader = FifoReader(entry)
    status = htts_stream.run_stream(run_args(tmp_path, server.port))
    assert status == htts_stream.STATUS_OK
    assert reader.eof.wait(3)
    # What mpv received, decoded back into samples.
    played = array.array("h")
    played.frombytes(bytes(reader.data))
    reader.close()
    server.close()
    # Nothing was lost on the way to the player.
    assert len(played) == len(samples)
    # The default 6 dB were applied (raw level about -29 dB).
    assert rms_db(played) - rms_db(samples) == pytest.approx(htts_stream.DEFAULT_GAIN_DB, abs=0.2)
    # The stored gain is what would have brought the raw chunk to the -21 dB target.
    learned = htts_stream.read_gains(str(tmp_path / "gains"))["ryan"]
    assert learned == pytest.approx(-21.0 - rms_db(samples), abs=0.2)
    # The replay copy equals what mpv played.
    assert read_copy(entry) == bytes(reader.data)


def test_no_gain_flag_leaves_audio_untouched_and_learns_nothing(tmp_path):
    """NORMALIZE_LOUDNESS=0 passes the audio through and keeps the table empty."""
    samples = tone(0.6)
    server = FakeServer(samples)
    os.mkfifo(str(tmp_path / "s00000.pcm"))
    # No reader is attached: the copy alone must still hold the exact server bytes.
    args = run_args(tmp_path, server.port, no_gain=True)
    assert htts_stream.run_stream(args) == htts_stream.STATUS_OK
    server.close()
    # Untouched audio, and no gain table was written.
    assert read_copy(args.entry) == samples.tobytes()
    assert not os.path.exists(args.gains)


# An HTTP error and a server that sits on the request past the start timeout.
@pytest.mark.parametrize("mode,kwargs", [
    ("http500", {}),
    ("ok", {"first_delay": 2.0}),
])
def test_failures_before_audio_report_no_audio(tmp_path, mode, kwargs):
    """An HTTP error or a stall before the first byte leaves no copy and asks for a fallback."""
    server = FakeServer(tone(1.0), mode=mode, **kwargs)
    os.mkfifo(str(tmp_path / "s00000.pcm"))
    # A short start timeout keeps the stalled case fast.
    args = run_args(tmp_path, server.port, start_timeout=0.5)
    assert htts_stream.run_stream(args) == htts_stream.STATUS_NO_AUDIO
    server.close()
    assert not os.path.exists(args.entry + ".part")


def test_silent_stream_is_not_played(tmp_path):
    """All-zero audio is held, then rejected before anything reaches mpv."""
    server = FakeServer(tone(2.0, amplitude=0.0))
    os.mkfifo(str(tmp_path / "s00000.pcm"))
    reader = FifoReader(str(tmp_path / "s00000.pcm"))
    # The helper gives up on the silent stream ...
    assert htts_stream.run_stream(run_args(tmp_path, server.port)) == htts_stream.STATUS_NO_AUDIO
    # ... before a single byte reached the player.
    assert bytes(reader.data) == b""
    reader.close()
    server.close()


def test_connection_refused_reports_no_audio(tmp_path):
    """A dead worker is a fallback case, not a crash."""
    os.mkfifo(str(tmp_path / "s00000.pcm"))
    assert htts_stream.run_stream(run_args(tmp_path, 9)) == htts_stream.STATUS_NO_AUDIO


def test_stream_that_dies_midway_is_partial(tmp_path):
    """Audio already played is kept; the status tells the caller to re-render for replay."""
    server = FakeServer(tone(1.6), mode="die")
    os.mkfifo(str(tmp_path / "s00000.pcm"))
    # The server cuts the connection halfway; audio was already played, hence PARTIAL.
    args = run_args(tmp_path, server.port)
    assert htts_stream.run_stream(args) == htts_stream.STATUS_PARTIAL
    server.close()
    # Some audio, but not all of it, was kept; a broken stream teaches no gain.
    size = len(read_copy(args.entry))
    assert 0 < size < len(tone(1.6)) * 2
    assert not os.path.exists(args.gains)


def test_stalled_stream_midway_is_partial_after_the_idle_timeout(tmp_path):
    """A generation that stops sending ends the run once the idle limit passes."""
    server = FakeServer(tone(1.6), mode="hang")
    os.mkfifo(str(tmp_path / "s00000.pcm"))
    # A 0.4 s idle limit makes the stall detectable quickly.
    args = run_args(tmp_path, server.port, idle_timeout=0.4)
    started = time.monotonic()
    assert htts_stream.run_stream(args) == htts_stream.STATUS_PARTIAL
    # The run ended through the idle limit, not through the server's 30 s hang.
    assert time.monotonic() - started < 5
    # Only now release the server's hanging handler thread.
    server.close()


def test_runaway_is_cut_and_the_server_is_released(tmp_path):
    """Audio beyond the runaway limit is dropped and the connection closed."""
    server = FakeServer(tone(6.0), frame_gap=0.01)
    os.mkfifo(str(tmp_path / "s00000.pcm"))
    # Six seconds are offered but the limit is one second.
    args = run_args(tmp_path, server.port, runaway_seconds=1.0)
    assert htts_stream.run_stream(args) == htts_stream.STATUS_PARTIAL
    # Exactly one second (48000 bytes) was kept, and the server noticed the closed connection.
    assert len(read_copy(args.entry)) == 48000
    assert server.client_gone.wait(3)
    server.close()
