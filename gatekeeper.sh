# gatekeeper.sh - hardware & OS gate (blueprint item 1)
# Verifies aarch64 + modern ARMv8.2+/v9 cores, blocks Qualcomm/Adreno,
# warns on weak A53/A55-only boards, checks page size / RAM / disk.

# ARM implementer ids
IMPL_ARM="0x41"
IMPL_QUALCOMM="0x51"

# "CPU part" ids (ARM, implementer 0x41). Classification only needs rough tiers.
STRONG_PARTS=" 0xd0b 0xd0d 0xd0e 0xd40 0xd41 0xd42 0xd44 0xd47 0xd48 0xd49 0xd4b 0xd4c 0xd4d 0xd4e 0xd4f 0xd85 0xd87 0xd8e 0xd8f "
MID_PARTS=" 0xd07 0xd08 0xd09 0xd0a "
WEAK_PARTS=" 0xd01 0xd02 0xd03 0xd04 0xd05 0xd46 0xd80 "

part_name() {
    case "$1" in
        0xd01) echo "Cortex-A32";;
        0xd02) echo "Cortex-A34";;
        0xd03) echo "Cortex-A53";;
        0xd04) echo "Cortex-A35";;
        0xd05) echo "Cortex-A55";;
        0xd07) echo "Cortex-A57";;
        0xd08) echo "Cortex-A72";;
        0xd09) echo "Cortex-A73";;
        0xd0a) echo "Cortex-A75";;
        0xd0b) echo "Cortex-A76";;
        0xd0c) echo "Neoverse-N1";;
        0xd0d) echo "Cortex-A77";;
        0xd0e) echo "Cortex-A76AE";;
        0xd40) echo "Neoverse-V1";;
        0xd41) echo "Cortex-A78";;
        0xd42) echo "Cortex-A78AE";;
        0xd44) echo "Cortex-X1";;
        0xd46) echo "Cortex-A510";;
        0xd47) echo "Cortex-A710";;
        0xd48) echo "Cortex-X2";;
        0xd49) echo "Neoverse-N2";;
        0xd4a) echo "Neoverse-E1";;
        0xd4b) echo "Cortex-A78C";;
        0xd4c) echo "Cortex-X1C/Neoverse-V2";;
        0xd4d) echo "Cortex-A715";;
        0xd4e) echo "Cortex-X3";;
        0xd4f) echo "Cortex-A720";;
        0xd80) echo "Cortex-A520";;
        0xd85) echo "Cortex-X4";;
        0xd87) echo "Cortex-A725";;
        0xd8e) echo "Cortex-A920";;
        0xd8f) echo "Cortex-X925";;
        *) echo "Unknown(0x$1)";;
    esac
}

impl_name() {
    case "$1" in
        0x41) echo "ARM";;
        0x51) echo "Qualcomm";;
        0x53) echo "Samsung";;
        0x48) echo "HiSilicon";;
        0x61) echo "Apple";;
        0x63) echo "Ampere";;
        0x6d) echo "Microsoft";;
        *) echo "Unknown(0x$1)";;
    esac
}

# Detect known SoC from device-tree compatible strings (informational)
detect_soc() {
    local comp="" soc=""
    if [ -r /proc/device-tree/compatible ]; then
        comp="$(tr '\0' '\n' < /proc/device-tree/compatible 2>/dev/null || true)"
    fi
    case "$comp" in
        *rk3588*)  soc="Rockchip RK3588/RK3588S (Cortex-A76/A55)";;
        *rk3576*)  soc="Rockchip RK3576 (Cortex-A72/A53 class)";;
        *sun55i*|*a733*) soc="Allwinner A733 (Cortex-A76/A55)";;
        *bcm2712*) soc="Broadcom BCM2712 (Raspberry Pi 5, Cortex-A76)";;
        *bcm2711*) soc="Broadcom BCM2712? No: BCM2711 (Raspberry Pi 4, Cortex-A72)";;
        *sky1*|*cix*) soc="CIX P1/CP8180 (Cortex-A720/A725)";;
    esac
    printf '%s' "$soc"
}

# Returns page size in bytes (0 on failure)
get_page_size() {
    local ps=""
    ps="$(getconf PAGE_SIZE 2>/dev/null || true)"
    [ -z "$ps" ] && ps="$(getconf PAGESIZE 2>/dev/null || true)"
    case "$ps" in
        ''|*[!0-9]*) echo 0 ;;
        *) echo "$ps" ;;
    esac
}

get_mem_total_kb() {
    awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || echo 0
}

# Collect per-core implementer/part pairs from /proc/cpuinfo
# Fills: CORE_IMPLEMENTS CORE_PARTS (parallel arrays).
# Pure awk paragraph parsing: portable across gawk/mawk/busybox awk.
collect_cores() {
    CORE_IMPLEMENTS=()
    CORE_PARTS=()
    local pair
    while read -r pair; do
        [ -n "$pair" ] || continue
        CORE_IMPLEMENTS+=("${pair%% *}")
        CORE_PARTS+=("${pair##* }")
    done < <(awk -v RS='' '
        /CPU part/ {
            impl = ""; part = "";
            n = split($0, lines, "\n");
            for (i = 1; i <= n; i++) {
                if (lines[i] ~ /^CPU implementer/) { sub(/^CPU implementer[ \t]*:[ \t]*/, "", lines[i]); impl = lines[i]; }
                if (lines[i] ~ /^CPU part/)       { sub(/^CPU part[ \t]*:[ \t]*/, "", lines[i]); part = lines[i]; }
            }
            if (impl != "" && part != "") print impl, part;
        }' /proc/cpuinfo 2>/dev/null)
}

# Run the full hardware gate.
# Usage: run_gate strict|report
#   strict  -> exits non-zero when BLOCKED (used by `setup`)
#   report  -> never exits non-zero (used by `doctor`)
# Sets GATE_VERDICT: APPROVED | WARNED | BLOCKED
run_gate() {
    local mode="${1:-strict}"
    GATE_VERDICT="BLOCKED"
    local blocked=0 warned=0
    local arch soc page memkb diskavail_mb

    banner "Hardware & OS Gatekeeper"

    arch="$(uname -m 2>/dev/null || echo unknown)"
    log_info "Architecture: $arch"
    if [ "$arch" != "aarch64" ]; then
        log_err "This launcher requires aarch64 (ARM64). Found: $arch"
        blocked=1
    fi

    soc="$(detect_soc)"
    if [ -n "$soc" ]; then
        log_info "Detected SoC: $soc"
    fi

    collect_cores
    local n="${#CORE_PARTS[@]}"
    local have_strong=0 have_mid=0 have_weak=0 unknown_impl="" qcom=0
    local i name
    if [ "$n" -eq 0 ]; then
        log_warn "Could not parse CPU core types from /proc/cpuinfo"
        warned=1
    else
        log_info "Cores detected: $n"
        for i in "${!CORE_PARTS[@]}"; do
            name="$(part_name "${CORE_PARTS[$i]}")"
            log_info "  core $((i+1)): $(impl_name "${CORE_IMPLEMENTS[$i]}") ${CORE_PARTS[$i]} (${name})"
            case " ${STRONG_PARTS} " in
                *" ${CORE_PARTS[$i]} "*) have_strong=$((have_strong+1)) ;;
            esac
            case " ${MID_PARTS} " in
                *" ${CORE_PARTS[$i]} "*) have_mid=$((have_mid+1)) ;;
            esac
            case " ${WEAK_PARTS} " in
                *" ${CORE_PARTS[$i]} "*) have_weak=$((have_weak+1)) ;;
            esac
            if [ "${CORE_IMPLEMENTS[$i]}" = "$IMPL_QUALCOMM" ]; then
                qcom=1
            elif [ "${CORE_IMPLEMENTS[$i]}" != "$IMPL_ARM" ] && [ -z "$unknown_impl" ]; then
                unknown_impl="${CORE_IMPLEMENTS[$i]}"
            fi
        done
    fi

    # Blueprint: explicitly block Qualcomm/Adreno devices
    if [ "$qcom" = "1" ]; then
        if [ "${ROBLOX_LAUNCHER_ALLOW_QUALCOMM:-0}" = "1" ]; then
            log_warn "Qualcomm/Adreno device detected but ROBLOX_LAUNCHER_ALLOW_QUALCOMM=1 override is set - continuing at your own risk."
            warned=1
        else
            log_err "Qualcomm/Adreno devices are explicitly blocked (Adreno + Android-container graphics path is unsupported)."
            log_err "Use a Rockchip/Allwinner/Broadcom/CIX board with Mali or Panfrost/Panthor graphics."
            blocked=1
        fi
    fi

    if [ "$n" -gt 0 ]; then
        if [ "$have_strong" -gt 0 ]; then
            log_ok "Modern ARMv8.2+/v9 big core present (Cortex-A76 class or newer) - approved."
        elif [ "$have_mid" -gt 0 ]; then
            log_warn "Only older big cores found (A72/A73/A75). Roblox may run but with reduced performance."
            warned=1
        elif [ "$have_weak" -gt 0 ]; then
            log_warn "Weak Cortex-A53/A55-only board detected. Performance will be poor; continuing is allowed but not recommended."
            warned=1
        else
            log_warn "No recognized core types (unknown part ids). Proceeding with a warning."
            warned=1
        fi
    fi
    if [ -n "$unknown_impl" ]; then
        log_warn "Non-ARM implementer present: $(impl_name "$unknown_impl") (treated as unknown)."
    fi

    # Page size: Android binder inside Waydroid requires 4K pages
    page="$(get_page_size)"
    log_info "Kernel page size: ${page:-unknown} bytes"
    case "$page" in
        4096)  log_ok "4K page kernel - compatible with Android containers." ;;
        16384) log_warn "16K page kernel detected (Raspberry Pi 5 default). Android binder needs 4K pages;"
               log_warn "setup will switch /boot firmware to kernel8.img (4K) and a reboot will be required."
               state_set reboot-required 1
               warned=1 ;;
        65536) log_err "64K page kernel detected. Android binder cannot run with 64K pages on this setup."
               blocked=1 ;;
        *)     log_warn "Unknown page size '${page:-?}'. Continuing." ; warned=1 ;;
    esac

    # Memory
    memkb="$(get_mem_total_kb)"
    if [ "$memkb" -ge 3900000 ]; then
        log_ok "Memory: $((memkb/1024)) MB total - sufficient."
    elif [ "$memkb" -ge 2400000 ]; then
        log_warn "Memory: $((memkb/1024)) MB total. Roblox + Android needs about 3.5 GB; expect pressure."
        warned=1
    else
        log_err "Memory: $((memkb/1024)) MB total is below the practical minimum (2.5 GB)."
        blocked=1
    fi

    # Disk space for images + Android data
    diskavail_mb="$(df -Pk /var/lib 2>/dev/null | awk 'NR==2 {print int($4/1024)}')"
    if [ -n "$diskavail_mb" ] && [ "$diskavail_mb" -ge 6000 ]; then
        log_ok "Disk: ${diskavail_mb} MB free under /var/lib - sufficient (need ~6 GB)."
    else
        log_warn "Disk: ${diskavail_mb:-?} MB free under /var/lib. At least ~6 GB is recommended for the Waydroid image."
        warned=1
    fi

    # GPU / devfreq nodes (informational)
    local gpu_nodes ddr_nodes
    gpu_nodes="$(ls /sys/class/devfreq 2>/dev/null | grep -iE 'mali|panfrost|panthor|gpu' | tr '\n' ' ' || true)"
    ddr_nodes="$(ls /sys/class/devfreq 2>/dev/null | grep -iE 'dmc|dram|ddr' | tr '\n' ' ' || true)"
    [ -n "$gpu_nodes" ] && log_info "GPU devfreq nodes: $gpu_nodes"
    [ -n "$ddr_nodes" ] && log_info "DDR devfreq nodes: $ddr_nodes"
    [ -z "$gpu_nodes" ] && log_warn "No GPU devfreq node found; GPU governor locking will be skipped at runtime."

    # Verdict
    if [ "$blocked" = "1" ]; then
        GATE_VERDICT="BLOCKED"
        log_err "GATE VERDICT: BLOCKED. Fix the issues above or run 'roblox-launcher doctor' for details."
        if [ "$mode" = "strict" ]; then
            echo "BLOCKED" > "$RT_STATE_DIR/gate.result" 2>/dev/null || true
            return 1
        fi
        return 0
    fi

    if [ "$warned" = "1" ]; then
        GATE_VERDICT="WARNED"
        log_warn "GATE VERDICT: APPROVED WITH WARNINGS (see above)."
    else
        GATE_VERDICT="APPROVED"
        log_ok "GATE VERDICT: APPROVED."
    fi
    echo "$GATE_VERDICT" > "$RT_STATE_DIR/gate.result" 2>/dev/null || true
    return 0
}
