# hyprland-tts — install/uninstall
# Used by the PKGBUILD (DESTDIR + PREFIX=/usr) and by the local installer
# (PREFIX=$HOME/.local). Installs only static, versioned assets; per-user
# wiring is done by `hyprland-tts setup`, never here.

PREFIX  ?= /usr
DESTDIR ?=

BINDIR   = $(DESTDIR)$(PREFIX)/bin
APPDIR   = $(DESTDIR)$(PREFIX)/share/applications
DOCDIR   = $(DESTDIR)$(PREFIX)/share/doc/hyprland-tts
LICDIR   = $(DESTDIR)$(PREFIX)/share/licenses/hyprland-tts

.PHONY: all install uninstall check

all:
	@echo "Nothing to build. Run 'make install' (optionally with PREFIX/DESTDIR)."

check:
	bash -n bin/hyprland-tts
	python3 -m py_compile gui/hyprland-tts-gui

install:
	install -Dm755 bin/hyprland-tts        $(BINDIR)/hyprland-tts
	install -Dm755 gui/hyprland-tts-gui    $(BINDIR)/hyprland-tts-gui
	install -Dm644 share/applications/hyprland-tts.desktop $(APPDIR)/hyprland-tts.desktop
	install -Dm644 share/tts.conf.sample   $(DOCDIR)/tts.conf.sample
	install -Dm644 README.md               $(DOCDIR)/README.md
	install -Dm644 Agent.md                $(DOCDIR)/Agent.md
	install -Dm644 LICENSE                 $(LICDIR)/LICENSE

uninstall:
	rm -f  $(BINDIR)/hyprland-tts
	rm -f  $(BINDIR)/hyprland-tts-gui
	rm -f  $(APPDIR)/hyprland-tts.desktop
	rm -rf $(DOCDIR)
	rm -rf $(LICDIR)
