# hyprland-tts — install/uninstall
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

# pyenv is optional at build time: it may be absent while that module is in development.
LIBS = common text router model image keybind engine qwen3 qwen3_install worker voices \
       pyenv player setup hover

.PHONY: all install uninstall check test

all:
	@echo "Nothing to build. Run 'make install' (optionally with PREFIX/DESTDIR)."

check:
	bash -n bin/hyprland-tts
	for m in $(LIBS); do [ -f lib/$$m.sh ] || [ "$$m" = pyenv ] || exit 1; \
	  [ ! -f lib/$$m.sh ] || bash -n lib/$$m.sh; done
	python3 -m py_compile gui/hyprland-tts-gui
	python3 -m py_compile lib/hover-read.py
	for f in lib/py/*.py; do [ ! -f "$$f" ] || python3 -m py_compile "$$f"; done

test:
	bash tests/run.sh

install:
	install -Dm755 bin/hyprland-tts        $(BINDIR)/hyprland-tts
	install -Dm755 gui/hyprland-tts-gui    $(BINDIR)/hyprland-tts-gui
	for m in $(LIBS); do \
	  if [ -f lib/$$m.sh ]; then install -Dm644 lib/$$m.sh $(LIBDIR)/$$m.sh; \
	  elif [ "$$m" != pyenv ]; then echo "missing lib/$$m.sh" >&2; exit 1; fi; done
	for f in lib/py/*.py; do \
	  [ ! -f "$$f" ] || install -Dm644 "$$f" $(LIBDIR)/py/$$(basename "$$f"); done
	if [ -d share/voices ]; then (cd share/voices && find . -type f) | while read -r f; do \
	  install -Dm644 "share/voices/$$f" "$(SHAREDIR)/voices/$$f"; done; fi
	install -Dm755 lib/hover-read.py       $(LIBDIR)/hover-read.py
	install -Dm644 share/applications/hyprland-tts.desktop $(APPDIR)/hyprland-tts.desktop
	install -Dm644 share/tts.conf.sample   $(DOCDIR)/tts.conf.sample
	install -Dm644 README.md               $(DOCDIR)/README.md
	install -Dm644 Agent.md                $(DOCDIR)/Agent.md
	install -Dm644 LICENSE                 $(LICDIR)/LICENSE

uninstall:
	rm -f  $(BINDIR)/hyprland-tts
	rm -f  $(BINDIR)/hyprland-tts-gui
	rm -rf $(LIBDIR)
	rm -rf $(SHAREDIR)
	rm -f  $(APPDIR)/hyprland-tts.desktop
	rm -rf $(DOCDIR)
	rm -rf $(LICDIR)
