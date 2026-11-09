# Maintainer: artibex <korbinian.maag@gmail.com>
pkgname=hyprland-tts
pkgver=1.1.0
pkgrel=3
pkgdesc="Accessible, multilingual, offline Text-to-Speech for Hyprland (Piper, optional Qwen3-TTS) with smart playback controls and a voice manager"
arch=('any')
url="https://github.com/artibex/hyprland-tts"
license=('GPL3')
depends=('bash' 'piper-tts-bin' 'wl-clipboard' 'mpv' 'socat' 'procps-ng' 'curl' 'gawk' 'sed' 'grep'
         'util-linux' 'findutils' 'gtk4' 'libadwaita' 'python-gobject')
optdepends=(
  'hyprland: target compositor for keybinds and the hover command'
  'tesseract: read text inside copied images (OCR)'
  'tesseract-data-eng: English OCR language data'
  'perl-image-exiftool: read embedded image description metadata'
  'at-spi2-core: speak text under the mouse cursor (hyprland-tts hover)'
  'libnotify: desktop notifications when a keybind-triggered action fails silently'
  'cmake: build the Qwen3 neural engine (hyprland-tts engine install qwen3)'
  'git: fetch the pinned Qwen3 engine sources (hyprland-tts engine install qwen3)'
  'gcc: compile the Qwen3 neural engine (hyprland-tts engine install qwen3)'
  'make: compile the Qwen3 neural engine (hyprland-tts engine install qwen3)'
  'shaderc: glslc shader compiler for the GPU (Vulkan) build of the Qwen3 engine'
  'vulkan-icd-loader: Vulkan loader for the GPU build of the Qwen3 engine'
  'vulkan-headers: Vulkan headers for the GPU build (pinned ones are fetched if absent)'
  'spirv-headers: SPIR-V headers for the GPU build (pinned ones are fetched if absent)'
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
