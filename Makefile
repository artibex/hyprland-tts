# hyprland-tts — install/uninstall, checks and the QA gate.
# Used by the PKGBUILD (DESTDIR + PREFIX=/usr) and by the local installer
# (PREFIX=$HOME/.local). Installs only static, versioned assets; per-user
# wiring is done by `hyprland-tts setup`, never here.

PREFIX  ?= /usr
DESTDIR ?=

BINDIR   = $(DESTDIR)$(PREFIX)/bin
LIBDIR   = $(DESTDIR)$(PREFIX)/lib/hyprland-tts
APPDIR   = $(DESTDIR)$(PREFIX)/share/applications
DOCDIR   = $(DESTDIR)$(PREFIX)/share/doc/hyprland-tts
LICDIR   = $(DESTDIR)$(PREFIX)/share/licenses/hyprland-tts
SHAREDIR = $(DESTDIR)$(PREFIX)/share/hyprland-tts

# Every sourced module, in the order the dispatcher loads them.
LIBS = common text router model image keybind engine qwen3 qwen3_install worker voices \
       pyenv player setup hover

# Optional documents: installed when present, so a partial checkout still builds.
OPTIONAL_DOCS = THIRD_PARTY.md CHANGELOG.md

.PHONY: all install uninstall check test qa

all:
	@echo "Nothing to build. Run 'make install' (optionally with PREFIX/DESTDIR)."

# Syntax-check every script and byte-compile every Python file.
check:
	bash -n bin/hyprland-tts install-tts.sh uninstall-tts.sh
	for m in $(LIBS); do bash -n lib/$$m.sh || exit 1; done
	python3 -m py_compile gui/hyprland-tts-gui lib/hover-read.py lib/py/*.py
	python3 -m py_compile tools/qa/qa-precheck.py tools/qa/comment-runs.py

test:
	bash tests/run.sh

# The coding-standard gate (R1-R7 for shell, docstrings and comment runs for Python).
qa:
	python3 tools/qa/qa-precheck.py .
	python3 tools/qa/qa-precheck.py . gui/hyprland-tts-gui tests/gui/*.py
	python3 tools/qa/comment-runs.py lib/hover-read.py lib/py/*.py tests/lib/*.py tests/gui/*.py
	# The GUI has no .py suffix, so the comment checker reads it through a .py copy.
	gui_copy="$$(mktemp --suffix=.py)" && cp gui/hyprland-tts-gui "$$gui_copy" && \
	  python3 tools/qa/comment-runs.py "$$gui_copy"; status=$$?; rm -f "$$gui_copy"; exit $$status

install:
	install -Dm755 bin/hyprland-tts        $(BINDIR)/hyprland-tts
	install -Dm755 gui/hyprland-tts-gui    $(BINDIR)/hyprland-tts-gui
	for m in $(LIBS); do install -Dm644 lib/$$m.sh $(LIBDIR)/$$m.sh || exit 1; done
	for f in lib/py/*.py lib/py/requirements.txt; do \
	  install -Dm644 "$$f" "$(LIBDIR)/py/$$(basename "$$f")" || exit 1; done
	if [ -d share/voices ]; then (cd share/voices && find . -type f) | while read -r f; do \
	  install -Dm644 "share/voices/$$f" "$(SHAREDIR)/shipped-voices/$$f" || exit 1; done; fi
	install -Dm755 lib/hover-read.py       $(LIBDIR)/hover-read.py
	install -Dm644 share/applications/hyprland-tts.desktop $(APPDIR)/hyprland-tts.desktop
	install -Dm644 share/tts.conf.sample   $(DOCDIR)/tts.conf.sample
	install -Dm644 README.md               $(DOCDIR)/README.md
	install -Dm644 Agent.md                $(DOCDIR)/Agent.md
	for f in $(OPTIONAL_DOCS); do \
	  [ ! -f "$$f" ] || install -Dm644 "$$f" "$(DOCDIR)/$$f" || exit 1; done
	install -Dm644 LICENSE                 $(LICDIR)/LICENSE

uninstall:
	rm -f  $(BINDIR)/hyprland-tts
	rm -f  $(BINDIR)/hyprland-tts-gui
	rm -rf $(LIBDIR)
	rm -rf $(SHAREDIR)
	rm -f  $(APPDIR)/hyprland-tts.desktop
	rm -rf $(DOCDIR)
	rm -rf $(LICDIR)
