# perf.sh - BIOS-style performance mode (blueprint item 6)
# Locks CPU, GPU (Mali/Panfrost/Panthor via devfreq) and DDR governors to
# 'performance', plus Android fixed-performance-mode. Fully reverted on exit.

PERF_NODES_FILE="$RT_STATE_DIR/perf.nodes"

perf_discover_nodes() {
    # Emit list of governor files: CPU cpufreq + GPU/DDR devfreq
    local cpu_nodes ddr_gpu_nodes
    cpu_nodes="$(ls /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null || true)"
    ddr_gpu_nodes="$(ls /sys/class/devfreq/* 2>/dev/null | grep -iE 'mali|panfrost|panthor|gpu|dmc|dram|ddr' || true)"
    printf '%s\n%s\n' "$cpu_nodes" "$ddr_gpu_nodes" | awk 'NF'
}

perf_save_current() {
    rt_init_dirs
    local f val out=""
    while IFS= read -r f; do
        [ -e "$f" ] || continue
        val="$(cat "$f" 2>/dev/null || echo schedutil)"
        out="$out$f $val\n"
    done < <(perf_discover_nodes)
    printf '%b' "$out" > "$PERF_NODES_FILE"
}

perf_set_all() {
    # perf_set_all GOVERNOR
    local gov="$1" f ok=0 fail=0
    while IFS= read -r f; do
        [ -e "$f" ] || continue
        if root_run sh -c "echo $gov > '$f'" 2>/dev/null; then
            ok=$((ok+1))
        else
            fail=$((fail+1))
        fi
    done < "$PERF_NODES_FILE"
    printf '%d %d' "$ok" "$fail"
}

perf_on() {
    # Idempotent
    if [ -f "$RT_STATE_DIR/perf.on" ]; then return 0; fi
    banner "Performance mode: locking CPU/GPU/DDR governors"
    perf_save_current
    local counts ok fail
    counts="$(perf_set_all performance || printf '0 1')"
    ok="${counts%% *}"; fail="${counts##* }"
    if [ "${ok:-0}" -gt 0 ]; then
        log_ok "$ok governor node(s) locked to performance ($fail skipped - permission or missing)."
    else
        log_warn "No governor nodes could be locked to performance (missing cpufreq/devfreq or permissions)."
    fi
    # CPU energy performance preference where available
    local epp
    for epp in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
        [ -e "$epp" ] || continue
        root_run sh -c "echo performance > '$epp'" >/dev/null 2>&1 || true
    done
    # Android fixed performance mode (only while container runs; re-applied by run.sh)
    if have waydroid; then
        waydroid shell cmd power set-fixed-performance-mode-enabled true >/dev/null 2>&1 || true
        log_ok "Android fixed-performance-mode enabled."
    fi
    touch "$RT_STATE_DIR/perf.on"
}

perf_off() {
    # Idempotent. Reverts to the saved originals (default schedutil).
    [ -f "$RT_STATE_DIR/perf.on" ] || return 0
    if have waydroid; then
        waydroid shell cmd power set-fixed-performance-mode-enabled false >/dev/null 2>&1 || true
    fi
    if [ -s "$PERF_NODES_FILE" ]; then
        local f val restored=0
        while read -r f val; do
            [ -e "$f" ] || continue
            val="${val:-schedutil}"
            if root_run sh -c "echo $val > '$f'" 2>/dev/null; then
                restored=$((restored+1))
            else
                root_run sh -c "echo schedutil > '$f'" >/dev/null 2>&1 || true
            fi
        done < "$PERF_NODES_FILE"
        log_ok "Performance mode OFF: $restored governor node(s) reverted (default schedutil)."
    fi
    rm -f "$RT_STATE_DIR/perf.on" "$PERF_NODES_FILE"
    return 0
}
