# doctor.sh - diagnostics report (no simulation hooks; reads the real system)

_d() { printf '  %s\n' "$*"; }
_dok() { printf '  [ OK ] %s\n' "$*"; }
_dwarn() { printf '  [WARN] %s\n' "$*"; }
_derr() { printf '  [FAIL] %s\n' "$*"; }

cmd_doctor() {
    rt_init_dirs
    local section=""
    sec() { section="$1"; printf '\n%s\n%s\n' "$1" "----------------------------------------"; }

    sec "Launcher"
    _d "version : $ROBLOX_LAUNCHER_VERSION"
    _d "runtime : $RT_DIR"
    _d "logfile : $RT_LOG_FILE ($(wc -l < "$RT_LOG_FILE" 2>/dev/null || echo 0) lines)"
    if [ "$(state_get gate.result "")" != "" ]; then
        _d "last gate verdict: $(state_get gate.result)"
    fi
    [ "$(state_get reboot-required "")" = "1" ] && _dwarn "reboot required (kernel switch to 4K pages pending)"

    sec "Hardware & OS gate"
    run_gate report
    _d "page size: $(get_page_size) bytes"
    _d "mem total: $(( $(get_mem_total_kb) / 1024 )) MB"

    sec "Distro"
    if detect_distro; then
        _d "ID=$DISTRO_ID codename=${DISTRO_CODENAME:-none} family=$DISTRO_FAMILY"
    else
        _derr "cannot read /etc/os-release"
    fi
    if [ -f /etc/apt/sources.list.d/waydroid.list ]; then
        _dok "waydroid apt repo configured:"
        sed 's/^/         /' /etc/apt/sources.list.d/waydroid.list 2>/dev/null || true
    else
        _dwarn "waydroid apt repo not configured yet (run setup)"
    fi

    sec "Host tools"
    for tool in waydroid gamescope cec-client pactl curl zenity xdg-mime flock dbus-run-session; do
        if have "$tool"; then
            local v=""
            case "$tool" in
                waydroid)  v="$(waydroid --version 2>/dev/null | head -n1)" ;;
                gamescope) v="$(gamescope --version 2>/dev/null | head -n1)" ;;
                pactl)     v="$(pactl --version 2>/dev/null | head -n1)" ;;
            esac
            _dok "$tool ${v:+($v)}"
        else
            _dwarn "$tool missing"
        fi
    done
    if have pactl && pactl info 2>/dev/null | grep -qi pipewire; then
        _dok "audio: PipeWire active"
    elif have pactl; then
        _dwarn "audio: legacy PulseAudio (works; PipeWire recommended)"
    else
        _dwarn "audio: no PulseAudio/PipeWire control found"
    fi

    sec "Waydroid"
    if waydroid_inited; then
        _dok "initialized (VANILLA marker: $( [ "$(state_get waydroid.vanilla '')" = 1 ] && echo yes || echo unknown))"
        local img_size
        img_size="$(du -sh "$WAYDROID_IMAGES_DIR" 2>/dev/null | awk '{print $1}')"
        _d "images: $WAYDROID_IMAGES_DIR ($img_size)"
        if container_active; then
            _d "container: RUNNING"
            waydroid status 2>/dev/null | sed 's/^/         /' || true
        else
            _d "container: stopped (on-demand only - this is the zero-bloat policy)"
        fi
    else
        _derr "not initialized - run: roblox-launcher setup"
    fi
    if root_run systemctl is-enabled waydroid-container.service >/dev/null 2>&1; then
        _dwarn "waydroid-container.service is ENABLED at boot (violates zero-bloat policy; run setup again)"
    else
        _d "container autostart: disabled (on-demand)"
    fi

    sec "Runtime properties (waydroid.cfg)"
    if [ -f "$WAYDROID_CFG" ]; then
        awk '/^\[properties\]/{f=1;next} /^\[/{f=0} f && NF' "$WAYDROID_CFG" 2>/dev/null \
            | sed 's/^/  /' || true
        [ -z "$(awk '/^\[properties\]/{f=1;next} /^\[/{f=0} f && NF' "$WAYDROID_CFG" 2>/dev/null)" ] && _d "(none set)"
    else
        _d "(no waydroid.cfg yet)"
    fi

    sec "Apps inside container"
    if container_active; then
        if android_pkg_installed "$ROBLOX_ANDROID_PKG"; then
            _dok "Roblox installed ($(android_pkg_version "$ROBLOX_ANDROID_PKG" 2>/dev/null || echo version?))"
        else
            _dwarn "Roblox NOT installed yet"
        fi
        if android_pkg_installed "$AURORA_ANDROID_PKG"; then
            _dok "Aurora Store installed ($(android_pkg_version "$AURORA_ANDROID_PKG" 2>/dev/null || echo version?))"
        else
            _dwarn "Aurora Store not installed"
        fi
        if waydroid shell command -v su >/dev/null 2>&1; then
            _derr "su binary present inside container (anti-cheat risk!)"
        else
            _dok "no su binary (unrooted)"
        fi
    else
        _d "(container not running - start a session or setup to inspect apps)"
    fi

    sec "Host bridges"
    if [ -f "$WAYDROID_CFG" ] && grep -q "devices = .*Pictures/Roblox" "$WAYDROID_CFG" 2>/dev/null; then
        _dok "screenshot bridge configured in waydroid.cfg"
    else
        _dwarn "screenshot bridge not configured"
    fi
    [ -d "$HOME/Pictures/Roblox" ] \
        && _dok "host folder exists: ~/Pictures/Roblox" \
        || _dwarn "host folder missing: ~/Pictures/Roblox"
    if [ -f ~/.config/mimeapps.list ] && grep -q "roblox" ~/.config/mimeapps.list 2>/dev/null; then
        _dok "scheme handlers registered (roblox, roblox-player)"
    else
        _dwarn "scheme handlers not registered yet (run setup)"
    fi

    sec "Performance nodes"
    local nodes count=0
    nodes="$(perf_discover_nodes)"
    if [ -n "$nodes" ]; then
        while IFS= read -r n; do
            _d "$n = $(cat "$n" 2>/dev/null || echo unreadable)"
            count=$((count+1))
        done <<< "$nodes"
        _d "$count node(s) total; perf marker: $([ -f "$RT_STATE_DIR/perf.on" ] && echo LOCKED || echo released)"
    else
        _dwarn "no cpufreq/devfreq governor nodes found"
    fi

    sec "HDMI-CEC"
    if have cec-client; then
        local adapters
        adapters="$(ls /dev/cec* 2>/dev/null || true)"
        [ -n "$adapters" ] && _d "adapters: $adapters" || _dwarn "no /dev/cec* adapters"
        _d "CEC_ON_LAUNCH=$(config_get CEC_ON_LAUNCH 0) CEC_STANDBY_EXIT=$(config_get CEC_STANDBY_EXIT 0)"
    else
        _d "cec-utils not installed (optional)"
    fi

    sec "Config overrides"
    config_list | sed 's/^/  /'

    sec "Recent log"
    tail -n 15 "$RT_LOG_FILE" 2>/dev/null | sed 's/^/  /' || true

    return 0
}
