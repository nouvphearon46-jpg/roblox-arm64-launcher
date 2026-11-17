# distro.sh - distro-specific setup (blueprint item 1, second bullet)
# Adds the official Waydroid apt repository, installs packages, switches
# Raspberry Pi OS to a 4K-page kernel, disables Waydroid autostart and
# masks any Waydroid desktop icons.

DISTRO_ID=""
DISTRO_LIKE=""
DISTRO_CODENAME=""
DISTRO_FAMILY="unknown"

detect_distro() {
    if [ ! -r /etc/os-release ]; then
        DISTRO_FAMILY="unknown"
        return 1
    fi
    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO_ID="${ID:-unknown}"
    DISTRO_LIKE="${ID_LIKE:-}"
    DISTRO_CODENAME="${VERSION_CODENAME:-}"
    case "$DISTRO_ID $DISTRO_LIKE" in
        *raspbian*|*debian*|*armbian*|*ubuntu*) DISTRO_FAMILY="debian" ;;
        *) DISTRO_FAMILY="unknown" ;;
    esac
    log_info "Distro: ID=$DISTRO_ID codename=${DISTRO_CODENAME:-none} family=$DISTRO_FAMILY"
    return 0
}

# Suites that repo.waydro.id publishes. Anything else falls back to the
# distro-agnostic "waydroid" suite.
waydroid_repo_suite() {
    case "${DISTRO_CODENAME}" in
        buster|bullseye|bookworm|trixie|focal|jammy|noble|oracular|plucky|questing)
            printf '%s' "$DISTRO_CODENAME" ;;
        *)
            printf '%s' "waydroid" ;;
    esac
}

apt_repo_waydroid() {
    banner "APT repository: official Waydroid repo"

    if [ -f /etc/apt/sources.list.d/waydroid.list ]; then
        log_ok "Waydroid apt repository already configured."
    else
        log_info "Fetching Waydroid repository signing key..."
        root_run mkdir -p /usr/share/keyrings
        if ! root_run curl -fsSL --retry 3 -o /usr/share/keyrings/waydroid.gpg https://repo.waydro.id/waydroid.gpg; then
            die "Could not download https://repo.waydro.id/waydroid.gpg - check network access to repo.waydro.id." 1
        fi
        local suite
        suite="$(waydroid_repo_suite)"
        log_info "Writing /etc/apt/sources.list.d/waydroid.list (suite: $suite)"
        printf 'deb [arch=arm64 signed-by=/usr/share/keyrings/waydroid.gpg] https://repo.waydro.id/ %s main\n' "$suite" \
            | root_run tee /etc/apt/sources.list.d/waydroid.list >/dev/null
    fi

    log_info "Running apt-get update (this can take a minute)..."
    if ! root_run env DEBIAN_FRONTEND=noninteractive apt-get update; then
        die "apt-get update failed. Check network connectivity and try again." 1
    fi

    # Verify waydroid is actually resolvable; otherwise retry with generic suite
    if ! apt-cache policy waydroid 2>/dev/null | grep -q "Candidate:"; then
        die "apt-cache could not query waydroid package." 1
    fi
    if apt-cache policy waydroid 2>/dev/null | awk '/Candidate:/ {exit !($2=="(none)")}' ; then
        log_warn "Waydroid not found in suite '${DISTRO_CODENAME:-?}' - switching to generic 'waydroid' suite."
        printf 'deb [arch=arm64 signed-by=/usr/share/keyrings/waydroid.gpg] https://repo.waydro.id/ waydroid main\n' \
            | root_run tee /etc/apt/sources.list.d/waydroid.list >/dev/null
        root_run env DEBIAN_FRONTEND=noninteractive apt-get update || true
    fi
    log_ok "Waydroid apt repository ready."
}

apt_install_pkgs() {
    banner "Installing host packages"
    local pkgs="waydroid gamescope cec-utils curl ca-certificates"
    # zenity is optional (GUI confirmations)
    if apt-cache show zenity >/dev/null 2>&1; then
        pkgs="$pkgs zenity"
    fi
    # Audio: prefer PipeWire; only install pipewire-pulse when no pulse server exists
    if have pactl && pactl info 2>/dev/null | grep -qi pipewire; then
        log_ok "PipeWire audio already active."
    elif have pactl; then
        log_warn "Legacy PulseAudio detected. Audio will work, but PipeWire is recommended."
    else
        pkgs="$pkgs pipewire-pulse wireplumber"
    fi
    log_info "Installing: $pkgs"
    if ! root_run env DEBIAN_FRONTEND=noninteractive apt-get install -y $pkgs; then
        die "Package installation failed. Review apt output above." 1
    fi
    log_ok "Host packages installed."
    if ! have gamescope; then
        log_warn "gamescope binary still missing after install; the launcher will fall"
        log_warn "back to a direct Waydroid window (maximize manually, e.g. Super+Up)."
    fi
}

# Raspberry Pi OS: 16K-page kernel (kernel_2712.img on Pi 5) breaks the
# Android binder. Switch to kernel8.img (4K pages) in the firmware config.
pi_page_kernel_fix() {
    banner "Raspberry Pi 4K-page kernel check"
    local page
    page="$(get_page_size)"
    if [ "$page" != "16384" ]; then
        log_ok "Page size is 4K (or not a 16K system) - no kernel switch needed."
        return 0
    fi

    local cfg="" found=0
    for cfg in $PI_CONFIG_CANDIDATES; do
        if [ -f "$cfg" ]; then found=1; break; fi
    done
    if [ "$found" = "0" ]; then
        die "16K pages detected but no /boot/firmware/config.txt found to fix." 1
    fi

    log_warn "16K-page kernel active. Editing $cfg to force kernel8.img (4K pages)."
    if ! confirm "Switch Raspberry Pi OS to the 4K-page kernel (kernel8.img) now? A reboot will be required." "y"; then
        log_warn "Skipped kernel switch. Waydroid WILL NOT WORK until the page size is 4K."
        state_set reboot-required 1
        return 0
    fi

    # Backup once
    if [ ! -f "$RT_BACKUP_DIR/config.txt.orig" ]; then
        root_run cp "$cfg" "$RT_BACKUP_DIR/config.txt.orig" \
            || die "Failed to back up $cfg" 1
        log_ok "Backed up $cfg to $RT_BACKUP_DIR/config.txt.orig"
    fi

    # Copy-edit-copy-back (avoids quoting issues in root context)
    root_run cp "$cfg" "$RT_CACHE_DIR/config.txt.work"
    if grep -qE '^[[:space:]]*kernel[[:space:]]*=' "$RT_CACHE_DIR/config.txt.work"; then
        sed -i -E 's|^[[:space:]]*kernel[[:space:]]*=.*|kernel=kernel8.img|' "$RT_CACHE_DIR/config.txt.work"
    else
        printf '\n[all]\n# roblox-arm64-launcher: force 4K pages for the Android binder\nkernel=kernel8.img\n' >> "$RT_CACHE_DIR/config.txt.work"
    fi
    root_run cp "$RT_CACHE_DIR/config.txt.work" "$cfg"
    rm -f "$RT_CACHE_DIR/config.txt.work"

    state_set reboot-required 1
    log_ok "Kernel switched to kernel8.img (4K pages). REBOOT REQUIRED before playing."
    info_msg "Raspberry Pi kernel switched to 4K pages.\n\nA REBOOT is required before Roblox can run.\n(16K pages break the Android binder.)"
}

# Zero background bloat: the container service must not auto-start at boot.
disable_waydroid_autostart() {
    if [ "$(config_get KEEP_CONTAINER_SERVICE 0)" = "1" ]; then
        log_warn "KEEP_CONTAINER_SERVICE=1 - leaving waydroid-container.service enabled."
        return 0
    fi
    banner "Zero-bloat: disabling Waydroid autostart"
    if root_run systemctl disable waydroid-container.service >/dev/null 2>&1; then
        log_ok "waydroid-container.service disabled (started on demand by the launcher)."
    else
        log_warn "Could not disable waydroid-container.service (maybe not installed yet)."
    fi
    return 0
}

# Mask any Waydroid desktop entries so no Android UI shows in the app menu
mask_waydroid_desktop() {
    banner "Hiding Waydroid UI entries from the desktop"
    local appdir="$HOME/.local/share/applications"
    mkdir -p "$appdir"
    local masked=0 f base
    for f in /usr/share/applications/waydroid*.desktop; do
        [ -e "$f" ] || continue
        base="$(basename "$f")"
        printf '[Desktop Entry]\nType=Application\nHidden=true\n' > "$appdir/$base"
        masked=$((masked+1))
    done
    if [ "$masked" -gt 0 ]; then
        log_ok "Masked $masked Waydroid desktop entry(ies) for this user."
    else
        log_info "No Waydroid desktop entries found to mask (fine)."
    fi
    # Register our own scheme handlers for this user as well
    if have xdg-mime && [ -f /usr/share/applications/roblox-launcher.desktop ]; then
        xdg-mime default roblox-launcher.desktop x-scheme-handler/roblox >/dev/null 2>&1 || true
        xdg-mime default roblox-launcher.desktop x-scheme-handler/roblox-player >/dev/null 2>&1 || true
        log_ok "Registered roblox:// and roblox-player:// scheme handlers."
    fi
    return 0
}
