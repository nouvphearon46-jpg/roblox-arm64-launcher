# common.sh - shared helpers, paths, logging, config for the Roblox ARM64 Launcher
# Part of roblox-arm64-launcher. All messages are ASCII-only by design.

ROBLOX_LAUNCHER_VERSION="1.0.2"
ROBLOX_LAUNCHER_NAME="Roblox ARM64 Launcher"

# Hidden runtime directory (blueprint requirement: hidden, no visible Android UI)
RT_DIR="${HOME}/.local/share/.roblox-runtime"
RT_STATE_DIR="${RT_DIR}/state"
RT_BACKUP_DIR="${RT_DIR}/backups"
RT_LOG_DIR="${RT_DIR}/logs"
RT_CACHE_DIR="${RT_DIR}/cache"
RT_CONFIG_FILE="${RT_DIR}/config"
RT_LOG_FILE="${RT_LOG_DIR}/launcher.log"

# Android package ids
ROBLOX_ANDROID_PKG="com.roblox.client"
AURORA_ANDROID_PKG="com.aurora.store"

# Well-known paths
WAYDROID_CFG="/var/lib/waydroid/waydroid.cfg"
WAYDROID_IMAGES_DIR="/var/lib/waydroid/images"
PI_CONFIG_CANDIDATES="/boot/firmware/config.txt /boot/config.txt"

ASSUME_YES="${ASSUME_YES:-0}"

# ---------------------------------------------------------------- logging ---
_use_color() { [ -t 1 ]; }

_log_write() {
    # $1 = level, rest = message
    local lvl="$1"; shift
    local msg
    msg="$*"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo '-')"
    # Best-effort file log (never fails the caller)
    printf '%s [%s] %s\n' "$ts" "$lvl" "$msg" >> "$RT_LOG_FILE" 2>/dev/null || true
}

# Console diagnostics go to stderr so stdout stays clean for captured data.
log_info() { printf '[INFO] %s\n' "$*" >&2; _log_write INFO "$*"; }
log_ok()   { printf '[OK]   %s\n' "$*" >&2; _log_write OK "$*"; }
log_warn() { printf '[WARN] %s\n' "$*" >&2; _log_write WARN "$*"; }
log_err()  { printf '[ERR]  %s\n' "$*" >&2; _log_write ERR "$*"; }

banner() {
    printf '\n============================================================\n== %s\n============================================================\n' "$*"
    _log_write STEP "== $*"
}

die() {
    # die "message" [exit_code]
    log_err "$1"
    exit "${2:-1}"
}

# ------------------------------------------------------------- primitives ---
have()        { command -v "$1" >/dev/null 2>&1; }
is_root()     { [ "$(id -u 2>/dev/null || echo 1)" = "0" ]; }
is_arm64()    { [ "$(uname -m 2>/dev/null)" = "aarch64" ]; }

rt_init_dirs() {
    mkdir -p "$RT_STATE_DIR" "$RT_BACKUP_DIR" "$RT_LOG_DIR" "$RT_CACHE_DIR" 2>/dev/null || true
    chmod 700 "$RT_DIR" 2>/dev/null || true
}

# Run a single command with root privileges. Prefers sudo, then pkexec.
root_run() {
    if is_root; then
        "$@"
    elif have sudo; then
        sudo "$@"
    elif have pkexec; then
        pkexec "$@"
    else
        die "Root privileges required (command: $*) but neither sudo nor pkexec is available." 1
    fi
}

# Confirm a destructive/important action. Uses zenity when a GUI is present.
confirm() {
    # confirm "question" [default: y|n]
    local q="$1" def="${2:-y}" ans
    if [ "${ASSUME_YES:-0}" = "1" ]; then return 0; fi
    if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && have zenity; then
        zenity --question --no-wrap --text="$q" >/dev/null 2>&1 && return 0
        return 1
    fi
    if [ ! -t 0 ]; then
        # Non-interactive without GUI: fail closed unless ASSUME_YES
        [ "${ASSUME_YES:-0}" = "1" ] && return 0
        return 1
    fi
    printf '%s [%s/n]: ' "$q" "$def"
    read -r ans || return 1
    [ -z "$ans" ] && ans="$def"
    case "$ans" in Y|y|yes|YES) return 0 ;; *) return 1 ;; esac
}

info_msg() {
    local msg="$1"
    if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && have zenity; then
        zenity --info --no-wrap --text="$msg" >/dev/null 2>&1 || true
    else
        printf '%s\n' "$msg"
    fi
}

# ----------------------------------------------------------------- config ---
# Simple KEY=VALUE store at ~/.local/share/.roblox-runtime/config
config_get() {
    # config_get KEY [default]
    local key="$1" def="${2:-}" v=""
    if [ -f "$RT_CONFIG_FILE" ]; then
        v="$(sed -n "s/^${key}=//p" "$RT_CONFIG_FILE" 2>/dev/null | tail -n 1)"
    fi
    if [ -n "$v" ]; then printf '%s' "$v"; else printf '%s' "$def"; fi
}

config_set() {
    # config_set KEY VALUE
    local key="$1" val="$2"
    rt_init_dirs
    touch "$RT_CONFIG_FILE" 2>/dev/null || die "Cannot write config file: $RT_CONFIG_FILE"
    if grep -q "^${key}=" "$RT_CONFIG_FILE" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${val}|" "$RT_CONFIG_FILE"
    else
        printf '%s=%s\n' "$key" "$val" >> "$RT_CONFIG_FILE"
    fi
}

config_list() {
    if [ -f "$RT_CONFIG_FILE" ] && [ -s "$RT_CONFIG_FILE" ]; then
        cat "$RT_CONFIG_FILE"
    else
        echo "(no user overrides - all defaults active)"
    fi
}

# ------------------------------------------------------------------ state ---
state_get() {
    # state_get KEY [default]
    local key="$1" def="${2:-}" v=""
    local f="$RT_STATE_DIR/${key}"
    if [ -f "$f" ]; then
        v="$(head -n 1 "$f" 2>/dev/null)"
    fi
    if [ -n "$v" ]; then printf '%s' "$v"; else printf '%s' "$def"; fi
}

state_set() {
    # state_set KEY VALUE
    local key="$1" val="$2"
    rt_init_dirs
    printf '%s\n' "$val" > "$RT_STATE_DIR/$key" 2>/dev/null || true
}

state_del() {
    rm -f "$RT_STATE_DIR/$1" 2>/dev/null || true
}

# Append a token to a space-separated progress file (for setup resume)
state_progress_add() {
    rt_init_dirs
    local existing
    existing="$(state_get setup.progress "")"
    case " $existing " in
        *" $1 "*) return 0 ;;
    esac
    printf '%s %s\n' "$existing" "$1" > "$RT_STATE_DIR/setup.progress"
}

state_progress_has() {
    local existing
    existing="$(state_get setup.progress "")"
    case " $existing " in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
}
