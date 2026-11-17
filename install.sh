#!/usr/bin/env bash
# install.sh - fallback installer for distros without a clean .deb path,
# especially Arch-based systems such as Orange Pi OS (Arch) / Arch Linux ARM.
# On Debian-family systems this simply builds and installs the .deb.

set -u

here="$(cd "$(dirname "$0")" && pwd)"

if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
elif command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
else
    echo "ERROR: run as root or install sudo first." >&2
    exit 1
fi

arch="$(uname -m)"
if [ "$arch" != "aarch64" ]; then
    echo "WARNING: this launcher targets aarch64; detected $arch. Continuing anyway." >&2
fi

# --------------------------------------------------------------------------
# Helper: install launcher files (non-dpkg path, e.g. Arch)
# --------------------------------------------------------------------------
install_files_local() {
    local prefix="$1"   # /usr or /usr/local
    $SUDO install -Dm755 "$here/src/roblox-launcher" "$prefix/bin/roblox-launcher"
    for lib in "$here"/src/lib/*.sh; do
        $SUDO install -Dm644 "$lib" "$prefix/lib/roblox-arm64-launcher/lib/$(basename "$lib")"
    done
    $SUDO install -Dm644 "$here/packaging/roblox-launcher.desktop" "$prefix/share/applications/roblox-launcher.desktop"
    $SUDO install -Dm644 "$here/packaging/roblox-arm64-launcher.svg" "$prefix/share/icons/hicolor/scalable/apps/roblox-arm64-launcher.svg"
    $SUDO install -Dm644 "$here/README.md" "$prefix/share/doc/roblox-arm64-launcher/README.md"
    $SUDO mkdir -p "$prefix/lib/roblox-arm64-launcher"
    command -v update-desktop-database >/dev/null 2>&1 && $SUDO update-desktop-database -q || true
    echo "Installed launcher to $prefix (bin, lib, desktop, icon)."
}

# --------------------------------------------------------------------------
# Path 1: Debian/Ubuntu/Armbian/Raspberry Pi OS -> build + install the .deb
# --------------------------------------------------------------------------
if command -v dpkg >/dev/null 2>&1; then
    echo "== Debian-family detected: building and installing the .deb =="
    bash "$here/build-deb.sh" || { echo "ERROR: .deb build failed." >&2; exit 1; }
    deb="$(ls -t "$here"/dist/roblox-arm64-launcher_*_arm64.deb 2>/dev/null | head -n1)"
    [ -n "$deb" ] || { echo "ERROR: built .deb not found." >&2; exit 1; }
    $SUDO apt-get install -y "$deb" || $SUDO dpkg -i "$deb" || $SUDO apt-get -f install -y
    echo
    echo "Done. Now run:  roblox-launcher setup"
    exit 0
fi

# --------------------------------------------------------------------------
# Path 2: Arch-based (Orange Pi OS Arch, Arch Linux ARM, Manjaro ARM, ...)
# --------------------------------------------------------------------------
if command -v pacman >/dev/null 2>&1; then
    echo "== Arch-family detected (pacman) =="

    echo "-- Installing repo packages: gamescope libcec pipewire --"
    $SUDO pacman -S --needed --noconfirm --asdeps gamescope libcec pipewire || true

    # PulseAudio/PipeWire bridge for Waydroid audio
    pacman -Qi pipewire-pulse >/dev/null 2>&1 || $SUDO pacman -S --needed --noconfirm pipewire-pulse || true

    echo "-- Waydroid: official repos do not ship it; using the AUR --"
    if pacman -Qi waydroid >/dev/null 2>&1; then
        echo "   waydroid already installed."
    elif command -v yay >/dev/null 2>&1; then
        yay -S --needed --noconfirm waydroid || { echo "ERROR: yay failed to install waydroid." >&2; exit 1; }
    elif command -v paru >/dev/null 2>&1; then
        paru -S --needed --noconfirm waydroid || { echo "ERROR: paru failed to install waydroid." >&2; exit 1; }
    else
        echo "   No AUR helper found. Building waydroid from the AUR with makepkg..."
        command -v git >/dev/null 2>&1 || $SUDO pacman -S --needed --noconfirm git || true
        command -v base-devel >/dev/null 2>&1 || $SUDO pacman -S --needed --noconfirm base-devel || true
        tmpdir="$(mktemp -d)"
        git clone --depth 1 https://aur.archlinux.org/waydroid.git "$tmpdir/waydroid" \
            || { echo "ERROR: cannot clone AUR/waydroid." >&2; exit 1; }
        ( cd "$tmpdir/waydroid" && makepkg -si --noconfirm ) \
            || { echo "ERROR: makepkg failed. Install manually: https://aur.archlinux.org/packages/waydroid" >&2; exit 1; }
        rm -rf "$tmpdir"
    fi

    echo "-- Installing launcher files to /usr/local --"
    install_files_local /usr/local

    # Zero-bloat: the container service must not auto-start at boot
    $SUDO systemctl disable waydroid-container.service >/dev/null 2>&1 || true

    echo
    echo "Done. Now run:"
    echo "   roblox-launcher setup"
    echo "   roblox-launcher play"
    echo
    echo "Tip: on Arch, run 'roblox-launcher doctor' if the hardware gate or"
    echo "graphics (Panfrost/Panthor) give you trouble."
    exit 0
fi

echo "ERROR: unsupported distro (no dpkg, no pacman)."
echo "Supported: Debian / Ubuntu / Armbian / Raspberry Pi OS (.deb path),"
echo "           Arch / Orange Pi OS Arch (pacman path)."
exit 1
