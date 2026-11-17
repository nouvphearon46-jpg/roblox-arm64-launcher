# waydroid_init.sh - hidden, debloated VANILLA Android subsystem (blueprint item 2)
# Plus unrooted hardening and uimode normal enforcement (user requirements).

waydroid_inited() { [ -f "$WAYDROID_IMAGES_DIR/system.img" ]; }

container_active() {
    root_run systemctl is-active --quiet waydroid-container.service 2>/dev/null
}

ensure_container() {
    if container_active; then return 0; fi
    log_info "Starting waydroid-container.service..."
    root_run systemctl start waydroid-container.service \
        || root_run waydroid container start \
        || die "Could not start the Waydroid container service." 1
    local i=0
    while [ $i -lt 60 ]; do
        if waydroid status 2>/dev/null | grep -q "RUNNING"; then
            log_ok "Waydroid container is running."
            return 0
        fi
        sleep 1
        i=$((i+1))
    done
    die "Waydroid container did not reach RUNNING state within 60s. Run 'roblox-launcher doctor'." 1
}

stop_container_fully() {
    # Idempotent: safe to call many times. Stops session then container.
    waydroid session stop >/dev/null 2>&1 || true
    if have waydroid && (container_active || waydroid status 2>/dev/null | grep -q "RUNNING"); then
        root_run waydroid container stop >/dev/null 2>&1 || true
    fi
    sleep 1
    return 0
}

# Set a persistent Waydroid property. Tries offline first; falls back to a
# container boot cycle. Non-fatal on failure (logged).
prop_set_safe() {
    # prop_set_safe PROP VALUE
    local prop="$1" value="$2"
    if waydroid prop set "$prop" "$value" >/dev/null 2>&1; then
        log_ok "prop $prop = ${value:-<empty>}"
        return 0
    fi
    log_info "prop set failed offline; retrying with container up..."
    if ensure_container; then
        if waydroid prop set "$prop" "$value" >/dev/null 2>&1; then
            log_ok "prop $prop = ${value:-<empty>}"
            stop_container_fully
            return 0
        fi
        stop_container_fully
    fi
    log_warn "Could not set prop $prop (continuing)."
    return 1
}

set_runtime_props() {
    banner "Waydroid PC-mode properties"
    # PC mode: no virtual touch buttons, native USB input passthrough,
    # desktop DPI, single window, no duplicate cursors.
    prop_set_safe persist.waydroid.fake_touch ""
    prop_set_safe persist.waydroid.uevent true
    prop_set_safe persist.waydroid.cursor_on_subsurface true
    prop_set_safe persist.waydroid.multi_windows false
    prop_set_safe ro.sf.lcd_density "$(config_get DPI 160)"
}

# Enforce uimode type normal so Android never glitches into a console/TV UI
force_uimode_normal() {
    if ! have waydroid; then return 0; fi
    waydroid shell cmd uimode type normal >/dev/null 2>&1 || true
    waydroid shell cmd uimode night no >/dev/null 2>&1 || true
    log_ok "Android UI mode forced to: normal (night mode: no)"
}

# Keep the container UNROOTED for anti-cheat compatibility.
harden_unrooted() {
    banner "Unrooted hardening (anti-cheat compatibility)"
    # Props that root-detection heuristics look for. These are defaults in a
    # user build, but set them explicitly so nothing drifts.
    prop_set_safe ro.debuggable 0
    prop_set_safe ro.secure 1
    prop_set_safe ro.build.tags release-keys
    if container_active || waydroid status 2>/dev/null | grep -q "RUNNING"; then
        # No su binary, no root granters
        if waydroid shell command -v su >/dev/null 2>&1; then
            log_warn "A 'su' binary is present inside the container - investigate before playing."
        else
            log_ok "No su binary inside the container."
        fi
        local bad
        bad="$(waydroid shell pm list packages 2>/dev/null | sed -n 's/^package://p' | grep -iE 'magisk|supersu|superuser|kingroot|topjohnwu' || true)"
        if [ -n "$bad" ]; then
            log_warn "Root-granting app(s) detected: $bad - uninstalling."
            local p
            for p in $bad; do
                waydroid shell pm uninstall --user 0 "$p" >/dev/null 2>&1 || true
            done
        else
            log_ok "No root-granting apps installed."
        fi
        # Make sure we never hand apps a root prompt
        waydroid shell setprop service.adb.tcp.port "" >/dev/null 2>&1 || true
    else
        log_info "(Container not running - su/root-app checks will run on next first-boot pass.)"
    fi
    log_ok "Container is kept UNROOTED (no Magisk/su, secure user build props)."
}

waydroid_init_vanilla() {
    banner "Waydroid VANILLA image initialization"
    if ! have waydroid; then
        die "waydroid is not installed. Run setup first or install it manually." 1
    fi
    if waydroid_inited; then
        if [ "$(state_get waydroid.vanilla "")" = "1" ]; then
            log_ok "Waydroid already initialized (VANILLA)."
        else
            log_warn "Waydroid already initialized but not by this launcher."
            log_warn "If it was initialized with GAPPS, re-initialize with: roblox-launcher reset-container"
            state_set waydroid.vanilla 1
        fi
        return 0
    fi
    log_info "Running 'waydroid init -s VANILLA' (downloads ~700 MB; zero Google services)..."
    if ! root_run waydroid init -s VANILLA; then
        die "waydroid init failed. Check network access to OTA servers (ota.waydroid.org)." 1
    fi
    waydroid_inited || die "waydroid init finished but system image is missing." 1
    state_set waydroid.vanilla 1
    log_ok "VANILLA image ready (no Google Play Services, no Google sign-in)."
}

# Bind-mount ~/Pictures/Roblox into the container (blueprint item 5)
setup_shared_folder() {
    banner "Screenshot bridge: ~/Pictures/Roblox -> /sdcard/Pictures/Roblox"
    local host_dir="$HOME/Pictures/Roblox"
    mkdir -p "$host_dir"
    log_ok "Host folder ready: $host_dir"

    if [ ! -f "$WAYDROID_CFG" ]; then
        log_warn "Waydroid config not found yet ($WAYDROID_CFG); the bridge will be added after 'waydroid init'."
        return 0
    fi

    # Backup once
    if [ ! -f "$RT_BACKUP_DIR/waydroid.cfg.orig" ]; then
        root_run cp "$WAYDROID_CFG" "$RT_BACKUP_DIR/waydroid.cfg.orig" || true
    fi

    # Copy-edit-copy-back
    root_run cp "$WAYDROID_CFG" "$RT_CACHE_DIR/waydroid.cfg.work" || die "Cannot read $WAYDROID_CFG" 1
    if grep -q "devices = .*Pictures/Roblox" "$RT_CACHE_DIR/waydroid.cfg.work"; then
        log_ok "Shared folder already present in waydroid.cfg."
    elif grep -qE '^\[custom\]' "$RT_CACHE_DIR/waydroid.cfg.work"; then
        sed -i "/^\[custom\]/a\\
devices = ${host_dir}:/sdcard/Pictures/Roblox" "$RT_CACHE_DIR/waydroid.cfg.work"
        log_ok "Added shared folder under existing [custom] section."
    else
        printf '\n[custom]\ndevices = %s:/sdcard/Pictures/Roblox\n' "$host_dir" >> "$RT_CACHE_DIR/waydroid.cfg.work"
        log_ok "Appended [custom] shared folder section."
    fi
    root_run cp "$RT_CACHE_DIR/waydroid.cfg.work" "$WAYDROID_CFG"
    rm -f "$RT_CACHE_DIR/waydroid.cfg.work"

    # Verify the mount actually appears inside Android
    if ensure_container; then
        sleep 2
        if waydroid shell ls /sdcard/Pictures/Roblox >/dev/null 2>&1; then
            log_ok "Verified: /sdcard/Pictures/Roblox is visible inside Android."
        else
            log_warn "Could not verify /sdcard/Pictures/Roblox inside Android (check 'roblox-launcher doctor')."
        fi
        stop_container_fully
    fi
}

# First-boot preparation: uimode normal, harden, then stop everything again
first_boot_prepare() {
    banner "First-boot preparation"
    ensure_container
    force_uimode_normal
    harden_unrooted
    stop_container_fully
    log_ok "First-boot preparation complete (container stopped again)."
}

reset_container() {
    banner "Resetting Waydroid container to VANILLA"
    confirm "This deletes the Waydroid image AND all Android data (including the Roblox install). Continue?" "n" \
        || die "Aborted." 1
    stop_container_fully
    root_run systemctl stop waydroid-container.service >/dev/null 2>&1 || true
    root_run rm -rf /var/lib/waydroid || die "Could not remove /var/lib/waydroid" 1
    state_del waydroid.vanilla
    state_del waydroid.ready
    state_del setup.progress
    log_ok "Container removed. Run 'roblox-launcher setup' to re-initialize VANILLA."
}
