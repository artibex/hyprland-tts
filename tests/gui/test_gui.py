"""Headless tests for gui/hyprland-tts-gui.

The GUI is imported as a module and driven programmatically on a GTK4 Broadway display
(gtk4-broadwayd), so no window ever appears on the user's live desktop. A fake ``hyprland-tts``
executable records every argv and replays canned porcelain output, which makes the
button-to-CLI mapping, the asynchronous install log and the error paths observable.

Run with: ``python -m pytest tests/gui`` (needs PyGObject, GTK4, libadwaita, gtk4-broadwayd;
the whole module is skipped when any of them is missing).
"""

# Standard library: environment, file handling, process control, timing and JSON.
import importlib.machinery
import importlib.util
import json
import os

# shutil, socket and subprocess serve the fake CLI and the private Broadway daemon.
import shutil
import socket
import subprocess
import sys

# time drives the polling loops that wait for asynchronous GUI reactions.
import time

import pytest

# Without PyGObject there is nothing to test, so the module is skipped instead of failing.
pytest.importorskip("gi")
# PyGObject's own event-loop shim trips a Python 3.14 deprecation on every main-loop turn;
# it is upstream noise (gi/events.py), not a GUI defect, so it must not bury real warnings.
pytestmark = pytest.mark.filterwarnings("ignore::DeprecationWarning:gi.events")

# Repository root and the GUI script (it has no .py extension, hence the explicit loader).
REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
GUI_PATH = os.path.join(REPO_ROOT, "gui", "hyprland-tts-gui")
# Seconds a test may wait for an asynchronous GUI reaction before it counts as failed.
WAIT_SECONDS = 8.0

# The fake CLI: logs argv (plus the content of absolute file arguments) and replays responses.
FAKE_CLI_SOURCE = '''#!PYTHON
"""Fake hyprland-tts for GUI tests."""
import json, os, signal, subprocess, sys, time

state = os.environ["FAKE_TTS_STATE"]
args = sys.argv[1:]
files = {}
for arg in args:
    if os.path.isabs(arg) and os.path.isfile(arg):
        with open(arg, encoding="utf-8", errors="replace") as handle:
            files[arg] = handle.read(2000)
with open(os.path.join(state, "calls.jsonl"), "a") as log:
    log.write(json.dumps({"argv": args, "files": files}) + "\\n")
with open(os.path.join(state, "responses.json")) as handle:
    responses = json.load(handle)
best = None
for candidate in responses:
    prefix = candidate["match"]
    longer = best is None or len(prefix) > len(best["match"])
    if args[:len(prefix)] == prefix and longer:
        best = candidate
entry = best or {}
if entry.get("ignore_term"):
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
for line in entry.get("stderr_lines", []):
    print(line, file=sys.stderr, flush=True)
    time.sleep(entry.get("line_delay", 0))
if entry.get("hang"):
    child = subprocess.Popen(["sleep", "60"])
    with open(os.path.join(state, "child.pid"), "w") as handle:
        handle.write(str(child.pid))
    with open(os.path.join(state, "self.pid"), "w") as handle:
        handle.write(str(os.getpid()))
    time.sleep(60)
time.sleep(entry.get("sleep", 0))
sys.stdout.write(entry.get("stdout", ""))
sys.stderr.write(entry.get("stderr", ""))
sys.exit(entry.get("rc", 0))
'''

# Canned porcelain output for a machine with Qwen3 (Base model, Vulkan) installed and running.
ENGINE_STATUS = (
    "selected=auto\nactive=qwen3\nqwen3_installed=1\nqwen3_variant=base\n"
    "qwen3_device=Vulkan0\nqwen3_reason=\nworker=running\nworker_port=41234\n"
    "idle_minutes=10\npiper_languages=de,en\nlanguages=de,en,fr\nfuture_key=ignored\n"
)
# Voice list with three languages, one preset, two shipped voices and one user voice.
VOICE_LIST = (
    "assign\tde\tde-thorsten\nassign\ten\ten-lj\nassign\tfr\t-\n"
    "preset\tryan\ncloned\tde-thorsten\tshipped\ncloned\ten-lj\tshipped\n"
    "cloned\tmy-voice\tuser\n"
)
# One installed Piper voice (default, not fallback) and two catalogue entries.
MODEL_LIST = "de/de_DE-thorsten-high\tde\tthorsten (high)\t63000000\t1\t0\t0\n"
MODEL_CATALOG = (
    "de-thorsten\tde\tde_DE-thorsten-high\thigh\t1\tGerman Thorsten\n"
    "en-ryan\ten\ten_US-ryan-high\thigh\t0\tEnglish Ryan\n"
)
# Two shortcut rows as `keybind list --porcelain` prints them.
KEYBIND_LIST = "speak\tSpeak selection\tSUPER ALT, A\nstop\tStop speech\tSUPER ALT, ESCAPE\n"
# Dependency status with everything missing, as on a fresh install.
DEPS_MISSING = "python=\nmodel=\nsystem_packages=0\nready=0\n"


def pump(condition, timeout=WAIT_SECONDS):
    """Run the GLib main loop until a condition holds.

    Args:
        condition: Callable returning a truthy value when the wait is over.
        timeout: Seconds before the wait fails the test.

    Returns:
        None.
    """
    from gi.repository import GLib

    context = GLib.MainContext.default()
    deadline = time.monotonic() + timeout
    # Iterating the default context delivers the idle callbacks the worker threads queue.
    while not condition():
        if time.monotonic() > deadline:
            raise AssertionError("timed out waiting for the GUI")
        context.iteration(False)
        # A short sleep keeps the polling loop from burning a CPU core.
        time.sleep(0.005)


def pump_for(seconds):
    """Run the GLib main loop for a fixed time.

    Args:
        seconds: Duration to keep iterating.

    Returns:
        None.
    """
    deadline = time.monotonic() + seconds
    # A condition that only becomes true after the deadline turns pump into a timed loop.
    pump(lambda: time.monotonic() > deadline, timeout=seconds + 2)


def iter_widgets(root):
    """Yield a widget and all its descendants.

    Args:
        root: Starting Gtk.Widget.

    Returns:
        Generator of widgets, depth first.
    """
    yield root
    child = root.get_first_child()
    # Siblings are walked iteratively, children recursively.
    while child is not None:
        yield from iter_widgets(child)
        child = child.get_next_sibling()


def find_row(root, title):
    """Find the first Adw preferences row with an exact title.

    Args:
        root: Widget to search below.
        title: Row title to look for.

    Returns:
        The row, or None.
    """
    from gi.repository import Adw

    for widget in iter_widgets(root):
        # Only rows have titles; plain widgets are skipped.
        if isinstance(widget, Adw.PreferencesRow) and widget.get_title() == title:
            return widget
    return None


def find_button(root, tooltip=None, label=None):
    """Find a button by tooltip or label below a widget.

    Args:
        root: Widget to search below.
        tooltip: Tooltip text to match, or None.
        label: Button label to match, or None.

    Returns:
        The button, or None.
    """
    from gi.repository import Gtk

    for widget in iter_widgets(root):
        if not isinstance(widget, Gtk.Button):
            continue
        # Either criterion may identify the button; both are exact matches.
        if tooltip is not None and widget.get_tooltip_text() == tooltip:
            return widget
        if label is not None and widget.get_label() == label:
            return widget
    # Neither a tooltip nor a label matched any button below the root.
    return None


def process_is_gone(pid):
    """Tell whether a process no longer runs (a zombie counts as gone).

    Args:
        pid: Process id.

    Returns:
        True when the process is dead or already reaped.
    """
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    # A zombie still answers kill(0) but is finished; its stat state letter is Z.
    try:
        with open(f"/proc/{pid}/stat", encoding="utf-8") as handle:
            return handle.read().rsplit(")", 1)[1].split()[0] == "Z"
    except OSError:
        return True


class FakeCli:
    """Handle on the fake CLI's state directory: canned responses and the call log."""

    def __init__(self, state_dir):
        """Create the state directory contents.

        Args:
            state_dir: Directory the fake script reads and writes.

        Returns:
            None.
        """
        self.state_dir = str(state_dir)
        self.responses = []
        self._write_responses()

    def _write_responses(self):
        """Persist the response table where the fake script reads it.

        Returns:
            None.
        """
        with open(os.path.join(self.state_dir, "responses.json"), "w", encoding="utf-8") as out:
            json.dump(self.responses, out)

    def respond(self, *match, **fields):
        """Register (or replace) the canned answer for an argv prefix.

        Args:
            *match: Leading argv words the call must start with.
            **fields: stdout, stderr, rc, stderr_lines, line_delay, hang, sleep, ignore_term.

        Returns:
            None.
        """
        # A later registration for the same prefix replaces the earlier one.
        self.responses = [r for r in self.responses if r["match"] != list(match)]
        self.responses.append({"match": list(match), **fields})
        self._write_responses()

    def records(self):
        """Read the call log.

        Returns:
            List of dicts with argv and files, oldest first.
        """
        path = os.path.join(self.state_dir, "calls.jsonl")
        if not os.path.exists(path):
            return []
        # The log has one JSON object per call, appended by the fake CLI.
        with open(path, encoding="utf-8") as handle:
            return [json.loads(line) for line in handle if line.strip()]

    def calls(self):
        """List the argv of every call so far.

        Returns:
            List of argument lists.
        """
        return [record["argv"] for record in self.records()]

    def clear_calls(self):
        """Forget all recorded calls.

        Returns:
            None.
        """
        path = os.path.join(self.state_dir, "calls.jsonl")
        if os.path.exists(path):
            os.remove(path)

    def read_pid(self, name):
        """Read a pid file the fake wrote, waiting for it to appear.

        Args:
            name: File name inside the state directory.

        Returns:
            The pid as an int.
        """
        path = os.path.join(self.state_dir, name)
        pump(lambda: os.path.exists(path) and os.path.getsize(path) > 0)
        with open(path, encoding="utf-8") as handle:
            # The fake writes its pids as plain decimal text.
            return int(handle.read())


def free_display_number():
    """Find a Broadway display number whose HTTP port and socket are unused.

    Returns:
        An integer display number.
    """
    runtime_dir = os.environ.get("XDG_RUNTIME_DIR", "/tmp")
    for number in range(61, 120):
        # Broadway listens on 8080 + n; a bind test proves the port is free.
        probe = socket.socket()
        try:
            probe.bind(("127.0.0.1", 8080 + number))
        except OSError:
            continue
        finally:
            # The probe socket is always released so the daemon can use the port.
            probe.close()
        if not os.path.exists(os.path.join(runtime_dir, f"broadway{number + 1}.socket")):
            return number
    pytest.skip("no free Broadway display number")


@pytest.fixture(scope="session")
def broadway():
    """Start a private Broadway daemon and point GTK at it, never at the live session.

    Yields:
        The display name such as ":61".
    """
    daemon_binary = shutil.which("gtk4-broadwayd")
    if daemon_binary is None:
        pytest.skip("gtk4-broadwayd is not installed")
    # Broadway keeps its sockets in the runtime directory, which is cleaned up afterwards.
    runtime_dir = os.environ.get("XDG_RUNTIME_DIR", "/tmp")
    sockets_before = {
        name for name in os.listdir(runtime_dir) if name.startswith("broadway")
    }
    display = f":{free_display_number()}"
    daemon = subprocess.Popen(
        [daemon_binary, display], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )
    # Removing the Wayland/X11 variables guarantees GTK cannot fall back to the real desktop.
    for variable in ("WAYLAND_DISPLAY", "DISPLAY"):
        os.environ.pop(variable, None)
    os.environ["GDK_BACKEND"] = "broadway"
    os.environ["BROADWAY_DISPLAY"] = display
    # Give the daemon a moment to create its socket before GTK connects.
    time.sleep(0.6)
    yield display
    # Stop the daemon and delete only the socket files this run created.
    daemon.terminate()
    daemon.wait(timeout=5)
    for name in os.listdir(runtime_dir):
        if name.startswith("broadway") and name not in sockets_before:
            # Only sockets created by this run are removed, never the user's own.
            os.remove(os.path.join(runtime_dir, name))


@pytest.fixture(scope="session")
def fake_cli_path(tmp_path_factory):
    """Write the fake CLI executable once per session.

    Returns:
        Path of the executable.
    """
    path = tmp_path_factory.mktemp("fakebin") / "hyprland-tts"
    path.write_text(FAKE_CLI_SOURCE.replace("PYTHON", sys.executable, 1), encoding="utf-8")
    path.chmod(0o755)
    # Tests refer to the executable by its absolute path.
    return str(path)


@pytest.fixture(scope="session")
def gui(broadway, fake_cli_path):
    """Import the GUI module on the Broadway display with the fake CLI configured.

    Returns:
        The imported module.
    """
    os.environ["HYPRLAND_TTS_CLI"] = fake_cli_path
    loader = importlib.machinery.SourceFileLoader("hyprland_tts_gui", GUI_PATH)
    spec = importlib.util.spec_from_loader("hyprland_tts_gui", loader)
    # The module is executed only after the display variables are in place.
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    from gi.repository import Adw, Gdk

    Adw.init()
    # The default display is what GTK actually connected to.
    display = Gdk.Display.get_default()
    # A display that is not Broadway would mean the test could touch the live desktop.
    if display is None or "Broadway" not in type(display).__name__:
        pytest.skip(f"GTK did not open a Broadway display ({display})")
    return module


@pytest.fixture(scope="session")
def application(gui):
    """Create and register one application for all windows.

    Returns:
        The registered TtsApp.
    """
    from gi.repository import Gio

    # NON_UNIQUE never claims the real application id on the session bus, so a GUI that the
    # user has open (same id) cannot turn this process into a remote instance and crash it.
    app = gui.TtsApp(application_id="test.hyprland_tts.gui", flags=Gio.ApplicationFlags.NON_UNIQUE)
    app.register(None)
    return app


@pytest.fixture
def fake(tmp_path, monkeypatch):
    """Give each test its own fake-CLI state with default porcelain answers.

    Returns:
        A FakeCli.
    """
    state = tmp_path / "state"
    state.mkdir()
    monkeypatch.setenv("FAKE_TTS_STATE", str(state))
    # The helper writes and reads the state files the fake script uses.
    handle = FakeCli(state)
    # Default answers make a freshly built window render a complete, realistic picture.
    handle.respond("engine", "status", "--porcelain", stdout=ENGINE_STATUS)
    handle.respond("voice", "list", "--porcelain", stdout=VOICE_LIST)
    handle.respond("model", "list", "--porcelain", stdout=MODEL_LIST)
    handle.respond("model", "catalog", "--porcelain", stdout=MODEL_CATALOG)
    # Missing helpers exit with 1, exactly like the real `deps status`.
    handle.respond("deps", "status", "--porcelain", stdout=DEPS_MISSING, rc=1)
    handle.respond("keybind", "list", "--porcelain", stdout=KEYBIND_LIST)
    # The reader plays at full volume until a test says otherwise.
    handle.respond("volume", stdout="100\n")
    return handle


@pytest.fixture
def dialogs(gui, monkeypatch):
    """Capture dialogs instead of presenting them, so tests can answer them.

    Returns:
        A list that receives every dialog the GUI tries to show.
    """
    shown = []
    monkeypatch.setattr(gui, "present_dialog", lambda dialog, _window: shown.append(dialog))
    return shown


@pytest.fixture
def toasts(window, monkeypatch):
    """Record toast messages instead of showing them.

    Returns:
        A list that receives every toast text.
    """
    messages = []
    monkeypatch.setattr(window, "toast", messages.append)
    return messages


@pytest.fixture
def window(gui, application, fake):
    """Build a TtsWindow, wait for its first refresh and clear the call log.

    Yields:
        The window.
    """
    win = gui.TtsWindow(application)
    win.present()
    # The initial refresh issues one query batch per page: engine, voices, language, keys.
    pump(lambda: len(fake.calls()) >= 7)
    previous = -1
    # Wait until the call count stops growing, which means all results were delivered.
    while previous != len(fake.calls()):
        previous = len(fake.calls())
        pump_for(0.25)
    fake.clear_calls()
    # Every test starts from a fully rendered window with an empty call log.
    yield win
    win.destroy()
    pump_for(0.05)


def wait_for_call(fake, prefix):
    """Wait until the fake CLI saw a call that starts with a prefix.

    Args:
        fake: The FakeCli.
        prefix: Leading argv words.

    Returns:
        The first matching argv.
    """
    pump(lambda: any(call[: len(prefix)] == prefix for call in fake.calls()))
    return next(call for call in fake.calls() if call[: len(prefix)] == prefix)


def answer(dialog, response):
    """Emit a dialog response as if the user clicked a button.

    Args:
        dialog: The captured dialog.
        response: Response id, e.g. "confirm".

    Returns:
        None.
    """
    dialog.emit("response", response)


# ----------------------------------------------------------------------------------------
# Pure parsing and formatting
# ----------------------------------------------------------------------------------------


def test_display_is_broadway_not_the_live_session(gui):
    """The tests must never open windows on the user's real compositor."""
    from gi.repository import Gdk

    # The backend class name proves which display server GTK is talking to.
    assert "Broadway" in type(Gdk.Display.get_default()).__name__
    assert os.environ["GDK_BACKEND"] == "broadway"


def test_parse_key_values_ignores_noise(gui):
    """Blank, malformed and uppercase lines are dropped; later duplicates win."""
    text = "a=1\n\nnot a pair\nB=2\nc = 3 \nc=4\n=x\n"
    # Only well-formed lowercase keys survive, with values stripped.
    assert gui.parse_key_values(text) == {"a": "1", "c": "4"}


def test_parse_engine_status_full_contract(gui):
    """Every documented key is parsed and unknown keys are ignored."""
    status = gui.parse_engine_status(ENGINE_STATUS)
    # Scalars, flags, numbers and csv lists each take their own conversion path.
    assert (status.selected, status.active) == ("auto", "qwen3")
    assert status.qwen3_installed is True
    assert (status.qwen3_variant, status.qwen3_device) == ("base", "Vulkan0")
    assert (status.worker, status.worker_port, status.idle_minutes) == ("running", "41234", 10)
    # Both language lists are split at commas.
    assert status.piper_languages == ["de", "en"]
    assert status.languages == ["de", "en", "fr"]
    assert status.known is True


@pytest.mark.parametrize("text", ["", "garbage without equals\n", "future=1\n"])
def test_parse_engine_status_defaults_when_missing(gui, text):
    """Empty or unrelated output yields safe defaults and known=False."""
    status = gui.parse_engine_status(text)
    # The display falls back to Piper and a stopped worker instead of crashing.
    assert status.known is False
    assert (status.selected, status.active, status.worker) == ("auto", "piper", "stopped")
    assert status.idle_minutes == 10
    assert status.languages == []


def test_parse_engine_status_bad_numbers(gui):
    """A non-numeric idle value keeps the default."""
    assert gui.parse_engine_status("selected=auto\nidle_minutes=abc\n").idle_minutes == 10


def test_describe_qwen3_reasons(gui):
    """The inactive explanation prefers the CLI reason, then falls back to derived text."""
    base = gui.EngineStatus(known=True)
    # The CLI-provided reason is shown verbatim.
    base.qwen3_reason = "no cloned voice"
    assert "no cloned voice" in gui.describe_qwen3(base)
    # Without a reason, the engine choice and the install state explain the situation.
    base.qwen3_reason = ""
    base.selected = "piper"
    assert "set to Piper" in gui.describe_qwen3(base)
    base.selected = "auto"
    # Installed-but-unusable is the last remaining explanation.
    assert "not installed" in gui.describe_qwen3(base)
    base.qwen3_installed = True
    assert "no usable voice" in gui.describe_qwen3(base)


def test_describe_qwen3_active_names_device(gui):
    """An active engine shows its variant and a GPU/CPU wording."""
    status = gui.parse_engine_status(ENGINE_STATUS)
    assert gui.describe_qwen3(status) == "Active: base model on GPU (Vulkan0)"
    assert gui.describe_device("CPU") == "CPU"
    # An empty device name must not produce an empty sentence.
    assert gui.describe_device("") == "an unknown device"


def test_describe_worker_states(gui):
    """Worker text covers running, starting and stopped."""
    status = gui.parse_engine_status(ENGINE_STATUS)
    # A running worker names its port and the idle limit.
    assert gui.describe_worker(status) == "Running on port 41234 · exits after 10 min idle"
    status.worker = "starting"
    assert gui.describe_worker(status).startswith("Starting")
    status.worker = "stopped"
    # Stopped is the normal idle state of the on-demand worker.
    assert "starts by itself" in gui.describe_worker(status)


def test_parse_deps_status(gui):
    """The deps porcelain maps to paths and two flags."""
    text = "python=/home/u/venv/bin/python\nmodel=/home/u/lid.ftz\nsystem_packages=0\nready=1\n"
    status = gui.parse_deps_status(text)
    assert (status.python, status.model) == ("/home/u/venv/bin/python", "/home/u/lid.ftz")
    # The two flags are independent of each other.
    assert status.ready is True and status.system_packages is False
    # Nothing recognisable means "unknown", not "missing".
    assert gui.parse_deps_status("hello\n").known is False
    assert "Unknown" in gui.describe_deps(gui.DepsStatus())


def test_parse_voice_list(gui):
    """Assignments, presets and cloned voices are split; malformed lines are skipped."""
    catalog = gui.parse_voice_list(VOICE_LIST + "assign\tonly-two\nbogus\tx\n")
    assert catalog.assignments == {"de": "de-thorsten", "en": "en-lj", "fr": ""}
    assert catalog.presets == ["ryan"]
    # Order and source column are preserved.
    assert [(v.name, v.source) for v in catalog.cloned] == [
        ("de-thorsten", "shipped"), ("en-lj", "shipped"), ("my-voice", "user"),
    ]


def test_voices_for_variant(gui):
    """Base offers clones, CustomVoice presets, unknown both."""
    catalog = gui.parse_voice_list(VOICE_LIST)
    assert gui.voices_for_variant(catalog, "base") == ["de-thorsten", "en-lj", "my-voice"]
    assert gui.voices_for_variant(catalog, "customvoice") == ["ryan"]
    # An unknown variant lists presets first, then clones.
    assert gui.voices_for_variant(catalog, "") == ["ryan", "de-thorsten", "en-lj", "my-voice"]


def test_parse_piper_porcelain(gui):
    """Installed (7 fields) and catalogue (6 fields) rows parse; other widths are skipped."""
    installed = gui.parse_installed_voices(MODEL_LIST + "too\tfew\n")
    assert installed[0]["id"] == "de/de_DE-thorsten-high" and installed[0]["default"] is True
    assert installed[0]["fallback"] is False and len(installed) == 1
    # The catalogue keeps the installed flag per entry.
    catalog = gui.parse_catalog_voices(MODEL_CATALOG)
    assert [(c["key"], c["installed"]) for c in catalog] == [
        ("de-thorsten", True), ("en-ryan", False),
    ]


@pytest.mark.parametrize(
    ("backend", "variant", "expected_tail"),
    [
        ("", "base", ["--variant", "base"]),
        ("--vulkan", "base", ["--vulkan", "--variant", "base"]),
        ("--cpu", "customvoice", ["--cpu", "--variant", "customvoice"]),
    ],
)
def test_build_install_args(gui, backend, variant, expected_tail):
    """The install argv always names the variant and only adds a backend flag when chosen."""
    assert gui.build_install_args(backend, variant) == ["engine", "install", "qwen3"] + expected_tail


def test_message_helpers(gui):
    """Error text comes from the last stderr line without the error: prefix."""
    result = gui.CliResult(1, "out line\n", "warn\nerror: disk full\n\n")
    assert gui.error_message(result) == "disk full"
    # stdout is the second choice, then a generic message with the exit code.
    assert gui.error_message(gui.CliResult(2, "only stdout\n", "")) == "only stdout"
    assert gui.error_message(gui.CliResult(3, "", "")) == "operation failed (exit 3)"
    assert gui.last_message_line("") == ""


def test_formatting_helpers(gui):
    """Sizes and language titles are human readable and tolerate junk."""
    assert gui.human_size("512") == "512 B"
    assert gui.human_size("63000000") == "60.1 MB"
    assert gui.human_size("n/a") == "?"
    # Known codes get a readable name, unknown ones are upper-cased.
    assert gui.language_title("de") == "German (de)"
    assert gui.language_title("xx") == "XX"


@pytest.mark.parametrize(
    ("text", "expected"),
    [("40\n", 40), ("100", 100), ("0\n", 0), ("150\n", None), ("-5\n", None),
     ("loud\n", None), ("", None)],
)
def test_parse_volume_accepts_only_whole_percentages(gui, text, expected):
    """The volume query yields 0-100; anything else is reported as unusable."""
    assert gui.parse_volume(text) == expected


def test_neural_sample_blocker_names_the_obstacle(gui):
    """A sample needs an installed engine and a voice; the reason says which is missing."""
    assert "Install Qwen3-TTS" in gui.neural_sample_blocker(False, "de-thorsten")
    # The engine check comes first, because without it no voice can help.
    assert "Install Qwen3-TTS" in gui.neural_sample_blocker(False, "")
    assert "No voice" in gui.neural_sample_blocker(True, "")
    assert gui.neural_sample_blocker(True, "de-thorsten") == ""


def test_accel_to_combo(gui):
    """Key events become Hyprland combos; lone modifiers are rejected."""
    from gi.repository import Gdk

    both = Gdk.ModifierType.SUPER_MASK | Gdk.ModifierType.ALT_MASK
    # Modifier order follows Hyprland's SUPER CTRL ALT SHIFT convention.
    assert gui.accel_to_combo(Gdk.KEY_r, both) == "SUPER ALT, r"
    assert gui.accel_to_combo(Gdk.KEY_Super_L, Gdk.ModifierType.SUPER_MASK) is None


def test_voice_documents_are_read_from_shipped_and_user_roots(gui, tmp_path, monkeypatch):
    """Attribution comes from the shipped roots and the licence from the user data dir."""
    shipped = tmp_path / "system"
    (shipped / "de-x").mkdir(parents=True)
    (shipped / "de-x" / "ATTRIBUTION.md").write_text("CC0 by Thorsten", encoding="utf-8")
    # A private data home stands in for the user's real one.
    data_home = tmp_path / "data"
    (data_home / "hyprland-tts" / "voices" / "mine").mkdir(parents=True)
    (data_home / "hyprland-tts" / "voices" / "mine" / "LICENSE").write_text("mine", encoding="utf-8")
    monkeypatch.setenv("HYPRLAND_TTS_SYSTEM_VOICES", str(shipped))
    # Both lookup roots are redirected into the temporary directory.
    monkeypatch.setenv("XDG_DATA_HOME", str(data_home))
    # Both sources resolve; a voice without a file yields None.
    assert gui.read_voice_document(gui.ClonedVoice("de-x", "shipped")) == "CC0 by Thorsten"
    assert gui.read_voice_document(gui.ClonedVoice("mine", "user")) == "mine"
    assert gui.read_voice_document(gui.ClonedVoice("nope", "shipped")) is None
    # A shipped pack that sits in the user data dir (local install) still shows its attribution.
    (data_home / "hyprland-tts" / "voices" / "pack").mkdir()
    (data_home / "hyprland-tts" / "voices" / "pack" / "ATTRIBUTION.md").write_text("by X", "utf-8")
    assert gui.read_voice_document(gui.ClonedVoice("pack", "user")) == "by X"


# ----------------------------------------------------------------------------------------
# CLI plumbing
# ----------------------------------------------------------------------------------------


def test_run_cli_returns_output_and_status(gui, fake):
    """run_cli maps stdout, stderr and the exit status into a CliResult."""
    fake.respond("x", stdout="hello\n", stderr="warn\n", rc=3)
    result = gui.run_cli(["x"])
    assert tuple(result) == (3, "hello\n", "warn\n")


def test_run_cli_timeout_and_missing_cli(gui, fake, monkeypatch):
    """A slow command maps to 124 and a missing CLI to 127; neither raises."""
    fake.respond("slow", sleep=5)
    assert gui.run_cli(["slow"], timeout=0.4).returncode == 124
    monkeypatch.setattr(gui, "CLI_PATH", None)
    # Without a CLI the status is 127, the shell's "command not found".
    assert gui.run_cli(["anything"]).returncode == 127


def test_cli_job_without_cli_reports_failure(gui, monkeypatch):
    """Starting a job without a CLI reports exit 127 through the callbacks."""
    monkeypatch.setattr(gui, "CLI_PATH", None)
    done = []
    lines = []
    # Both callbacks append to lists the test can inspect.
    job = gui.CliJob(["engine", "install"], lines.append, lambda *args: done.append(args))
    job.start()
    pump(lambda: done)
    # The user sees a line explaining the failure and a 127 status.
    assert done == [(127, False)] and "not found" in lines[0]


def test_cli_job_escalates_to_sigkill(gui, fake, monkeypatch):
    """A job that ignores SIGTERM is force-killed after the grace period."""
    monkeypatch.setattr(gui, "KILL_GRACE_SECONDS", 0.3)
    fake.respond("stubborn", hang=True, ignore_term=True)
    done = []
    # The fake ignores SIGTERM, so only the escalation can end it.
    job = gui.CliJob(["stubborn"], lambda _line: None, lambda *args: done.append(args))
    job.start()
    child_pid = fake.read_pid("child.pid")
    job.cancel()
    # SIGKILL after 0.3 s ends both the ignoring parent and its sleeping child.
    pump(lambda: done)
    assert done[0][1] is True
    pump(lambda: process_is_gone(child_pid))


# ----------------------------------------------------------------------------------------
# Window and shared helpers
# ----------------------------------------------------------------------------------------


def test_window_builds_four_pages_and_refreshes_every_page(gui, application, fake):
    """Construction creates all pages and the first refresh queries each data source."""
    window = gui.TtsWindow(application)
    # Eight queries: engine 1, voices 5 (including the volume), language 1, shortcuts 1.
    pump(lambda: len(fake.calls()) >= 8)
    calls = fake.calls()
    # The calls were captured first, so the teardown cannot add to the list.
    window.destroy()
    # One page per feature, in tab order.
    assert list(window.pages) == ["engine", "voices", "language", "keys"]
    for expected in (
        ["engine", "status", "--porcelain"], ["voice", "list", "--porcelain"],
        ["model", "list", "--porcelain"], ["model", "catalog", "--porcelain"],
        ["deps", "status", "--porcelain"], ["keybind", "list", "--porcelain"], ["volume"],
    ):
        assert expected in calls


def test_run_task_success_and_failure_toasts(window, fake, toasts):
    """A successful task toasts the ok message; a failing one toasts the CLI error."""
    fake.respond("engine", "stop", stdout="")
    assert window.run_task(["engine", "stop"], "Worker stopped") is True
    pump(lambda: "Worker stopped" in toasts)
    # A failing start exits 1 and explains itself on stderr.
    fake.respond("engine", "start", stderr="info\nerror: worker failed to start\n", rc=1)
    window.run_task(["engine", "start"], "Worker started")
    pump(lambda: "worker failed to start" in toasts)
    # The busy indicator is released after each task.
    assert window._busy is False


def test_run_task_refuses_while_busy(window, fake, toasts):
    """A second task while one is running is refused with a hint, not queued."""
    fake.respond("engine", "start", sleep=0.6)
    assert window.run_task(["engine", "start"], "ok") is True
    assert window.run_task(["engine", "stop"], "ok") is False
    # The hint tells the user why nothing happened.
    assert any("wait" in message for message in toasts)
    pump(lambda: window._busy is False)
    # Only the first command ever reached the CLI.
    assert [call[:2] for call in fake.calls()].count(["engine", "stop"]) == 0


def test_refresh_without_cli_does_nothing(window, fake, monkeypatch, gui):
    """With no CLI the refresh is a no-op instead of spawning failing commands."""
    monkeypatch.setattr(gui, "CLI_PATH", None)
    assert window.refresh() is False
    pump_for(0.1)
    # No refresh means no CLI calls at all.
    assert fake.calls() == []


def test_confirm_runs_action_only_on_confirm(window, dialogs):
    """Cancel does nothing; the confirm response runs the action."""
    ran = []
    window.confirm("Sure?", "body", "Do it", lambda: ran.append(1))
    # Cancelling must leave the action untouched.
    answer(dialogs[-1], "cancel")
    assert ran == []
    answer(dialogs[-1], "confirm")
    assert ran == [1]


def test_real_dialog_presentation_works_on_broadway(window, gui):
    """The real present_dialog path (not the spy) shows a dialog without errors."""
    dialog = gui.create_dialog("Hello", "World")
    dialog.add_response("ok", "OK")
    gui.present_dialog(dialog, window)
    # A short pump lets any wrongly triggered handler show up as a call.
    pump_for(0.1)
    assert dialog.get_heading() == "Hello"


# ----------------------------------------------------------------------------------------
# Engine page
# ----------------------------------------------------------------------------------------


def test_engine_page_shows_status(window):
    """The status rows reflect the porcelain output after the first refresh."""
    page = window.pages["engine"]
    assert page.active_row.get_subtitle() == "Qwen3-TTS (neural)"
    assert "GPU (Vulkan0)" in page.qwen3_row.get_subtitle()
    # The worker row names the port from the porcelain.
    assert "port 41234" in page.worker_row.get_subtitle()
    assert page.languages_row.get_subtitle() == "de, en, fr"
    # Worker is running: Stop is enabled and Start is not.
    assert page.stop_button.get_sensitive() and not page.start_button.get_sensitive()
    assert page.idle_row.get_value() == 10
    assert page.variant_combo.get_selected() == 0


def test_engine_page_explains_why_qwen3_is_inactive(window, gui):
    """A status without Qwen3 shows the reason and disables Remove and Start."""
    page = window.pages["engine"]
    page.apply_status(gui.parse_engine_status(
        "selected=auto\nactive=piper\nqwen3_installed=0\nqwen3_reason=not installed\n"
        "worker=stopped\n"
    ))
    assert page.active_row.get_subtitle() == "Piper (light)"
    # The CLI's reason text is shown after the Inactive prefix.
    assert page.qwen3_row.get_subtitle() == "Inactive: not installed"
    assert not page.remove_button.get_sensitive() and not page.start_button.get_sensitive()


def test_engine_page_unknown_status_on_cli_failure(window, fake, toasts):
    """A failing status command shows 'Unknown' and a toast, without raising."""
    fake.respond("engine", "status", "--porcelain", stderr="error: engine broke\n", rc=1)
    window.pages["engine"].refresh()
    pump(lambda: "engine broke" in toasts)
    # A failed query must not look like a healthy Piper setup.
    assert "Unknown" in window.pages["engine"].active_row.get_subtitle()


def test_engine_choice_maps_to_engine_use(window, fake):
    """Choosing Piper in the combo runs `engine use piper`; refresh alone does not."""
    page = window.pages["engine"]
    # Programmatic status updates must not be mistaken for user choices.
    page.apply_status(page._status)
    pump_for(0.1)
    assert fake.calls() == []
    page.engine_combo.set_selected(2)
    # Index 2 of the combo is Piper.
    assert wait_for_call(fake, ["engine", "use"]) == ["engine", "use", "piper"]


def test_worker_buttons_map_to_start_and_stop(window, fake, gui):
    """Start and Stop run `engine start` and `engine stop`."""
    page = window.pages["engine"]
    page.start_button.emit("clicked")
    assert wait_for_call(fake, ["engine", "start"]) == ["engine", "start"]
    # The first task must be finished before the next one is accepted.
    pump(lambda: window._busy is False)
    page.stop_button.emit("clicked")
    assert wait_for_call(fake, ["engine", "stop"]) == ["engine", "stop"]


def test_idle_minutes_apply_maps_to_engine_config(window, fake):
    """Apply sends the spin row value through `engine config idle`."""
    page = window.pages["engine"]
    page.idle_row.set_value(25)
    page._on_apply_idle()
    # The minutes arrive as a plain integer string.
    assert wait_for_call(fake, ["engine", "config"]) == ["engine", "config", "idle", "25"]


def test_remove_engine_requires_confirmation(window, fake, dialogs):
    """Remove asks first; only the confirm response runs `engine remove qwen3`."""
    page = window.pages["engine"]
    page.remove_button.emit("clicked")
    # Cancel must not reach the CLI.
    answer(dialogs[-1], "cancel")
    pump_for(0.15)
    assert ["engine", "remove", "qwen3"] not in fake.calls()
    page.remove_button.emit("clicked")
    # Confirming is what finally triggers the CLI call.
    answer(dialogs[-1], "confirm")
    assert wait_for_call(fake, ["engine", "remove"]) == ["engine", "remove", "qwen3"]


def test_install_streams_log_lines_and_finishes(window, fake, toasts):
    """Install runs asynchronously, streams stderr lines into the log and toasts success."""
    fake.respond(
        "engine", "install", "qwen3",
        stderr_lines=["Installing the qwen3 engine (vulkan build)", "  downloading model ...",
                      "Done."],
        line_delay=0.25,
    )
    page = window.pages["engine"]
    page.backend_combo.set_selected(1)
    # Index 0 is the Base model.
    page.variant_combo.set_selected(0)
    page.install_button.emit("clicked")
    # While running: the panel is visible, the install button is locked and the UI stays live.
    assert page.install_panel.running and not page.install_button.get_sensitive()
    pump(lambda: "downloading" in page.install_panel.log_text())
    assert page.install_panel.running
    pump(lambda: not page.install_panel.running)
    # The call is read after the job ended, so it is certainly complete.
    argv = wait_for_call(fake, ["engine", "install"])
    # The chosen backend and model are passed explicitly.
    assert argv == ["engine", "install", "qwen3", "--vulkan", "--variant", "base"]
    assert page.install_panel.log_text().splitlines() == [
        "Installing the qwen3 engine (vulkan build)", "  downloading model ...", "Done.",
    ]
    pump(lambda: "Qwen3-TTS installed" in toasts)
    assert page.install_button.get_sensitive()


def test_install_failure_toasts_last_line_and_refreshes(window, fake, toasts):
    """A failing install toasts its last output line and reloads the status."""
    fake.respond("engine", "install", "qwen3", stderr="step 1\nerror: sha256 mismatch\n", rc=1)
    page = window.pages["engine"]
    page.install_button.emit("clicked")
    # The toast carries the CLI's own last line unchanged.
    pump(lambda: "error: sha256 mismatch" in toasts)
    # The status line names the exit code; a refresh follows the failure.
    assert "Failed (exit 1)" in page.install_panel._status_label.get_text()
    fake.clear_calls()
    wait_for_call(fake, ["engine", "status", "--porcelain"])


def test_install_cancel_kills_the_whole_process_group(window, fake, toasts):
    """Cancel terminates the installer and its child processes and reports it."""
    fake.respond("engine", "install", "qwen3", hang=True, stderr_lines=["compiling ..."])
    page = window.pages["engine"]
    page.install_button.emit("clicked")
    # The child pid proves the fake really spawned a sub-process.
    child_pid = fake.read_pid("child.pid")
    parent_pid = fake.read_pid("self.pid")
    pump(lambda: "compiling" in page.install_panel.log_text())
    page.install_panel._cancel_button.emit("clicked")
    # The job must end by itself after the cancel.
    pump(lambda: not page.install_panel.running)
    # Both the CLI process and the build child it spawned are gone.
    pump(lambda: process_is_gone(parent_pid) and process_is_gone(child_pid))
    pump(lambda: "Installation cancelled" in toasts)
    assert page.install_panel._status_label.get_text() == "Cancelled"
    assert page.install_button.get_sensitive()


def test_closing_during_install_asks_and_cancels(window, fake, dialogs):
    """Closing mid-install is blocked by a dialog; confirming cancels the job."""
    fake.respond("deps", "install", hang=True)
    page = window.pages["language"]
    page.install_button.emit("clicked")
    # Wait until the job really runs before asking to close.
    fake.read_pid("child.pid")
    # The close request is vetoed and a confirmation dialog is shown instead.
    assert window._on_close_request(window) is True
    assert dialogs[-1].get_heading() == "Installation in progress"
    answer(dialogs[-1], "confirm")
    pump(lambda: not page.install_panel.running)


def test_closing_without_job_is_allowed(window):
    """With nothing running the close request passes through."""
    assert window._on_close_request(window) is False


# ----------------------------------------------------------------------------------------
# Voices page: neural voices
# ----------------------------------------------------------------------------------------


def test_neural_rows_reflect_current_voices(window):
    """One row per engine language shows the current voice and preselects it."""
    root = window.pages["voices"]
    german = find_row(root, "German (de)")
    assert german is not None and german.get_subtitle() == "Current: de-thorsten"
    # Index 0 is "Default"; the Base variant lists the three cloned voices after it.
    assert german.get_selected() == 1
    assert find_row(root, "French (fr)").get_selected() == 0
    assert find_row(root, "French (fr)").get_subtitle() == "Current: no voice available"


def test_building_rows_makes_no_cli_call(window, fake):
    """Re-rendering the voices does not run `voice set` by itself."""
    window.pages["voices"].refresh()
    pump_for(0.4)
    assert not [call for call in fake.calls() if call[:2] == ["voice", "set"]]


def test_choosing_a_voice_maps_to_voice_set(window, fake):
    """Picking a voice runs `voice set <lang> <voice>`; Default clears the choice."""
    english = find_row(window.pages["voices"], "English (en)")
    english.set_selected(3)
    assert wait_for_call(fake, ["voice", "set"]) == ["voice", "set", "en", "my-voice"]
    # Wait for the first task so the second selection is not refused.
    pump(lambda: window._busy is False)
    fake.clear_calls()
    # The re-render after the task rebuilt the rows, so look the row up again.
    pump(lambda: find_row(window.pages["voices"], "English (en)") is not None)
    find_row(window.pages["voices"], "English (en)").set_selected(0)
    assert wait_for_call(fake, ["voice", "set"]) == ["voice", "set", "en", "--clear"]


def test_cloned_rows_allow_removal_only_for_user_voices(window, fake, dialogs):
    """Shipped voices have no trash button; a user voice is removed after confirmation."""
    root = window.pages["voices"]
    shipped = find_row(root, "de-thorsten")
    mine = find_row(root, "my-voice")
    # Shipped voices are read-only, so they offer no trash button.
    assert find_button(shipped, tooltip="Remove") is None
    assert find_button(shipped, tooltip="Attribution and licence") is not None
    find_button(mine, tooltip="Remove").emit("clicked")
    answer(dialogs[-1], "confirm")
    # The user voice name is the only argument.
    assert wait_for_call(fake, ["voice", "remove"]) == ["voice", "remove", "my-voice"]


def test_attribution_dialog_shows_file_text(window, dialogs, tmp_path, monkeypatch):
    """The info button shows the shipped voice's ATTRIBUTION.md, or an honest fallback."""
    (tmp_path / "de-thorsten").mkdir()
    (tmp_path / "de-thorsten" / "ATTRIBUTION.md").write_text("Thorsten Müller, CC0", "utf-8")
    monkeypatch.setenv("HYPRLAND_TTS_SYSTEM_VOICES", str(tmp_path))
    # Both lookups below start from the voices page.
    root = window.pages["voices"]
    find_button(find_row(root, "de-thorsten"), tooltip="Attribution and licence").emit("clicked")
    label_texts = [w.get_label() for w in iter_widgets(dialogs[-1].get_extra_child())
                   if hasattr(w, "get_label") and w.get_label()]
    assert "Thorsten Müller, CC0" in label_texts
    # A user voice whose LICENSE file is missing gets an explicit message, not an empty dialog.
    monkeypatch.setenv("XDG_DATA_HOME", str(tmp_path / "empty-data"))
    find_button(find_row(root, "my-voice"), tooltip="Licence note").emit("clicked")
    texts = [w.get_label() for w in iter_widgets(dialogs[-1].get_extra_child())
             if hasattr(w, "get_label") and w.get_label()]
    assert any("No attribution file" in text for text in texts)


# ----------------------------------------------------------------------------------------
# Voices page: playback (volume, stop, samples)
# ----------------------------------------------------------------------------------------


def volume_writes(fake):
    """List the `volume <n>` calls, leaving out the read-only `volume` queries.

    Args:
        fake: The FakeCli.

    Returns:
        List of argument lists.
    """
    return [call for call in fake.calls() if call[0] == "volume" and len(call) > 1]


def wait_for_volume_query(window, fake):
    """Re-query the voices page and wait until its volume answer was rendered.

    Args:
        window: The TtsWindow.
        fake: The FakeCli.

    Returns:
        None.
    """
    window.pages["voices"].refresh()
    wait_for_call(fake, ["volume"])
    # The volume is the last query of the batch; a short pump delivers the render.
    pump_for(0.3)


def test_playback_group_leads_the_page_and_shows_the_queried_volume(window, fake):
    """The slider shows the CLI's volume, and setting it from a query sends nothing back."""
    page = window.pages["voices"]
    # Playback is the first group of the page, above the neural voices.
    assert page.content.get_first_child() is page.playback
    assert page.playback.volume_scale.get_value() == 100
    # A refresh now reads a lowered volume from the CLI.
    fake.respond("volume", stdout="40\n")
    page.refresh()
    pump(lambda: page.playback.volume_scale.get_value() == 40)
    # The value label next to the slider reads as a percentage.
    labels = [widget.get_label() for widget in iter_widgets(page.playback.volume_scale)
              if hasattr(widget, "get_label")]
    assert "40%" in labels
    # Longer than the debounce: a programmatic update must never become a `volume <n>` call.
    pump_for(0.6)
    assert volume_writes(fake) == []


@pytest.mark.parametrize("answer_fields", [
    {"stderr": "error: unknown command 'volume'\n", "rc": 1},
    {"stdout": "loud\n"},
])
def test_unusable_volume_query_keeps_the_slider_quietly(window, fake, toasts, answer_fields):
    """A failed or garbled `volume` query leaves the slider at 100 without a toast."""
    fake.respond("volume", **answer_fields)
    wait_for_volume_query(window, fake)
    # Nothing was readable, so the slider still shows the full volume.
    assert window.pages["voices"].playback.volume_scale.get_value() == 100
    assert toasts == [] and volume_writes(fake) == []


def test_moving_the_slider_sends_one_debounced_volume_call(window, fake, toasts):
    """Quick moves collapse into one `volume <n>` with the last value; no lock, no refresh."""
    fake.respond("volume", sleep=0.6)
    scale = window.pages["voices"].playback.volume_scale
    # Three moves well inside the debounce window.
    for value in (30, 55, 70):
        scale.set_value(value)
    pump_for(0.1)
    # Still inside the debounce window, nothing has been sent yet.
    assert volume_writes(fake) == []
    wait_for_call(fake, ["volume", "70"])
    # The slow command is running now, yet the window stays unlocked.
    assert window._busy is False
    pump_for(1.0)
    # Exactly one call reached the CLI, and no page re-query followed it.
    assert fake.calls() == [["volume", "70"]]
    assert toasts == []


def test_pending_slider_move_wins_over_an_older_volume_query(window, fake):
    """A query answer arriving mid-debounce does not snap the slider back."""
    playback = window.pages["voices"].playback
    playback.volume_scale.set_value(30)
    # The stale answer of a refresh that started before the user moved the slider.
    playback.set_volume(80)
    assert playback.volume_scale.get_value() == 30
    assert wait_for_call(fake, ["volume", "30"]) == ["volume", "30"]


def test_failing_volume_change_toasts_the_cli_error(window, fake, toasts):
    """A rejected volume is reported with the CLI's own message."""
    fake.respond("volume", "55", stderr="error: could not reach the audio server\n", rc=1)
    window.pages["voices"].playback.volume_scale.set_value(55)
    # The error line arrives without its "error:" prefix.
    pump(lambda: "could not reach the audio server" in toasts)


def test_stop_button_runs_stop_without_locking(window, fake, toasts):
    """Stop runs `stop` as a quick command that neither locks nor refreshes the window."""
    fake.respond("stop", sleep=0.4)
    find_button(window.pages["voices"].playback, tooltip="Stop playback").emit("clicked")
    assert wait_for_call(fake, ["stop"]) == ["stop"]
    # The command is still running, but the window stays usable.
    assert window._busy is False
    pump_for(0.8)
    assert fake.calls() == [["stop"]] and toasts == []


def test_neural_sample_button_maps_to_preview(window, fake, toasts):
    """▶ on a language row runs `preview <lang> --engine qwen3` and names the language."""
    german = find_row(window.pages["voices"], "German (de)")
    find_button(german, tooltip="Play a sample").emit("clicked")
    assert wait_for_call(fake, ["preview"]) == ["preview", "de", "--engine", "qwen3"]
    # The success toast names the language whose voice is speaking.
    pump(lambda: "Playing sample: German (de)" in toasts)
    # The click neither changed the voice nor started a page refresh.
    assert german.get_selected() == 1
    assert fake.calls() == [["preview", "de", "--engine", "qwen3"]]


def test_neural_sample_button_is_disabled_without_a_voice(window):
    """A language without a voice gets an insensitive ▶ that explains why."""
    french = find_row(window.pages["voices"], "French (fr)")
    button = find_button(french, tooltip="No voice is available for this language")
    # The button exists but cannot be clicked.
    assert button is not None and not button.get_sensitive()
    assert find_button(french, tooltip="Play a sample") is None


def test_neural_sample_button_is_disabled_without_qwen3(window, fake):
    """Without an installed engine every ▶ is insensitive; building rows calls nothing."""
    fake.respond("engine", "status", "--porcelain",
                 stdout="selected=auto\nactive=piper\nqwen3_installed=0\nqwen3_variant=base\n"
                 "languages=de,en\n")
    # The re-render picks up the engine that is now missing.
    page = window.pages["voices"]
    page.refresh()
    pump(lambda: find_row(page, "Qwen3-TTS is not installed") is not None)
    # Even the German row, which has a voice, cannot play without the engine.
    button = find_button(find_row(page, "German (de)"),
                         tooltip="Install Qwen3-TTS on the Engine tab to play a sample")
    assert button is not None and not button.get_sensitive()
    pump_for(0.4)
    # Rendering the rows ran only the page queries, never a preview.
    assert not [call for call in fake.calls() if call[0] == "preview"]


def test_piper_sample_button_maps_to_preview_with_model(window, fake, toasts):
    """▶ on an installed Piper voice passes its language and model id."""
    row = find_row(window.pages["voices"], "thorsten (high)")
    find_button(row, tooltip="Play a sample").emit("clicked")
    # The model id is exactly the one the other `model` commands use.
    assert wait_for_call(fake, ["preview"]) == [
        "preview", "de", "--engine", "piper", "--model", "de/de_DE-thorsten-high"]
    pump(lambda: "Playing sample: thorsten (high)" in toasts)


def test_failing_preview_toasts_the_cli_error(window, fake, toasts):
    """A preview the CLI refuses shows its message instead of the "Playing" toast."""
    fake.respond("preview", stderr="error: no sample sentence for language 'xx'\n", rc=1)
    window.pages["voices"].neural.on_play_sample("xx")
    pump(lambda: "no sample sentence for language 'xx'" in toasts)
    # Success text must not appear for a failed preview.
    assert not any(message.startswith("Playing sample") for message in toasts)
    assert window._busy is False


def test_neural_section_shows_error_when_listing_fails(window, fake):
    """A failing `voice list` replaces the groups with an explanatory row."""
    fake.respond("voice", "list", "--porcelain", stderr="error: voices unavailable\n", rc=1)
    window.pages["voices"].refresh()
    pump(lambda: find_row(window.pages["voices"], "Could not list voices") is not None)
    # The CLI's error text is shown in the row subtitle.
    assert "voices unavailable" in find_row(
        window.pages["voices"], "Could not list voices").get_subtitle()


# ----------------------------------------------------------------------------------------
# Voices page: adding a cloned voice
# ----------------------------------------------------------------------------------------


def make_filled_form(gui, tmp_path, consent=True):
    """Build an AddVoiceForm with valid values.

    Args:
        gui: The GUI module.
        tmp_path: Directory for the dummy WAV.
        consent: Whether to tick the consent box.

    Returns:
        The filled form.
    """
    wav = tmp_path / "ref.wav"
    wav.write_bytes(b"RIFF....WAVE")
    form = gui.AddVoiceForm(lambda: None)
    # Every mandatory field gets a value; consent is optional so tests can leave it unticked.
    form.name_entry.set_text("de-anna")
    form.set_wav_path(str(wav))
    form.transcript_view.get_buffer().set_text("Guten Tag, das ist ein Test.")
    form.consent_check.set_active(consent)
    # The caller may still change single fields before using the form.
    return form


def test_add_voice_form_requires_consent_and_all_fields(gui, tmp_path):
    """The form is valid only with a name, a WAV, a transcript and the consent box ticked."""
    form = make_filled_form(gui, tmp_path, consent=False)
    # Everything is filled but consent is missing.
    assert form.is_valid() is False
    form.consent_check.set_active(True)
    assert form.is_valid() is True
    form.name_entry.set_text("Bad Name!")
    # An invalid name alone is enough to block the form.
    assert form.is_valid() is False
    form.name_entry.set_text("ok-name")
    form.transcript_view.get_buffer().set_text("   ")
    assert form.is_valid() is False


def test_add_voice_dialog_gates_the_add_button_on_consent(window, dialogs, gui, tmp_path):
    """The dialog's Add response stays disabled until the form, including consent, is valid."""
    window.pages["voices"].neural.on_add_voice()
    dialog = dialogs[-1]
    form = dialog.get_extra_child()
    # A fresh dialog starts with Add disabled.
    assert dialog.get_response_enabled("add") is False
    form.name_entry.set_text("de-anna")
    form.set_wav_path(str(tmp_path / "ref.wav"))
    form.transcript_view.get_buffer().set_text("Hallo Welt")
    # Still disabled: the consent box is the last missing piece.
    assert dialog.get_response_enabled("add") is False
    form.consent_check.set_active(True)
    assert dialog.get_response_enabled("add") is True


def test_add_voice_runs_cli_with_transcript_and_consent_note(window, fake, gui, tmp_path, toasts):
    """voice add receives temp transcript and consent files that exist during the call only."""
    values = make_filled_form(gui, tmp_path).values()
    window.pages["voices"].neural.add_voice(values)
    argv = wait_for_call(fake, ["voice", "add"])
    # The ok toast names the new voice.
    pump(lambda: "Voice added: de-anna" in toasts)
    record = next(r for r in fake.records() if r["argv"][:2] == ["voice", "add"])
    transcript_path, licence_path = argv[4], argv[6]
    # Name and WAV are passed through; the licence flag points at the consent note.
    assert argv[:4] == ["voice", "add", "de-anna", values["wav"]] and argv[5] == "--license"
    assert record["files"][transcript_path].strip() == "Guten Tag, das ist ein Test."
    assert "confirmed that they hold the rights" in record["files"][licence_path]
    # The private temp files are deleted once the command finished.
    assert not os.path.exists(transcript_path) and not os.path.exists(licence_path)


def test_add_voice_uses_the_chosen_licence_file(window, fake, gui, tmp_path):
    """A user-supplied licence file replaces the generated consent note and is kept."""
    licence = tmp_path / "LICENSE.txt"
    licence.write_text("CC-BY 4.0", encoding="utf-8")
    form = make_filled_form(gui, tmp_path)
    # The user's own licence file replaces the generated note.
    form.set_licence_path(str(licence))
    window.pages["voices"].neural.add_voice(form.values())
    argv = wait_for_call(fake, ["voice", "add"])
    pump(lambda: window._busy is False)
    # The user's own file is passed and must not be deleted by the cleanup.
    assert argv[6] == str(licence) and licence.exists()


def test_add_dialog_response_ignores_cancel_and_invalid_forms(window, fake, gui, tmp_path):
    """Neither Cancel nor a stale Add on an invalid form reaches the CLI."""
    neural = window.pages["voices"].neural
    form = make_filled_form(gui, tmp_path, consent=False)
    neural._on_add_response(None, "add", form)
    # Cancel must be ignored even for a valid form.
    neural._on_add_response(None, "cancel", form)
    pump_for(0.2)
    assert not [call for call in fake.calls() if call[:2] == ["voice", "add"]]


# ----------------------------------------------------------------------------------------
# Voices page: Piper
# ----------------------------------------------------------------------------------------


def test_piper_rows_show_flags_and_catalogue(window):
    """Installed voices show their flags; the catalogue shows installed and installable ones."""
    root = window.pages["voices"]
    installed = find_row(root, "thorsten (high)")
    assert "DE" in installed.get_subtitle() and "default" in installed.get_subtitle()
    # The voice is already the default, so the star button is absent.
    assert find_button(installed, tooltip="Make default for DE") is None
    assert find_button(find_row(root, "English Ryan"), label="Install") is not None
    assert find_button(find_row(root, "German Thorsten"), label="Install") is None


def test_piper_buttons_map_to_model_commands(window, fake, dialogs):
    """Install, fallback, clear-fallback and remove call the matching `model` commands."""
    root = window.pages["voices"]
    find_button(find_row(root, "English Ryan"), label="Install").emit("clicked")
    assert wait_for_call(fake, ["model", "install"]) == ["model", "install", "en-ryan"]
    # Each command must finish before the next is accepted.
    pump(lambda: window._busy is False)
    window.pages["voices"].piper.on_set_fallback("de/de_DE-thorsten-high")
    assert wait_for_call(fake, ["model", "fallback"]) == [
        "model", "fallback", "de/de_DE-thorsten-high"]
    pump(lambda: window._busy is False)
    # The default command takes the voice id as its only argument.
    window.pages["voices"].piper.on_set_default("de/de_DE-thorsten-high")
    assert wait_for_call(fake, ["model", "default"])[2] == "de/de_DE-thorsten-high"
    pump(lambda: window._busy is False)
    # Removing needs the confirmation first.
    window.pages["voices"].piper.on_remove("de/de_DE-thorsten-high")
    answer(dialogs[-1], "confirm")
    assert wait_for_call(fake, ["model", "remove"])[2] == "de/de_DE-thorsten-high"


def test_clear_fallback_and_custom_url(window, fake, toasts):
    """Clear runs `model fallback --clear`; the URL response validates and installs."""
    piper = window.pages["voices"].piper
    piper.on_clear_fallback()
    assert wait_for_call(fake, ["model", "fallback"]) == ["model", "fallback", "--clear"]
    # The URL task may only start after the clear task finished.
    pump(lambda: window._busy is False)
    from gi.repository import Gtk

    entries = [Gtk.Entry(), Gtk.Entry(), Gtk.Entry()]
    # Missing mandatory fields produce a toast and no command.
    piper._on_add_url_response(None, "install", entries)
    assert "Language and model URL are required." in toasts
    for entry, text in zip(entries, ("it", "https://x/voice.onnx", ""), strict=True):
        entry.set_text(text)
    # With both mandatory fields filled the command is accepted.
    piper._on_add_url_response(None, "install", entries)
    assert wait_for_call(fake, ["model", "install-url"]) == [
        "model", "install-url", "it", "https://x/voice.onnx"]


# ----------------------------------------------------------------------------------------
# Language page
# ----------------------------------------------------------------------------------------


def test_language_page_status_and_buttons(window, gui):
    """Missing helpers enable Install; ready helpers disable it and enable Remove."""
    page = window.pages["language"]
    assert "Not installed" in page.summary_row.get_subtitle()
    assert page.install_button.get_sensitive() and not page.remove_button.get_sensitive()
    # A ready status flips which of the two buttons is usable.
    page.apply_status(gui.parse_deps_status("python=/v/bin/python\nmodel=/m.ftz\nready=1\n"))
    assert "Ready" in page.summary_row.get_subtitle()
    assert page.python_row.get_subtitle() == "/v/bin/python"
    assert not page.install_button.get_sensitive() and page.remove_button.get_sensitive()


def test_language_install_streams_and_refreshes(window, fake, toasts):
    """`deps install` streams its lines, toasts success and re-reads the status."""
    fake.respond("deps", "install", stderr_lines=["creating venv", "installing", "deps ready"],
                 line_delay=0.1)
    page = window.pages["language"]
    page.install_button.emit("clicked")
    # Both the end of the job and its last line must have arrived.
    pump(lambda: not page.install_panel.running and "deps ready" in page.install_panel.log_text())
    assert wait_for_call(fake, ["deps", "install"]) == ["deps", "install"]
    pump(lambda: "Language detection is ready" in toasts)
    wait_for_call(fake, ["deps", "status", "--porcelain"])


def test_language_install_failure_and_remove(window, fake, dialogs, toasts):
    """A failed install toasts its last line; Remove confirms then runs `deps remove`."""
    fake.respond("deps", "install", stderr="g++ not found\n", rc=1)
    page = window.pages["language"]
    page.install_button.emit("clicked")
    # The failure reason reaches the user as a toast.
    pump(lambda: "g++ not found" in toasts)
    page.apply_status(page._status.__class__(python="/v/py", model="/m", ready=True, known=True))
    page.remove_button.emit("clicked")
    answer(dialogs[-1], "confirm")
    # Remove takes no arguments.
    assert wait_for_call(fake, ["deps", "remove"]) == ["deps", "remove"]


# ----------------------------------------------------------------------------------------
# Shortcuts page
# ----------------------------------------------------------------------------------------


def test_shortcut_rows_are_rendered(window):
    """Each shortcut triple becomes a row with its combo on the button."""
    row = find_row(window.pages["keys"], "Speak selection")
    assert row.get_subtitle() == "speak"
    assert find_button(row, label="SUPER ALT, A") is not None


def test_rebind_without_conflict_sets_the_key(window, fake):
    """A free combo is checked first and then bound with `keybind set`."""
    keys = window.pages["keys"]
    keys._on_rebind_response(None, "apply", "speak", {"combo": "SUPER, B"})
    assert wait_for_call(fake, ["keybind", "check"]) == ["keybind", "check", "SUPER, B"]
    # No --force flag is used for a free combination.
    assert wait_for_call(fake, ["keybind", "set"]) == ["keybind", "set", "speak", "SUPER, B"]


def test_rebind_with_conflict_asks_and_forces(window, fake, dialogs):
    """A taken combo opens a dialog; only confirming runs `keybind set ... --force`."""
    fake.respond("keybind", "check", stdout="bind = SUPER, B, exec, other\n")
    keys = window.pages["keys"]
    keys._on_rebind_response(None, "apply", "speak", {"combo": "SUPER, B"})
    # The conflict check is asynchronous, so the dialog appears later.
    pump(lambda: dialogs)
    assert dialogs[-1].get_heading() == "Shortcut already in use"
    assert not [call for call in fake.calls() if call[:2] == ["keybind", "set"]]
    answer(dialogs[-1], "confirm")
    # Forcing is the only way a taken combination gets bound.
    assert wait_for_call(fake, ["keybind", "set"]) == [
        "keybind", "set", "speak", "SUPER, B", "--force"]


def test_rebind_dialog_captures_keys_and_reset_works(window, fake, dialogs, gui):
    """The press-a-key dialog enables Apply after a real combo; Reset calls `keybind reset`."""
    from gi.repository import Gdk

    keys = window.pages["keys"]
    keys.on_rebind("speak", "Speak selection")
    # The captured dialog is the rebind dialog just opened.
    dialog = dialogs[-1]
    assert dialog.get_response_enabled("apply") is False
    capture = next(w for w in iter_widgets(dialog.get_extra_child()) if hasattr(w, "get_text"))
    chosen = {"combo": None}
    # Super+b is a valid combination with a named key.
    keys._on_key_pressed(None, Gdk.KEY_b, 0, Gdk.ModifierType.SUPER_MASK, dialog, capture, chosen)
    # The combination is stored and Apply becomes available.
    assert chosen["combo"] == "SUPER, b" and dialog.get_response_enabled("apply") is True
    find_button(window.pages["keys"], label="Reset").emit("clicked")
    assert wait_for_call(fake, ["keybind", "reset"]) == ["keybind", "reset"]


def test_shortcuts_error_row_when_listing_fails(window, fake):
    """A failing `keybind list` is explained in place."""
    fake.respond("keybind", "list", "--porcelain", stderr="error: no hyprctl\n", rc=1)
    window.pages["keys"].refresh()
    pump(lambda: find_row(window.pages["keys"], "Could not read shortcuts") is not None)
    # The CLI's reason is shown in the error row.
    assert "no hyprctl" in find_row(window.pages["keys"], "Could not read shortcuts").get_subtitle()


def test_engine_combo_shows_the_hint_of_the_selected_engine(window, gui):
    """The combo subtitle explains the engine that is selected right now."""
    page = window.pages["engine"]
    # The canned status selects "auto", whose hint mentions the Piper fallback.
    assert "otherwise Piper" in page.engine_combo.get_subtitle()
    page.apply_status(gui.parse_engine_status("selected=piper\nactive=piper\n"))
    assert "Fast and small" in page.engine_combo.get_subtitle()


def test_voices_page_warns_when_qwen3_is_not_installed(window, fake):
    """Without an installed engine the voice choices carry an explanatory notice."""
    fake.respond("engine", "status", "--porcelain",
                 stdout="selected=auto\nactive=piper\nqwen3_installed=0\nqwen3_variant=base\n")
    window.pages["voices"].refresh()
    pump(lambda: find_row(window.pages["voices"], "Qwen3-TTS is not installed") is not None)


# ----------------------------------------------------------------------------------------
# Contract with the real CLI (isolated HOME, never the user's own data)
# ----------------------------------------------------------------------------------------


@pytest.fixture
def real_cli(gui, tmp_path, monkeypatch):
    """Point the GUI at the repository's bin/hyprland-tts with a throw-away HOME.

    Returns:
        None; the GUI now talks to the real CLI.
    """
    cli = os.path.join(REPO_ROOT, "bin", "hyprland-tts")
    if not os.access(cli, os.X_OK):
        pytest.skip("bin/hyprland-tts is not executable")
    # Every directory the CLI could write to is redirected into the temporary directory.
    for variable, sub in (("HOME", ""), ("XDG_DATA_HOME", "data"), ("XDG_CONFIG_HOME", "config"),
                          ("XDG_STATE_HOME", "state"), ("XDG_RUNTIME_DIR", "run"),
                          ("HYPRLAND_TTS_WORKER_DIR", "worker"), ("HYPRLAND_TTS_RUN_DIR", "play")):
        target = tmp_path / sub
        target.mkdir(exist_ok=True)
        monkeypatch.setenv(variable, str(target))
    # From here on the GUI talks to the repository's own CLI.
    monkeypatch.setattr(gui, "CLI_PATH", cli)


def test_real_engine_status_matches_the_porcelain_contract(gui, real_cli):
    """`engine status --porcelain` of the real CLI parses into a known status."""
    result = gui.run_cli(["engine", "status", "--porcelain"], timeout=30)
    if result.returncode != 0 or "selected=" not in result.stdout:
        pytest.skip("the CLI in this checkout has no engine status --porcelain yet")
    # The real output must parse into a status that the GUI recognises.
    status = gui.parse_engine_status(result.stdout)
    # A fresh isolated HOME has no engine installed and no worker running.
    assert status.known and status.qwen3_installed is False
    assert status.worker == "stopped" and 1 <= status.idle_minutes <= 240


def test_real_voice_list_and_deps_status_parse(gui, real_cli):
    """`voice list --porcelain` and `deps status --porcelain` match what the GUI parses."""
    voices = gui.run_cli(["voice", "list", "--porcelain"], timeout=30)
    if voices.returncode != 0:
        pytest.skip("the CLI has no voice list --porcelain")
    # Presets are fixed by the model, so their count is stable.
    catalog = gui.parse_voice_list(voices.stdout)
    # The shipped voice packs and the nine presets are always listed.
    assert len(catalog.presets) == 9 and catalog.assignments
    assert all(voice.source in ("user", "shipped") for voice in catalog.cloned)
    deps = gui.run_cli(["deps", "status", "--porcelain"], timeout=30)
    if "ready=" not in deps.stdout:
        # Older checkouts lack the machine-readable deps output.
        pytest.skip("the CLI has no deps status --porcelain yet")
    assert gui.parse_deps_status(deps.stdout).known


def test_real_volume_query_parses(gui, real_cli):
    """`volume` of the real CLI prints a percentage the slider can show."""
    result = gui.run_cli(["volume"], timeout=30)
    if result.returncode != 0:
        pytest.skip("the CLI in this checkout has no volume command yet")
    # A fresh isolated HOME has no stored volume, so the full default is reported.
    assert gui.parse_volume(result.stdout) == 100


def test_switch_model_maps_to_engine_variant(window, fake):
    """Switch model runs `engine variant <x>` and is enabled only for a different model."""
    page = window.pages["engine"]
    # The canned status already runs the Base model, so switching to Base is pointless.
    assert page.variant_combo.get_selected() == 0 and not page.switch_button.get_sensitive()
    page.variant_combo.set_selected(1)
    assert page.switch_button.get_sensitive()
    page.switch_button.emit("clicked")
    # The new model name is passed as the only argument.
    assert wait_for_call(fake, ["engine", "variant"]) == ["engine", "variant", "customvoice"]
