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
source=("$pkgname-$pkgver.tar.gz::$url/archive/refs/tags/v$pkgver.tar.gz")
sha256sums=('SKIP')  # TODO: replace with the real checksum once the tag is published

package() {
  cd "$srcdir/$pkgname-$pkgver"
  make PREFIX=/usr DESTDIR="$pkgdir" install
}

# After install, each user runs:  hyprland-tts setup
# ...to wire the keybinds into their own ~/.config/hypr, then installs a voice
# via `hyprland-tts gui` or `hyprland-tts model install <key>`.
