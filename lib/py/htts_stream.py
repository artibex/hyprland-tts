"""Streaming speech client: plays the first chunk while the server is still generating it.

The warm tts-server answers a ``response_format: pcm`` request with chunked signed 16-bit mono
24 kHz audio while it synthesizes. This helper reads that stream, applies the per-voice gain
learned from earlier chunks (the file cannot be normalised before it plays), writes every byte
into a FIFO that mpv plays (speech starts after the first frames instead of after the whole
chunk) and into a regular copy. When the stream is complete the copy replaces the FIFO under
the same name, so a later replay of that playlist entry reads an ordinary file.

Exit status: 0 complete; 10 no audio was played (stall, error, silence), so the caller may
render the chunk the normal way; 11 audio was played but the stream died or ran away; 2 usage.

Usage: htts_stream.py stream ENTRY --port N --body FILE --voice NAME --gains FILE [options]
"""
import argparse  # Command line of the helper.
import array  # Typed buffers for the 16-bit samples.
import errno  # Distinguishing "no reader yet" from real FIFO errors.
import fcntl  # Enlarging the FIFO buffer.
import http.client  # Chunked HTTP response handling.
import math  # Decibel conversion and the soft limiter.
import os  # FIFO and file descriptors, atomic renames.
import select  # Waiting for a full FIFO to drain.
import sys  # Exit status and diagnostics.
import time  # Monotonic deadlines and latency figures.

import htts_wav  # Silence threshold and the loudness maths shared with the file gate.

# The server's PCM format: mono, 24 kHz, two bytes per sample.
RATE = 24000
BYTES_PER_SECOND = RATE * 2
# Exit statuses shared with lib/stream.sh.
STATUS_OK, STATUS_NO_AUDIO, STATUS_PARTIAL, STATUS_USAGE = 0, 10, 11, 2
# fcntl constant for the pipe size (absent from older fcntl modules).
F_SETPIPE_SZ = getattr(fcntl, "F_SETPIPE_SZ", 1031)
# A big pipe lets the writer run ahead of a paused mpv instead of blocking on it.
PIPE_BYTES = 1 << 20
# Leading near-silence is held back this long; a render that stays silent is never played.
SILENT_HOLD_SECONDS = 1.0
# Samples above this (90 % of full scale) are compressed softly instead of clipped.
LIMITER_KNEE = 0.9 * 32767
LIMITER_ROOM = 32767 - LIMITER_KNEE
# Share of a new measurement that moves the learned gain of a voice.
LEARN_WEIGHT = 0.5
# Seconds mpv gets to open the FIFO once the first audio is ready, and to drain a full pipe.
FIFO_ATTACH_SECONDS = 2.0
FIFO_WRITE_WAIT = 5.0
# Bytes requested per read from the HTTP response.
READ_BYTES = 65536
# Last-resort gain for a voice with neither a learned value nor a calibrated gain_db file
# (typical raw level is 6 dB under target).
DEFAULT_GAIN_DB = 6.0


class StreamFailure(Exception):
    """Raised when the stream cannot continue; the message names the reason for the log."""


def read_gains(path):
    """Read the learned per-voice gains.

    Args:
        path: Gain file with one ``<voice><TAB><dB>`` line per voice.

    Returns:
        Dict voice -> gain in dB (empty when the file is missing or unreadable).
    """
    gains = {}
    # A missing file is the normal first-run state.
    try:
        with open(path, encoding="utf-8") as handle:
            lines = handle.read().splitlines()
    except OSError:
        return gains
    # Malformed lines are skipped so one bad edit never disables the whole table.
    for line in lines:
        name, _, value = line.partition("\t")
        # A line without a number is garbage, not a gain.
        try:
            gains[name] = float(value)
        except ValueError:
            continue
    return gains


def write_gains(path, gains):
    """Store the gain table atomically (a crash never leaves a half-written file).

    Args:
        path: Gain file.
        gains: Dict voice -> gain in dB.

    Returns:
        None; failures are ignored because the table is only an optimisation.
    """
    temporary = f"{path}.tmp{os.getpid()}"
    # The state directory may not exist before the first learned voice.
    try:
        os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
        with open(temporary, "w", encoding="utf-8") as handle:
            handle.writelines(f"{name}\t{value:.2f}\n" for name, value in sorted(gains.items()))
        # The rename publishes the finished table in one step.
        os.replace(temporary, path)
    except OSError:
        return


def learn_gain(path, voice, measured_db):
    """Move a voice's stored gain towards a new measurement.

    Args:
        path: Gain file.
        voice: Voice name (the table key).
        measured_db: Gain that would have brought the finished chunk exactly to the target.

    Returns:
        The new stored gain in dB.
    """
    gains = read_gains(path)
    previous = gains.get(voice)
    # The first measurement is taken as is; later ones are averaged in.
    blended = measured_db
    if previous is not None:
        blended = previous + LEARN_WEIGHT * (measured_db - previous)
    # The same bounds as the file gate keep one odd chunk from wrecking the table.
    gains[voice] = max(htts_wav.MIN_GAIN_DB, min(htts_wav.MAX_GAIN_DB, blended))
    write_gains(path, gains)
    return gains[voice]


def usable_gain(value):
    """Check a gain from the command line and keep it inside the file gate's bounds.

    Args:
        value: Gain in dB as parsed from the command line (may be nan or infinite).

    Returns:
        The gain limited to the normaliser's bounds, or ``DEFAULT_GAIN_DB`` when not a number.
    """
    # nan and inf parse as floats but would silence or blow up every sample.
    if not math.isfinite(value):
        return DEFAULT_GAIN_DB
    return max(htts_wav.MIN_GAIN_DB, min(htts_wav.MAX_GAIN_DB, value))


def first_use_gain(args):
    """Choose the gain for the audio that streams before it can be measured.

    Args:
        args: Parsed command line (``no_gain``, ``gains``, ``voice``, ``default_gain_db``).

    Returns:
        0 without normalisation; else the learned gain of the voice, else the calibrated
        gain_db the caller passed for it (or the built-in default).
    """
    # Normalisation switched off: the stream is played untouched.
    if args.no_gain:
        return 0.0
    # What this machine learned beats what was calibrated on another one.
    learned = read_gains(args.gains).get(args.voice)
    return learned if learned is not None else usable_gain(args.default_gain_db)


def limit_sample(value):
    """Compress one scaled sample softly above the knee so loud outliers do not clip hard.

    Args:
        value: Sample after the gain, in 16-bit units.

    Returns:
        An integer within the 16-bit range.
    """
    magnitude = abs(value)
    # Most samples sit below the knee and pass unchanged.
    if magnitude <= LIMITER_KNEE:
        return int(value)
    # tanh bends the excess towards full scale without ever crossing it.
    limited = LIMITER_KNEE + LIMITER_ROOM * math.tanh((magnitude - LIMITER_KNEE) / LIMITER_ROOM)
    return int(math.copysign(limited, value))


def scale_samples(samples, gain_db):
    """Apply a gain to 16-bit samples.

    Args:
        samples: array('h') of raw samples.
        gain_db: Gain in dB (0 returns the input unchanged).

    Returns:
        array('h') with the gain and the soft limiter applied.
    """
    # A zero gain is common after normalisation was switched off.
    if gain_db == 0:
        return samples
    factor = 10 ** (gain_db / 20)
    return array.array("h", [limit_sample(value * factor) for value in samples])


def peak_of(samples):
    """Return the largest sample magnitude as a fraction of full scale.

    Args:
        samples: array('h').

    Returns:
        Peak between 0.0 and 1.0 (0.0 for an empty array).
    """
    # max/min on a typed array run in C, which matters for the first, latency-critical frames.
    if not samples:
        return 0.0
    return max(max(samples), -min(samples)) / 32768.0


class AudibleGate:
    """Holds leading near-silence back until speech starts, so silent renders are never played."""

    def __init__(self):
        """Start closed with nothing held.

        Returns:
            None.
        """
        # Samples received while the gate is still closed, in arrival order.
        self.held = array.array("h")
        self.is_open = False

    def push(self, samples):
        """Pass audio on once it is audible.

        Args:
            samples: array('h') just received (raw level).

        Returns:
            The samples to emit now (everything held plus this block once audible, this block
            alone while open, otherwise an empty array).

        Raises:
            StreamFailure: When more than SILENT_HOLD_SECONDS of audio were all silent.
        """
        # After the first audible block everything passes straight through.
        if self.is_open:
            return samples
        self.held.extend(samples)
        # An audible block opens the gate and releases what was held, silence included.
        if peak_of(samples) >= htts_wav.SILENT_PEAK:
            self.is_open = True
            released, self.held = self.held, array.array("h")
            return released
        # A long all-zero stretch is the silent-render failure; give up before playing it.
        if len(self.held) > SILENT_HOLD_SECONDS * RATE:
            raise StreamFailure("silent render")
        return array.array("h")


class Tee:
    """Writes the stream into a FIFO (live playback) and a regular file (the replay copy)."""

    def __init__(self, path):
        """Create the copy file next to the FIFO.

        Args:
            path: Playlist entry path; currently a FIFO that mpv has (or is about to) open.

        Returns:
            None.
        """
        self.path = path
        self.part_path = path + ".part"
        self.part = open(self.part_path, "wb")  # noqa: SIM115 - closed in finish()/abort()
        # None until mpv's read end exists; reader_gone marks an mpv that closed it early.
        self.fifo_fd = None
        self.reader_gone = False
        self.first_write = None
        # Audio produced before mpv attached; it is flushed first so no start is lost.
        self.backlog = bytearray()

    def attach(self, patient):
        """Open the FIFO's write end if mpv has opened the read end.

        Args:
            patient: False inside the attach window (retry later), True for a last single try.

        Returns:
            True when the write end is open.
        """
        # One attach per run is enough; a gone reader never returns.
        if self.fifo_fd is not None:
            return True
        if self.reader_gone:
            return False
        # Opening without O_NONBLOCK would hang forever when mpv never opens its end.
        try:
            self.fifo_fd = os.open(self.path, os.O_WRONLY | os.O_NONBLOCK)
        except OSError as error:
            # ENXIO means "no reader yet"; after the window the copy alone carries on.
            if error.errno == errno.ENXIO and not patient:
                self.reader_gone = time.monotonic() - self.first_write > FIFO_ATTACH_SECONDS
            return False
        # Best effort: a bigger pipe keeps the writer ahead of a paused player.
        try:
            fcntl.fcntl(self.fifo_fd, F_SETPIPE_SZ, PIPE_BYTES)
        except OSError:
            pass
        return True

    def write_fifo(self, data):
        """Write all bytes into the FIFO, waiting briefly while it is full.

        Args:
            data: Bytes to write.

        Returns:
            None.

        Raises:
            BrokenPipeError: When the reader left or stopped reading for FIFO_WRITE_WAIT seconds.
        """
        view = memoryview(data)
        deadline = time.monotonic() + FIFO_WRITE_WAIT
        # os.write may take only part of the data from a non-blocking descriptor.
        while view:
            try:
                view = view[os.write(self.fifo_fd, view):]
            except BlockingIOError:
                # A paused mpv fills even the large pipe; waiting longer than this is a stall.
                if time.monotonic() > deadline:
                    raise BrokenPipeError from None
                select.select([], [self.fifo_fd], [], 0.5)

    def write(self, data):
        """Append audio to the copy and hand it to mpv.

        Args:
            data: Bytes of s16le audio (already gained).

        Returns:
            None.
        """
        self.part.write(data)
        # The attach window is counted from the first audio, not from process start.
        if self.first_write is None:
            self.first_write = time.monotonic()
        # Without a live reader the audio waits in the backlog (the copy has it already).
        if not self.reader_gone:
            self.backlog.extend(data)
        if not self.attach(patient=False):
            # Once the attach window is over no reader will come, so the backlog is dropped.
            if self.reader_gone:
                self.backlog.clear()
            return
        self.flush_backlog()

    def flush_backlog(self):
        """Hand the waiting audio to mpv.

        Returns:
            None.
        """
        # A reader that quit (skip, stop) must not end the download: the copy still completes.
        try:
            self.write_fifo(bytes(self.backlog))
        except OSError:
            self.close_fifo()
            self.reader_gone = True
        # Delivered or abandoned, the waiting audio is not sent twice.
        self.backlog.clear()

    def close_fifo(self):
        """Close the write end, which tells mpv the stream is over.

        Returns:
            None.
        """
        if self.fifo_fd is not None:
            os.close(self.fifo_fd)
            self.fifo_fd = None

    def finish(self):
        """Complete the stream: the copy replaces the FIFO name, then mpv gets its end-of-file.

        Returns:
            None.
        """
        # A reader that opened late still gets the audio and its end-of-file (before the rename).
        if self.attach(patient=True):
            self.flush_backlog()
        self.part.close()
        # The rename is atomic; mpv keeps the old FIFO inode open and replays read the file.
        try:
            os.replace(self.part_path, self.path)
        finally:
            # mpv must get its end-of-file even when the rename failed.
            self.close_fifo()

    def abort(self):
        """Give up without a usable copy: end the FIFO and delete the partial file.

        Returns:
            None.
        """
        self.attach(patient=True)
        self.close_fifo()
        self.part.close()
        # The caller removes the FIFO name itself after telling mpv.
        try:
            os.unlink(self.part_path)
        except OSError:
            pass


class Session:
    """State of one streaming run: gain, gate, limits and the copy of the audio."""

    def __init__(self, args, tee, gain_db):
        """Remember the settings.

        Args:
            args: Parsed command line.
            tee: Output sink.
            gain_db: Gain applied to the audio while it streams.

        Returns:
            None.
        """
        self.tee = tee
        self.gain_db = gain_db
        self.gate = AudibleGate()
        # Raw (ungained) audio is kept to measure the loudness at the end.
        self.raw = array.array("h")
        self.carry = b""
        # Zero means "no length limit", like the file gate's runaway parameter.
        self.limit_samples = int(args.runaway_seconds * RATE) if args.runaway_seconds > 0 else 0
        # Set once the audio was cut at the limit; first_audio_at marks the latency milestone.
        self.runaway = False
        self.first_audio_at = None

    def feed(self, data):
        """Process bytes from the server.

        Args:
            data: Bytes of one HTTP read (may split a sample).

        Returns:
            True while more audio is wanted; False once the runaway limit was reached.
        """
        data = self.carry + data
        # An odd trailing byte belongs to the next read.
        usable = len(data) - (len(data) % 2)
        self.carry = data[usable:]
        samples = array.array("h")
        samples.frombytes(data[:usable])
        # Past the length limit the audio is cut off and the connection is dropped.
        if self.limit_samples and len(self.raw) + len(samples) > self.limit_samples:
            samples = samples[:max(self.limit_samples - len(self.raw), 0)]
            self.runaway = True
        self.raw.extend(samples)
        # The gate decides what is audible enough to play right now.
        self.emit(self.gate.push(samples))
        return not self.runaway

    def emit(self, samples):
        """Send gained audio to the sinks.

        Args:
            samples: array('h') at raw level (may be empty).

        Returns:
            None.
        """
        # Nothing to do while the gate holds the audio back.
        if not samples:
            return
        if self.first_audio_at is None:
            self.first_audio_at = time.monotonic()
        # The gain is applied here, so the copy holds exactly what was played.
        self.tee.write(scale_samples(samples, self.gain_db).tobytes())


def open_response(args):
    """Send the request and wait for the response headers (which come with the first audio).

    Args:
        args: Parsed command line.

    Returns:
        Tuple (connection, response) with a 200 status.

    Raises:
        StreamFailure: When the server refuses, errors or does not answer in time.
    """
    # The server sends its headers together with the first audio, so this wait is the latency.
    connection = http.client.HTTPConnection("127.0.0.1", args.port, timeout=args.start_timeout)
    try:
        with open(args.body, "rb") as handle:
            body = handle.read()
        # The socket is kept: a closing response hands it over and clears connection.sock.
        connection.connect()
        sock = connection.sock
        # getresponse blocks until the server has its first audio (or the start timeout hits).
        connection.request("POST", "/v1/audio/speech", body, {"Content-Type": "application/json"})
        response = connection.getresponse()
    except (OSError, http.client.HTTPException) as error:
        connection.close()
        raise StreamFailure(f"no stream: {error.__class__.__name__}") from error
    # An error envelope (JSON) arrives instead of audio when synthesis fails before any frame.
    if response.status != 200:
        detail = response.read(200).decode("utf-8", "replace")
        connection.close()
        raise StreamFailure(f"HTTP {response.status} {detail}")
    # From here on every read waits at most the idle limit (a stalled generation).
    sock.settimeout(args.idle_timeout)
    return connection, response


def pump(args, response, session, started):
    """Read the stream to its end, feeding every block into the session.

    Args:
        args: Parsed command line.
        response: Open HTTP response.
        session: The run's Session.
        started: Monotonic time the run began (the request limit counts from here).

    Returns:
        None.

    Raises:
        StreamFailure: On a timeout, a dropped connection or an exceeded request time.
    """
    deadline = started + args.request_timeout
    # read1 returns what has arrived (it must not wait for a full buffer); b"" is the end.
    while True:
        try:
            data = response.read1(READ_BYTES)
        except (OSError, http.client.HTTPException) as error:
            raise StreamFailure(f"stream broke: {error.__class__.__name__}") from error
        # An empty read is the clean end; feed() refuses more once the length limit is hit.
        if not data or not session.feed(data):
            return
        # The overall limit mirrors curl's --max-time of the non-streamed path.
        if time.monotonic() > deadline:
            raise StreamFailure("request timeout")


def measure_gain(samples):
    """Compute the gain that would bring raw audio to the common loudness target.

    Args:
        samples: array('h') of the raw (ungained) chunk.

    Returns:
        Gain in dB, or None when the audio has no measurable speech.
    """
    wav = htts_wav.Wav(RATE, 1, 16, False, [value / 32768.0 for value in samples], b"", b"")
    peak, speech_db = htts_wav.measure(wav)
    # Silence cannot teach a gain.
    if peak < htts_wav.SILENT_PEAK or speech_db == float("-inf"):
        return None
    return htts_wav.choose_gain_db(peak, speech_db)


def settle(args, session, failure, started):
    """Turn the end of the stream into the exit status and the files' final state.

    Args:
        args: Parsed command line.
        session: The run's Session.
        failure: StreamFailure that ended the stream, or None for a clean end.
        started: Monotonic time the run began.

    Returns:
        The exit status (see the module docstring).
    """
    audible = session.first_audio_at is not None
    # Nothing was played: the caller falls back to the normal render.
    if not audible:
        session.tee.abort()
        # The reason lands in the worker log through the caller's stderr redirect.
        reason = str(failure) if failure else "empty or silent stream"
        sys.stderr.write(f"htts_stream: no audio ({reason})\n")
        return STATUS_NO_AUDIO
    # Audio was played: keep what exists as the replay copy and tell mpv the stream ended.
    session.tee.finish()
    first_ms = (session.first_audio_at - started) * 1000
    seconds = len(session.raw) / RATE
    # An early end or a runaway keeps the audio that was heard but must not teach a gain.
    if failure or session.runaway:
        reason = str(failure) if failure else "runaway length"
        sys.stderr.write(f"htts_stream: partial {seconds:.2f}s ({reason})\n")
        return STATUS_PARTIAL
    # A good chunk teaches the voice's gain for the next first chunk.
    learned = None if args.no_gain else measure_gain(session.raw)
    if learned is not None:
        learn_gain(args.gains, args.voice, learned)
    # One summary line makes latency and gain visible in the worker log.
    sys.stderr.write(f"htts_stream: ok first_audio={first_ms:.0f}ms audio={seconds:.2f}s "
                     f"wall={time.monotonic() - started:.2f}s gain={session.gain_db:+.1f}dB\n")
    return STATUS_OK


def run_stream(args):
    """Stream one chunk from the server into the playlist entry.

    Args:
        args: Parsed command line.

    Returns:
        The exit status (see the module docstring).
    """
    started = time.monotonic()
    # An unmeasured voice gets its calibrated (else the default) gain until a chunk was measured.
    session = Session(args, Tee(args.entry), first_use_gain(args))
    # Nothing failed yet, and there is no connection to close yet.
    failure = connection = None
    # Every failure mode ends in settle(), which decides between fallback and partial audio.
    try:
        connection, response = open_response(args)
        pump(args, response, session, started)
    except StreamFailure as error:
        failure = error
    except Exception as error:  # noqa: BLE001 - a bug must still settle the FIFO and the files
        failure = StreamFailure(f"internal error: {error!r}")
    finally:
        # Closing the socket tells the server to stop generating for a stream nobody reads.
        if connection is not None:
            connection.close()
    return settle(args, session, failure, started)


def parse_args(argv):
    """Parse the command line.

    Args:
        argv: Arguments after the program name.

    Returns:
        The parsed namespace.
    """
    parser = argparse.ArgumentParser(prog="htts_stream.py")
    # The positional words come first: the only verb and the entry the audio goes to.
    parser.add_argument("verb", choices=["stream"])
    parser.add_argument("entry", help="playlist entry path (a FIFO mpv reads)")
    # Where the request is sent and what it contains.
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--body", required=True, help="file holding the JSON request")
    # Loudness handling: the table of learned gains and the first-use gain of the voice.
    parser.add_argument("--voice", default="default")
    parser.add_argument("--gains", required=True, help="learned per-voice gain table")
    parser.add_argument("--default-gain-db", type=float, default=DEFAULT_GAIN_DB,
                        help="gain before one was learned (the voice's gain_db file)")
    parser.add_argument("--no-gain", action="store_true", help="neither apply nor learn a gain")
    # Limits: audio length and the three timeouts.
    parser.add_argument("--runaway-seconds", type=float, default=0.0)
    parser.add_argument("--start-timeout", type=float, default=5.0)
    # Idle = no bytes mid-stream; request = the whole run, like curl's --max-time.
    parser.add_argument("--idle-timeout", type=float, default=5.0)
    parser.add_argument("--request-timeout", type=float, default=120.0)
    return parser.parse_args(argv)


def main(argv):
    """Command line entry point.

    Args:
        argv: Arguments after the program name.

    Returns:
        The process exit status (see the module docstring).
    """
    # argparse exits with status 2 itself for a usage error.
    return run_stream(parse_args(argv))


if __name__ == "__main__":
    # The status tells lib/stream.sh whether to fall back to the normal render.
    sys.exit(main(sys.argv[1:]))
