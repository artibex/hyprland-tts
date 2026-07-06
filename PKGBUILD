# Maintainer: artibex <korbinian.maag@gmail.com>
pkgname=hyprland-tts
pkgver=1.1.0
pkgrel=1
pkgdesc="Accessible, multilingual, offline Text-to-Speech for Hyprland (Piper) with smart playback controls and a voice manager"
arch=('any')
url="https://github.com/artibex/hyprland-tts"
license=('GPL3')
depends=('bash' 'piper-tts-bin' 'wl-clipboard' 'alsa-utils' 'procps-ng' 'curl' 'gawk' 'sed' 'grep')
optdepends=(
  'gtk4: graphical voice manager'
  'libadwaita: graphical voice manager'
  'python-gobject: graphical voice manager'
  'hyprland: target compositor for keybinds'
)
makedepends=('make')

# ---------------------------------------------------------------------------
# LOCAL / DEV BUILD (default): builds from this working tree. Run `makepkg`
# from inside the repo. No git tag or network needed — picks up your current
# files. This is what to use while iterating on `main`.
# ---------------------------------------------------------------------------
source=()
sha256sums=()

package() {
  cd "$startdir"
  make PREFIX=/usr DESTDIR="$pkgdir" install
}

# ---------------------------------------------------------------------------
# AUR RELEASE BUILD: when you publish, tag a release and swap the block above
# for the two lines below (and drop the local package() cd), then regenerate
# .SRCINFO with `makepkg --printsrcinfo > .SRCINFO`:
#
#   source=("$pkgname-$pkgver.tar.gz::$url/archive/refs/tags/v$pkgver.tar.gz")
#   sha256sums=('SKIP')   # replace SKIP with the real checksum
#
#   package() {
#     cd "$srcdir/$pkgname-$pkgver"
#     make PREFIX=/usr DESTDIR="$pkgdir" install
#   }
#
# Tag + push a release with:
#   git tag v1.1.0 && git push origin v1.1.0
# ---------------------------------------------------------------------------

# After install, each user runs:  hyprland-tts setup
# ...to wire the keybinds into their own ~/.config/hypr, then installs a voice
# via `hyprland-tts gui` or `hyprland-tts model install <key>`.
