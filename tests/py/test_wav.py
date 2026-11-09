"""Tests for the WAV quality gate and loudness normaliser (htts_wav)."""

import array
import math
import struct
import subprocess
import sys
import wave

import pytest

import htts_wav


def write_tone(path, seconds=1.0, amplitude=0.3, rate=24000, frequency=220):
    """Write a mono 16-bit sine tone.

    Args:
        path: Destination file.
        seconds: Duration.
        amplitude: Peak amplitude 0..1.
        rate: Sample rate.
        frequency: Tone frequency in Hz.

    Returns:
        None.
    """
    # Integer samples of a sine; amplitude 0 gives silence.
    samples = array.array("h", [
        int(amplitude * 32767 * math.sin(2 * math.pi * frequency * i / rate))
        for i in range(int(rate * seconds))])
    with wave.open(str(path), "wb") as writer:
        writer.setnchannels(1)
        writer.setsampwidth(2)
        writer.setframerate(rate)
        writer.writeframes(samples.tobytes())


def peak_of(path):
    """Return the peak amplitude (0..1) of a 16-bit WAV.

    Args:
        path: The file.

    Returns:
        The largest absolute sample divided by 32768.
    """
    # Decode through the module under test, so reading and writing stay consistent.
    return max(abs(value) for value in htts_wav.read_wav(str(path)).samples)


def test_silence_is_rejected(tmp_path):
    """A file of zeros is reported as silent and left untouched.

    Args:
        tmp_path: pytest temporary directory.

    Returns:
        None.
    """
    path = tmp_path / "silent.wav"
    write_tone(path, amplitude=0.0)
    # Status 3 is what lib/qwen3.sh maps to "retry with a new seed".
    assert htts_wav.finish(str(path)) == htts_wav.STATUS_SILENT


def test_near_silence_is_rejected(tmp_path):
    """Noise below -40 dBFS counts as silence too.

    Args:
        tmp_path: pytest temporary directory.

    Returns:
        None.
    """
    path = tmp_path / "hiss.wav"
    write_tone(path, amplitude=0.005)
    assert htts_wav.finish(str(path)) == htts_wav.STATUS_SILENT


def test_empty_payload_is_silent(tmp_path):
    """A WAV without any frame is silent, not unreadable.

    Args:
        tmp_path: pytest temporary directory.

    Returns:
        None.
    """
    path = tmp_path / "empty.wav"
    write_tone(path, seconds=0.0)
    assert htts_wav.finish(str(path)) == htts_wav.STATUS_SILENT


def test_runaway_duration_is_rejected(tmp_path):
    """Audio longer than the limit is a runaway; shorter audio passes.

    Args:
        tmp_path: pytest temporary directory.

    Returns:
        None.
    """
    path = tmp_path / "long.wav"
    write_tone(path, seconds=5.0)
    assert htts_wav.finish(str(path), runaway_seconds=4.0) == htts_wav.STATUS_RUNAWAY
    assert htts_wav.finish(str(path), runaway_seconds=6.0) == htts_wav.STATUS_OK
    # Zero means "no limit".
    assert htts_wav.finish(str(path), runaway_seconds=0) == htts_wav.STATUS_OK


def test_unreadable_files_are_reported(tmp_path):
    """Garbage, a missing file and an unsupported layout give status 5.

    Args:
        tmp_path: pytest temporary directory.

    Returns:
        None.
    """
    garbage = tmp_path / "garbage.wav"
    garbage.write_bytes(b"not a wav at all")
    assert htts_wav.finish(str(garbage)) == htts_wav.STATUS_UNREADABLE
    assert htts_wav.finish(str(tmp_path / "missing.wav")) == htts_wav.STATUS_UNREADABLE
    # 8-bit PCM is not a layout the servers produce.
    eight_bit = tmp_path / "eight.wav"
    with wave.open(str(eight_bit), "wb") as writer:
        writer.setnchannels(1)
        writer.setsampwidth(1)
        writer.setframerate(8000)
        writer.writeframes(b"\x80" * 100)
    assert htts_wav.finish(str(eight_bit)) == htts_wav.STATUS_UNREADABLE


def test_quiet_and_loud_voices_meet_at_the_same_level(tmp_path):
    """Normalisation brings a quiet and a loud tone to the same peak.

    Args:
        tmp_path: pytest temporary directory.

    Returns:
        None.
    """
    quiet, loud = tmp_path / "quiet.wav", tmp_path / "loud.wav"
    write_tone(quiet, amplitude=0.10)
    write_tone(loud, amplitude=0.30)
    assert htts_wav.finish(str(quiet)) == htts_wav.STATUS_OK
    assert htts_wav.finish(str(loud)) == htts_wav.STATUS_OK
    # Both end within a rounding step of each other (target -21 dBFS RMS).
    assert peak_of(quiet) == pytest.approx(peak_of(loud), abs=0.01)


def test_no_normalise_leaves_samples_alone(tmp_path):
    """The --no-normalise switch keeps the file byte-identical.

    Args:
        tmp_path: pytest temporary directory.

    Returns:
        None.
    """
    path = tmp_path / "tone.wav"
    write_tone(path, amplitude=0.1)
    before = path.read_bytes()
    assert htts_wav.finish(str(path), normalise=False) == htts_wav.STATUS_OK
    assert path.read_bytes() == before


def test_gain_never_clips(tmp_path):
    """A very quiet file with a tall transient is not boosted past the peak ceiling.

    Args:
        tmp_path: pytest temporary directory.

    Returns:
        None.
    """
    path = tmp_path / "peaky.wav"
    write_tone(path, amplitude=0.02)
    wav = htts_wav.read_wav(str(path))
    # One loud click on top of a faint tone: the loudness asks for much more gain than allowed.
    wav.samples[100] = 0.8
    htts_wav.write_scaled(str(path), wav, htts_wav.choose_gain_db(0.8, -45.0))
    assert peak_of(path) <= htts_wav.PEAK_CEILING + 1e-3


def test_gain_choice_is_clamped():
    """The chosen gain stays inside the configured limits.

    Returns:
        None.
    """
    # A tiny file would want +60 dB; the boost is limited.
    assert htts_wav.choose_gain_db(0.05, -80.0) <= htts_wav.MAX_GAIN_DB
    # A blasting file is attenuated, but never by more than the cut limit.
    assert htts_wav.choose_gain_db(0.5, 0.0) >= htts_wav.MIN_GAIN_DB
    # A file already at the target needs no rewrite.
    assert htts_wav.choose_gain_db(0.3, htts_wav.TARGET_RMS_DB + 0.1) == 0.0


def test_float32_wav_is_supported(tmp_path):
    """IEEE float WAVs (some servers write them) are decoded and rewritten as float.

    Args:
        tmp_path: pytest temporary directory.

    Returns:
        None.
    """
    path = tmp_path / "float.wav"
    samples = array.array("f", [0.2 * math.sin(2 * math.pi * 220 * i / 24000) for i in range(24000)])
    payload = samples.tobytes()
    header = b"RIFF" + struct.pack("<I", 36 + len(payload)) + b"WAVEfmt "
    header += struct.pack("<IHHIIHH", 16, 3, 1, 24000, 24000 * 4, 4, 32)
    path.write_bytes(header + b"data" + struct.pack("<I", len(payload)) + payload)
    assert htts_wav.finish(str(path)) == htts_wav.STATUS_OK
    rewritten = htts_wav.read_wav(str(path))
    # Still a float file, now at the target loudness.
    assert rewritten.is_float and rewritten.bits == 32
    assert max(rewritten.samples) > 0.1


def test_command_line_exit_codes(tmp_path):
    """The CLI maps results to exit codes and rejects bad usage with 2.

    Args:
        tmp_path: pytest temporary directory.

    Returns:
        None.
    """
    path = tmp_path / "silent.wav"
    write_tone(path, amplitude=0.0)
    script = str(htts_wav.__file__)
    # Exit status 3 means silent, as lib/engine.sh documents.
    assert subprocess.run([sys.executable, script, "finish", str(path)]).returncode == 3
    assert subprocess.run([sys.executable, script, "bogus"]).returncode == 2
    assert subprocess.run([sys.executable, script, "finish", str(path), "--bogus"]).returncode == 2
