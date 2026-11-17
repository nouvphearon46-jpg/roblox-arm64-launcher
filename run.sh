# run.sh - session lifecycle (blueprint items 4 & 6)
# Gamescope auto-detect (nested / x11 / drm / direct), Roblox launch with
# roblox-player:// deep-link support, PID monitoring, and zero-residue cleanup:
# on exit the Waydroid session+container are stopped and governors reverted.

# --------------------------------------------------------------- helpers ---
acquire_lock() {
    exec 9>"$RT_STATE_DIR/lock" || die "Cannot create lock file." 1
    if ! flock -n 9; then
        die "A Roblox session appears to be running. Stop it with: roblox-launcher stop" 2
    fi
}

ensure_ready_for_play() {
    if [ "$(state_get waydroid.ready "")" != "1" ]; then
        die "Setup incomplete. Run: roblox-launcher setup" 1
    fi
    if [ "$(state_get reboot-required "")" = "1" ]; then
        local page
        page="$(get_page_size)"
        if [ "$page" = "16384" ]; then
            die "A reboot is required to activate the 4K-page kernel (currently still 16K). Reboot and try again." 1
        fi
        # Page size is now 4K: the reboot happened, clear the flag
        state_del reboot-required
        log_ok "4K-page kernel is active (reboot done)."
    fi
}

pick_display_mode() {
    # Sets DISPLAY_MODE: gamescope-nested | gamescope-x11 | gamescope-drm | direct | none
    local gs_policy
    gs_policy="$(config_get GAMESCOPE auto)"
    local gs_ok=0
    if have gamescope && [ "$gs_policy" != "no" ]; then
        gs_ok=1
    fi
    if [ "$gs_ok" = "1" ]; then
        if [ -n "${WAYLAND_DISPLAY:-}" ]; then
            DISPLAY_MODE="gamescope-nested"
            return 0
        elif [ -n "${DISPLAY:-}" ]; then
            DISPLAY_MODE="gamescope-x11"
            return 0
        else
            DISPLAY_MODE="gamescope-drm"
            return 0
        fi
    fi
    if [ -n "${WAYLAND_DISPLAY:-}" ]; then
        DISPLAY_MODE="direct"
        return 0
    fi
    DISPLAY_MODE="none"
    return 1
}

build_gamescope_flags() {
    # Query gamescope --help once; only pass flags this build supports.
    GS_HELP="$(gamescope --help 2>/dev/null || true)"
    GS_FLAGS=""
    local res w h fps fullscreen
    fullscreen="$(config_get FULLSCREEN 1)"
    [ "$fullscreen" = "1" ] && GS_FLAGS="$GS_FLAGS -f"
    res="$(config_get RESOLUTION auto)"
    if [ "$res" != "auto" ] && [[ "$res" =~ ^[0-9]+x[0-9]+$ ]]; then
        w="${res%x*}"; h="${res#*x}"
        GS_FLAGS="$GS_FLAGS -w $w -h $h -W $w -H $h"
    fi
    fps="$(config_get FPS auto)"
    [ "$fps" != "auto" ] && GS_FLAGS="$GS_FLAGS -r $fps"
    if [ "$(config_get VRR 0)" = "1" ] && [[ "$GS_HELP" == *"--adaptive-sync"* ]]; then
        GS_FLAGS="$GS_FLAGS --adaptive-sync"
    fi
    # PC mouse-locking (blueprint): force-grab-cursor when supported
    if [[ "$GS_HELP" == *"--force-grab-cursor"* ]]; then
        GS_FLAGS="$GS_FLAGS --force-grab-cursor"
    fi
    # Waydroid is Wayland-native: skip XWayland entirely when supported
    if [[ "$GS_HELP" == *"--xwayland-count"* ]]; then
        GS_FLAGS="$GS_FLAGS --xwayland-count 0"
    fi
}

# ---------------------------------------------------------------- session ---
session_inner() {
    # Runs INSIDE gamescope (or directly). Manages Waydroid session, launches
    # Roblox, monitors the PID, and guarantees zero-residue cleanup.
    local uri="${WAYDROID_LAUNCH_URI:-}"
    local started_at now elapsed
    trap 'session_cleanup' EXIT
    trap 'session_cleanup; exit 130' INT
    trap 'session_cleanup; exit 143' TERM

    log_info "Session start (mode: ${WAYDROID_MODE:-unknown})"
    state_set session.active 1

    # Waydroid session must run on the compositor we were given (gamescope or
    # the desktop's own). Start it in the background and wait for it.
    waydroid session start >/dev/null 2>&1 &
    local i=0 ok=0
    while [ $i -lt 60 ]; do
        if waydroid status 2>/dev/null | grep -q "Session:.*RUNNING"; then ok=1; break; fi
        sleep 1; i=$((i+1))
    done
    if [ "$ok" = "1" ]; then
        log_ok "Waydroid session is running."
    else
        log_err "Waydroid session did not reach RUNNING state within 60s."
        log_err "Hints: run inside a Wayland session or from a TTY with gamescope; see README."
        session_cleanup
        return 1
    fi

    force_uimode_normal

    # Roblox present? If not, guide the user through Aurora (anonymous).
    if ! android_pkg_installed "$ROBLOX_ANDROID_PKG"; then
        log_warn "Roblox is not installed yet - opening Aurora Store (anonymous mode)."
        log_warn "Install Roblox there; this launcher keeps waiting for up to 30 minutes."
        info_msg "Roblox is not installed yet.\n\nAurora Store is opening now (anonymous, no Google account).\n\n1) Search for 'Roblox'\n2) Tap Install\n3) Wait - the game starts automatically.\n\nEnable Settings -> Updates -> 'Automatic app updates'\nso Roblox auto-updates in the background."
        waydroid app launch "$AURORA_ANDROID_PKG" >/dev/null 2>&1 || true
        i=0
        while [ $i -lt 360 ]; do
            if android_pkg_installed "$ROBLOX_ANDROID_PKG"; then break; fi
            sleep 5
            i=$((i+1))
            [ $((i % 12)) -eq 0 ] && log_info "Still waiting for Roblox to be installed via Aurora... ($((i/12)) min)"
        done
        if ! android_pkg_installed "$ROBLOX_ANDROID_PKG"; then
            log_err "Roblox was not installed within 30 minutes; exiting."
            session_cleanup
            return 1
        fi
        log_ok "Roblox detected as installed. Launching..."
        info_msg "Roblox installed successfully.\n\nLaunching the game now."
    fi

    # Launch Roblox (deep link or plain app launch)
    if [ -n "$uri" ]; then
        log_info "Deep link: $uri"
        if ! waydroid shell am start -a android.intent.action.VIEW -d "$uri" "$ROBLOX_ANDROID_PKG"; then
            log_warn "Deep link launch failed - falling back to plain launch."
            waydroid app launch "$ROBLOX_ANDROID_PKG" || true
        fi
    else
        waydroid app launch "$ROBLOX_ANDROID_PKG" || log_warn "app launch returned non-zero (window may still appear)."
    fi

    # Wait for the Roblox PID inside the container
    local pid=""
    i=0
    while [ $i -lt 120 ]; do
        pid="$(waydroid shell pidof "$ROBLOX_ANDROID_PKG" 2>/dev/null | awk '{print $1}')"
        [ -n "$pid" ] && break
        sleep 1; i=$((i+1))
    done
    if [ -z "$pid" ]; then
        log_err "Roblox process never appeared (120s timeout). Check logs; try again."
        dump_roblox_crash_log
        session_cleanup
        return 1
    fi
    state_set roblox.pid "$pid"
    started_at="$(date +%s)"
    log_ok "Roblox is running (pid $pid). Close the game to end the session."

    # Monitor loop: Roblox alive? session alive?
    while true; do
        sleep 3
        if ! waydroid shell kill -0 "$pid" >/dev/null 2>&1 \
           && [ -z "$(waydroid shell pidof "$ROBLOX_ANDROID_PKG" 2>/dev/null || true)" ]; then
            break
        fi
        if ! waydroid status 2>/dev/null | grep -q "Session:.*RUNNING"; then
            log_warn "Waydroid session died unexpectedly."
            break
        fi
    done

    now="$(date +%s)"
    elapsed=$((now - started_at))
    log_info "Roblox exited after ${elapsed}s."
    [ "$elapsed" -lt 30 ] && dump_roblox_crash_log
    session_cleanup
    return 0
}

dump_roblox_crash_log() {
    local out="$RT_LOG_DIR/roblox-crash.log"
    if have waydroid; then
        waydroid shell logcat -d 2>/dev/null | tail -n 80 > "$out" || true
        log_info "Recent Android logcat saved to $out"
    fi
}

session_cleanup() {
    # Idempotent, runs on EXIT/INT/TERM and via `roblox-launcher stop`.
    [ "${RT_CLEANUP_DONE:-0}" = "1" ] && return 0
    RT_CLEANUP_DONE=1
    log_info "Cleaning up: reverting performance mode, stopping Waydroid..."
    perf_off
    if have waydroid; then
        waydroid session stop >/dev/null 2>&1 || true
    fi
    stop_container_fully
    cec_off
    state_del roblox.pid
    state_del session.active
    state_set session.done 1
    log_ok "Zero background processes remain (container stopped, governors reverted)."
}

session_outer() {
    # Outer supervisor: wraps session_inner in gamescope when possible and
    # always sweeps leftovers afterwards.
    local mode="$1"
    shift || true

    state_del session.done
    local inner="$SELF_PATH _inner"
    local gs_pid=""

    if [ "$mode" = "direct" ]; then
        log_info "Display: direct Waydroid window (desktop Wayland session, no gamescope wrap)."
        if [ "$(config_get FULLSCREEN 1)" = "1" ]; then
            log_info "Fullscreen tip: the Waydroid window is chrome-less. Maximize it with"
            log_info "your compositor shortcut (GNOME/KDE: Super+Up), or install gamescope"
            log_info "for automatic borderless fullscreen (sudo apt install gamescope)."
        fi
        WAYDROID_MODE="direct" WAYDROID_LAUNCH_URI="${LAUNCH_URI:-}" session_inner
    elif [ "$mode" = "none" ]; then
        # Safety net (cmd_play already guards this); never leave perf locked.
        perf_off; stop_container_fully; cec_off
        die "No usable display stack found. Options:
  - Run from a Wayland desktop session (GNOME/KDE/wlroots), or
  - Install gamescope and run from a TTY, or
  - Set config: roblox-launcher config set GAMESCOPE auto" 1
    else
        build_gamescope_flags
        log_info "Display: gamescope wrap ($mode) with flags:$GS_FLAGS"
        case "$mode" in
            gamescope-nested) log_info "Nested gamescope inside your Wayland session." ;;
            gamescope-x11)    log_warn "X11 session detected; trying gamescope. If it exits immediately, switch to a Wayland session." ;;
            gamescope-drm)    log_info "TTY detected: gamescope DRM backend (true full-screen console mode)." ;;
        esac
        WAYDROID_MODE="$mode" WAYDROID_LAUNCH_URI="${LAUNCH_URI:-}" \
            gamescope $GS_FLAGS -- $inner &
        gs_pid=$!
        state_set gamescope.pid "$gs_pid"

        # Grace period: catch instant gamescope death (bad flags, no seat, ...)
        local i=0
        while [ $i -lt 10 ]; do
            kill -0 "$gs_pid" 2>/dev/null || break
            [ "$(state_get session.done "")" = "1" ] && break
            sleep 1; i=$((i+1))
        done
        if ! kill -0 "$gs_pid" 2>/dev/null && [ "$(state_get session.done "")" != "1" ]; then
            wait "$gs_pid" 2>/dev/null || true
            state_del gamescope.pid
            # Sweeping sweep in case the inner got partway through
            perf_off; stop_container_fully; cec_off
            die "gamescope exited immediately (mode: $mode). Check logs; if on X11 use a Wayland session or TTY; flags used:$GS_FLAGS" 1
        fi

        # Wait for gamescope to exit (user closed window) or inner to finish
        while kill -0 "$gs_pid" 2>/dev/null; do
            [ "$(state_get session.done "")" = "1" ] && break
            sleep 2
        done
        # Inner finished? then stop gamescope; gamescope died? inner trap handled cleanup.
        if kill -0 "$gs_pid" 2>/dev/null; then
            kill "$gs_pid" 2>/dev/null || true
            wait "$gs_pid" 2>/dev/null || true
        else
            wait "$gs_pid" 2>/dev/null || true
        fi
        state_del gamescope.pid
    fi

    # Final sweep - guarantees the zero-residue promise even on weird exits.
    perf_off
    stop_container_fully
    cec_off
    log_ok "Session ended. No Roblox/Waydroid background processes remain."
}

cmd_play() {
    rt_init_dirs
    acquire_lock
    ensure_ready_for_play

    LAUNCH_URI="${1:-}"
    case "$LAUNCH_URI" in
        roblox://*|roblox-player:*) log_info "Browser deep-link received." ;;
        "") : ;;
        *) die "Unknown argument to play: $LAUNCH_URI (expected roblox-player:// URI or nothing)" 2 ;;
    esac

    ensure_container
    cec_on

    # Pick the display mode BEFORE locking governors, so a missing display
    # stack can never leave the system in performance mode.
    pick_display_mode || DISPLAY_MODE="none"
    if [ "$DISPLAY_MODE" = "none" ]; then
        cec_off
        die "No usable display stack found. Options:
  - Run from a Wayland desktop session (GNOME/KDE/wlroots), or
  - Install gamescope and run from a TTY, or
  - Set config: roblox-launcher config set GAMESCOPE auto" 1
    fi

    perf_on   # lock governors before the window appears (BIOS-style boost)
    session_outer "$DISPLAY_MODE"
    return 0
}

cmd_stop() {
    rt_init_dirs
    log_info "Stop requested..."
    local gs_pid
    gs_pid="$(state_get gamescope.pid "")"
    if [ -n "$gs_pid" ] && kill -0 "$gs_pid" 2>/dev/null; then
        kill "$gs_pid" 2>/dev/null || true
        sleep 2
        kill -9 "$gs_pid" 2>/dev/null || true
    fi
    state_del gamescope.pid
    perf_off
    if have waydroid; then
        waydroid session stop >/dev/null 2>&1 || true
    fi
    stop_container_fully
    cec_off
    state_del session.active
    log_ok "Stopped. CPU/GPU/DDR governors reverted; container down."
}
