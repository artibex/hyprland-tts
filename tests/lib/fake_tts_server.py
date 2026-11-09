#!/usr/bin/env python3
"""Fake qwentts.cpp tts-server for the hyprland-tts test suite.

Speaks the subset of the real HTTP API the tool uses (health, speech, voices) and logs
every request as one JSON line, so tests can assert on the exact fields that were sent.
Behaviour switches come from environment variables and a control file that tests rewrite
while the server runs.
"""
import io  # In-memory buffer for building the WAV reply.
import json  # Request parsing and log lines.
import os  # Environment switches and the process id.
import signal  # Clean shutdown on SIGTERM like the real server.
import sys  # Command-line arguments and exit codes.
import time  # Startup delay and slow responses.
import wave  # Writing a valid RIFF/WAV reply.
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer  # Minimal HTTP server.

# JSON-lines file every event is appended to (set by the test).
LOG_PATH = os.environ.get("FAKE_TTS_LOG", "")
# File whose content switches behaviour per request: ok | fail500 | slow=<s> | dur=<audio s>.
CONTROL_PATH = os.environ.get("FAKE_TTS_CONTROL", "")
# Device that makes the server exit at once ("any" = every device), for fallback tests.
BAD_DEVICE = os.environ.get("FAKE_TTS_BAD_DEVICE", "")
# Seconds to wait before listening, to test the start-up wait loop.
STARTUP_DELAY = float(os.environ.get("FAKE_TTS_STARTUP_DELAY", "0"))


def log_event(event):
    """Append one event to the JSON-lines log.

    Args:
        event: Dict describing what happened.

    Returns:
        None.
    """
    # Without a log path the fake simply stays silent.
    if not LOG_PATH:
        return
    # Append mode keeps concurrent writers from truncating each other.
    with open(LOG_PATH, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(event) + "\n")


def read_mode():
    """Read the current behaviour switch.

    Returns:
        The control file content, or "ok" when there is none.
    """
    # No control file means normal behaviour.
    if not CONTROL_PATH or not os.path.exists(CONTROL_PATH):
        return "ok"
    # Re-read on every request so tests can flip it live.
    with open(CONTROL_PATH, encoding="utf-8") as handle:
        return handle.read().strip() or "ok"


def make_wav(seconds=0.25):
    """Build a valid mono 24 kHz WAV of silence.

    Args:
        seconds: Length of the audio.

    Returns:
        The WAV file as bytes.
    """
    # BytesIO avoids touching the disk for every reply.
    buffer = io.BytesIO()
    # Quarter second of 16-bit samples keeps the tests quick but real for mpv.
    with wave.open(buffer, "wb") as writer:
        writer.setnchannels(1)
        writer.setsampwidth(2)
        # 24 kHz mono matches what the real server returns.
        writer.setframerate(24000)
        writer.writeframes(b"\x00\x00" * int(24000 * seconds))
    # getvalue is complete once the wave writer closed.
    return buffer.getvalue()


def parse_args(argv):
    """Parse the server command line the way the real tool names its flags.

    Args:
        argv: Arguments after the program name.

    Returns:
        Dict with the flags that were given.
    """
    # Flags with a value; everything else is ignored like unknown tuning flags.
    options = {}
    index = 0
    # Walk the list once, pairing each --flag with the next token.
    while index < len(argv):
        # Only dashed tokens followed by a value are recorded.
        if argv[index].startswith("--") and index + 1 < len(argv):
            options[argv[index][2:]] = argv[index + 1]
            index += 1
        index += 1
    # The caller decides which keys are required.
    return options


class Handler(BaseHTTPRequestHandler):
    """HTTP handler implementing the fake API."""

    # Model path of this server process, set before serving starts.
    model_path = ""

    def log_message(self, format, *args):  # pylint: disable=redefined-builtin
        """Silence the default access log.

        Args:
            format: Ignored format string.
            args: Ignored format arguments.

        Returns:
            None.
        """
        # Tests read the JSON log instead of stderr noise.
        return

    def send_bytes(self, status, content_type, payload):
        """Send a complete response.

        Args:
            status: HTTP status code.
            content_type: MIME type of the body.
            payload: Body bytes.

        Returns:
            None.
        """
        # Headers first, then the body in one write.
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        # curl needs the length to know where the WAV ends.
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def read_json(self):
        """Read and parse the request body.

        Returns:
            The parsed JSON object.
        """
        # Content-Length is always set by curl --data-binary.
        length = int(self.headers.get("Content-Length", "0"))
        return json.loads(self.rfile.read(length) or b"{}")

    def do_GET(self):
        """Serve health and the voice list.

        Returns:
            None.
        """
        # Health is what the worker polls while the model "loads".
        if self.path == "/health":
            self.send_bytes(200, "application/json", b'{"status":"ok"}')
        # The voice list only needs to be well-formed for the tests.
        elif self.path == "/v1/audio/voices":
            self.send_bytes(200, "application/json", b'{"voices":[{"name":"ryan"}]}')
        # Anything else is an unknown route.
        else:
            self.send_bytes(404, "application/json", b"{}")

    def do_POST(self):
        """Serve speech synthesis and voice registration.

        Returns:
            None.
        """
        # Route by path; both bodies are JSON.
        body = self.read_json()
        if self.path == "/v1/audio/speech":
            self.handle_speech(body)
        # Voice registration is the Base-model feature.
        elif self.path == "/v1/audio/voices":
            self.handle_voice(body)
        # Unknown routes answer 404 like the real server.
        else:
            self.send_bytes(404, "application/json", b"{}")

    def handle_speech(self, body):
        """Log a speech request and answer it according to the control file.

        Args:
            body: Parsed request JSON.

        Returns:
            None.
        """
        # Log the fields tests assert on, before any failure mode applies.
        log_event({"event": "speech", **{key: body.get(key) for key in (
            "input", "voice", "language", "response_format", "max_new_tokens", "seed")}})
        mode = read_mode()
        # Simulated server error: the player must fall back to Piper.
        if mode == "fail500":
            self.send_bytes(500, "application/json", b'{"error":{"message":"boom"}}')
            return
        # Simulated slow synthesis, for idle-timer and concurrency tests.
        if mode.startswith("slow="):
            time.sleep(float(mode.split("=", 1)[1]))
        # dur=<seconds> makes the reply long enough to test playback controls.
        seconds = float(mode.split("=", 1)[1]) if mode.startswith("dur=") else 0.25
        self.send_bytes(200, "audio/wav", make_wav(seconds))

    def handle_voice(self, body):
        """Log a voice registration; only Base models accept it, like the real server.

        Args:
            body: Parsed request JSON.

        Returns:
            None.
        """
        # Record that latents (not a wav) arrived, never their content.
        log_event({"event": "voice", "name": body.get("name"), "ref_text": body.get("ref_text"),
                   "has_spk": bool(body.get("spk_b64")), "has_rvq": bool(body.get("rvq_b64"))})
        # CustomVoice servers refuse registrations with a 400.
        if "base" not in self.model_path:
            self.send_bytes(400, "application/json", b'{"error":{"message":"base only"}}')
            return
        self.send_bytes(200, "application/json", b'{"status":"registered"}')


def stop_on_signal(signal_number, frame):
    """Leave the serve loop cleanly when terminated.

    Args:
        signal_number: The received signal (unused).
        frame: The interrupted stack frame (unused).

    Returns:
        Never returns; raises SystemExit.
    """
    # SystemExit unwinds serve_forever and exits with status 0 like the real server.
    raise SystemExit(0)


def main():
    """Start the fake server.

    Returns:
        Process exit code.
    """
    options = parse_args(sys.argv[1:])
    # Mirror the real binary's startup record so tests can check host binding and device.
    log_event({"event": "start", "pid": os.getpid(), "argv": sys.argv[1:]})
    # A "broken" device makes the process die like a failed Vulkan initialisation.
    if BAD_DEVICE in (options.get("device"), "any"):
        return 1
    # Simulated model load time.
    time.sleep(STARTUP_DELAY)
    Handler.model_path = options.get("model", "")
    server = ThreadingHTTPServer((options.get("host", "127.0.0.1"), int(options["port"])), Handler)
    # SIGTERM must end serve_forever from the main thread without deadlocking.
    signal.signal(signal.SIGTERM, stop_on_signal)
    # Serve until terminated.
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
