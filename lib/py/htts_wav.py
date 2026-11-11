#!/usr/bin/env python3
"""Quality gate and loudness normaliser for synthesized WAV files (standard library only).

One call per rendered chunk decides whether the audio is usable (not silent, not a runaway
generation) and, when it is, rewrites the file in place at a common loudness so that voices
switch without volume jumps. Exit status: 0 ok, 3 silent or empty, 4 runaway, 5 unreadable.

Usage: htts_wav.py finish FILE [--runaway-seconds S] [--no-normalise]
       htts_wav.py gain FILE      (prints the gain in dB the normaliser would apply)
"""
import array  # Typed sample buffers for the PCM16 and float32 payloads.
import math  # Decibel conversions and square roots.
import os  # Atomic rename of the rewritten file.
import struct  # Packing and unpacking the RIFF chunk headers.
import sys  # Command line and exit status.

# Peak amplitude (0..1) below which a render counts as silence (about -40 dBFS).
SILENT_PEAK = 0.01
# Target loudness of the active speech (RMS in dBFS); close to the loudest preset voices.
TARGET_RMS_DB = -21.0
# Largest sample magnitude allowed after the gain (leaves headroom against clipping).
PEAK_CEILING = 0.9
# Largest boost and cut applied to one file, in dB; keeps odd renders from being wrecked.
MAX_GAIN_DB = 14.0
MIN_GAIN_DB = -12.0
# Gains smaller than this are not worth rewriting the file for.
MIN_AUDIBLE_GAIN_DB = 0.5
# Length of one analysis frame in seconds; frames below the gate do not count as speech.
FRAME_SECONDS = 0.02
# Frame loudness (dBFS) below which a frame is treated as a pause.
GATE_DB = -50.0
# Status codes shared with lib/qwen3.sh.
STATUS_OK, STATUS_SILENT, STATUS_RUNAWAY, STATUS_UNREADABLE = 0, 3, 4, 5
# RIFF format tags that carry the two sample layouts we understand.
FORMAT_PCM, FORMAT_FLOAT, FORMAT_EXTENSIBLE = 1, 3, 0xFFFE


class WavError(Exception):
    """Raised when a file is not a WAV this module can read."""


class Wav:
    """Decoded WAV: header facts, the samples as floats and the bytes around the payload."""

    def __init__(self, rate, channels, bits, is_float, samples, head, tail):
        """Store the decoded pieces.

        Args:
            rate: Sample rate in Hz.
            channels: Number of interleaved channels.
            bits: Bits per sample (16 or 32).
            is_float: True for IEEE float samples, False for signed PCM.
            samples: Interleaved samples scaled to -1..1.
            head: Raw bytes before the data payload (RIFF header, fmt chunk, data header).
            tail: Raw bytes after the data payload (trailing chunks, possibly empty).

        Returns:
            None.
        """
        # Plain attribute storage; all behaviour lives in the module functions below.
        self.rate, self.channels, self.bits = rate, channels, bits
        self.is_float, self.samples, self.head, self.tail = is_float, samples, head, tail

    @property
    def seconds(self):
        """Duration of the audio.

        Returns:
            Length in seconds (0.0 for an empty payload).
        """
        # Frames = samples per channel; the rate turns that into seconds.
        frames = len(self.samples) // max(self.channels, 1)
        return frames / self.rate if self.rate else 0.0


def parse_format_chunk(payload):
    """Decode the fmt chunk.

    Args:
        payload: Bytes of the fmt chunk without its 8-byte header.

    Returns:
        Tuple (rate, channels, bits, is_float).

    Raises:
        WavError: When the sample layout is neither PCM16 nor float32.
    """
    # Format tag, channel count, rate and bit depth sit at fixed offsets.
    tag, channels, rate = struct.unpack("<HHI", payload[:8])
    bits = struct.unpack("<H", payload[14:16])[0]
    # Extensible headers name the real layout in their sub-format; the bit depth decides here.
    is_float = tag == FORMAT_FLOAT or (tag == FORMAT_EXTENSIBLE and bits == 32)
    if not is_float and not (tag in (FORMAT_PCM, FORMAT_EXTENSIBLE) and bits == 16):
        raise WavError(f"unsupported WAV layout (tag {tag}, {bits} bit)")
    return rate, channels, bits, is_float


def split_chunks(data):
    """Locate the fmt and data chunks of a RIFF/WAVE byte string.

    Args:
        data: The whole file.

    Returns:
        Tuple (fmt_payload, data_start, data_end).

    Raises:
        WavError: When the container is not RIFF/WAVE or a chunk is missing.
    """
    # Anything that is not RIFF....WAVE cannot be played, so it is rejected up front.
    if data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise WavError("not a RIFF/WAVE file")
    fmt_payload, position = None, 12
    # Walk the chunk list; chunks are padded to even sizes.
    while position + 8 <= len(data):
        name, size = struct.unpack("<4sI", data[position:position + 8])
        body_start = position + 8
        # Streaming servers may leave 0xFFFFFFFF as the data size: the payload runs to the end.
        body_end = min(body_start + size, len(data))
        if name == b"fmt ":
            fmt_payload = data[body_start:body_end]
        if name == b"data":
            # Without a fmt chunk before the data the sample layout is unknown.
            if fmt_payload is None:
                raise WavError("data chunk before fmt chunk")
            return fmt_payload, body_start, body_end
        # Move on to the next chunk (chunks are padded to even sizes).
        position = body_start + size + (size & 1)
    raise WavError("no data chunk")


def read_wav(path):
    """Read and decode a WAV file.

    Args:
        path: File to read.

    Returns:
        A Wav with samples scaled to -1..1.

    Raises:
        WavError: When the file is unreadable or uses an unsupported layout.
    """
    # OSError covers a missing or unreadable file; both mean "nothing usable here".
    try:
        with open(path, "rb") as handle:
            data = handle.read()
    except OSError as error:
        raise WavError(str(error)) from error
    # Layout facts come from the fmt chunk, the samples from the data chunk.
    fmt_payload, start, end = split_chunks(data)
    rate, channels, bits, is_float = parse_format_chunk(fmt_payload)
    # Drop a trailing partial sample so the typed array always divides evenly.
    width = bits // 8
    payload = data[start:end - ((end - start) % width)]
    raw = array.array("f" if is_float else "h")
    raw.frombytes(payload)
    # 16-bit PCM is scaled to -1..1; float samples already are.
    scale = 1.0 if is_float else 1.0 / 32768.0
    return Wav(rate, channels, bits, is_float, [value * scale for value in raw],
               data[:start], data[end:])


def measure(wav):
    """Measure peak amplitude and the loudness of the speech frames.

    Args:
        wav: A decoded Wav.

    Returns:
        Tuple (peak, speech_rms_db); the loudness is -inf when no frame passes the gate.
    """
    samples = wav.samples
    peak = max((abs(value) for value in samples), default=0.0)
    frame_len = max(int(wav.rate * wav.channels * FRAME_SECONDS), 1)
    # Energy and sample count of all frames above the gate.
    loud_energy, loud_count = 0.0, 0
    # Only frames above the gate contribute, so pauses do not drag the loudness down.
    for start in range(0, len(samples), frame_len):
        frame = samples[start:start + frame_len]
        energy = math.fsum(value * value for value in frame)
        frame_db = 10 * math.log10(energy / len(frame) + 1e-12)
        # Quiet frames (pauses) are skipped.
        if frame_db > GATE_DB:
            loud_energy += energy
            loud_count += len(frame)
    # A file without any speech frame has no measurable loudness.
    if loud_count == 0:
        return peak, float("-inf")
    return peak, 10 * math.log10(loud_energy / loud_count)


def choose_gain_db(peak, speech_db):
    """Pick the gain that brings the speech to the target without clipping.

    Args:
        peak: Peak amplitude of the file (0..1).
        speech_db: Speech loudness in dBFS.

    Returns:
        Gain in dB (0.0 when no change is warranted).
    """
    # Boost or cut towards the target, but never by an extreme amount.
    gain_db = max(MIN_GAIN_DB, min(MAX_GAIN_DB, TARGET_RMS_DB - speech_db))
    # The loudest sample must stay below the ceiling, whatever the loudness target says.
    headroom_db = 20 * math.log10(PEAK_CEILING / peak)
    gain_db = min(gain_db, headroom_db)
    # Tiny corrections are skipped so most files are left untouched.
    return gain_db if abs(gain_db) >= MIN_AUDIBLE_GAIN_DB else 0.0


def write_scaled(path, wav, gain_db):
    """Rewrite a WAV with its samples multiplied by a gain.

    Args:
        path: Destination (same file that was read).
        wav: The decoded Wav the new payload is derived from.
        gain_db: Gain in dB.

    Returns:
        None.
    """
    factor = 10 ** (gain_db / 20)
    # Clipping to the legal range protects against rounding at the extremes.
    if wav.is_float:
        out = array.array("f", [value * factor for value in wav.samples])
    else:
        out = array.array("h", [max(-32768, min(32767, round(v * factor * 32768.0)))
                                for v in wav.samples])
    # Write to a sibling and rename, so a crash never leaves a half-written file.
    temporary = path + ".norm"
    with open(temporary, "wb") as handle:
        handle.write(wav.head + out.tobytes() + wav.tail)
    os.replace(temporary, path)


def finish(path, runaway_seconds=0.0, normalise=True):
    """Judge one rendered file and normalise its loudness when it is usable.

    Args:
        path: The WAV file.
        runaway_seconds: Duration above which the render counts as runaway (0 = no limit).
        normalise: Whether to rewrite the file at the common loudness.

    Returns:
        One of STATUS_OK, STATUS_SILENT, STATUS_RUNAWAY, STATUS_UNREADABLE.
    """
    # A file that cannot be decoded is reported so the caller can fall back.
    try:
        wav = read_wav(path)
    except WavError:
        return STATUS_UNREADABLE
    # Empty payloads and near-silent renders are the GPU-contention failure mode.
    peak, speech_db = measure(wav)
    if not wav.samples or peak < SILENT_PEAK:
        return STATUS_SILENT
    # The duration limit comes from the text length (see qwen3_runaway_seconds in qwen3.sh).
    if runaway_seconds > 0 and wav.seconds > runaway_seconds:
        return STATUS_RUNAWAY
    gain_db = choose_gain_db(peak, speech_db) if normalise else 0.0
    if gain_db:
        # The rewrite only happens for an audible gain.
        write_scaled(path, wav, gain_db)
    return STATUS_OK


def gain_of_file(path):
    """Measure the gain the normaliser would apply to a file, without touching it.

    Args:
        path: The WAV file.

    Returns:
        The gain in dB (0.0 when no change is warranted); None for an unreadable or silent file.
    """
    # An unreadable file has no loudness to speak of.
    try:
        wav = read_wav(path)
    except WavError:
        return None
    # Silence cannot teach a gain either.
    peak, speech_db = measure(wav)
    if not wav.samples or peak < SILENT_PEAK:
        return None
    return choose_gain_db(peak, speech_db)


def print_gain(path):
    """Command line verb ``gain``: print the normaliser gain of a file.

    Args:
        path: The WAV file.

    Returns:
        STATUS_OK with the gain on stdout; STATUS_UNREADABLE (also for silence) without output.
    """
    gain_db = gain_of_file(path)
    # Without a loudness there is nothing the caller could store.
    if gain_db is None:
        return STATUS_UNREADABLE
    # One decimal is far below what a listener hears.
    sys.stdout.write(f"{gain_db:.1f}\n")
    return STATUS_OK


def main(argv):
    """Command line entry point.

    Args:
        argv: Arguments after the program name: finish FILE [--runaway-seconds S] [--no-normalise].

    Returns:
        The process exit status (see the module docstring); 2 for a usage error.
    """
    # The cheap measuring verb needs no options.
    if len(argv) == 2 and argv[0] == "gain":
        return print_gain(argv[1])
    # Otherwise only the finish verb exists; anything else is a usage error.
    if len(argv) < 2 or argv[0] != "finish":
        sys.stderr.write("usage: htts_wav.py finish FILE [--runaway-seconds S] [--no-normalise]\n")
        return 2
    path, runaway_seconds, normalise = argv[1], 0.0, True
    # The remaining words are options.
    options = argv[2:]
    # Flags are tiny and fixed, so a hand-rolled loop beats an argparse import (startup time).
    while options:
        flag = options.pop(0)
        if flag == "--no-normalise":
            normalise = False
        # --runaway-seconds takes the following word as its value.
        elif flag == "--runaway-seconds" and options:
            runaway_seconds = float(options.pop(0))
        else:
            sys.stderr.write(f"htts_wav.py: unknown option {flag}\n")
            # Unknown options are a usage error.
            return 2
    return finish(path, runaway_seconds, normalise)


if __name__ == "__main__":
    # The exit status tells the bash caller what to do (see the module docstring).
    sys.exit(main(sys.argv[1:]))
