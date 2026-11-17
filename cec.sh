# cec.sh - optional HDMI-CEC support via cec-utils (blueprint item 4)
# TV remote / standby integration. Disabled by default; enable via config:
#   roblox-launcher config set CEC_ON_LAUNCH 1
#   roblox-launcher config set CEC_STANDBY_EXIT 1

CEC_DEVICE_CFG="$(config_get CEC_DEVICE auto)"

cec_find_adapter() {
    local dev
    if [ "$CEC_DEVICE_CFG" != "auto" ] && [ -e "$CEC_DEVICE_CFG" ]; then
        printf '%s' "$CEC_DEVICE_CFG"; return 0
    fi
    for dev in /dev/cec*; do
        [ -e "$dev" ] && { printf '%s' "$dev"; return 0; }
    done
    return 1
}

cec_available() {
    have cec-client || return 1
    cec_find_adapter >/dev/null 2>&1
}

cec_send() {
    # cec_send "on 0" | "standby 0"
    local msg="$1" dev
    dev="$(cec_find_adapter 2>/dev/null || true)"
    [ -z "$dev" ] && return 1
    printf '%s\n' "$msg" | timeout 8 cec-client -s -d 1 "$dev" >/dev/null 2>&1 || true
    return 0
}

cec_on() {
    [ "$(config_get CEC_ON_LAUNCH 0)" = "1" ] || return 0
    if ! cec_available; then
        log_warn "CEC_ON_LAUNCH=1 but no cec-client or /dev/cec* adapter found; skipping."
        return 0
    fi
    log_info "HDMI-CEC: powering on TV..."
    cec_send "on 0"
}

cec_off() {
    [ "$(config_get CEC_STANDBY_EXIT 0)" = "1" ] || return 0
    if ! cec_available; then
        return 0
    fi
    log_info "HDMI-CEC: putting TV on standby..."
    cec_send "standby 0"
}
