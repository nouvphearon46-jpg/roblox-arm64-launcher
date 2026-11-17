# aurora.sh - Anonymous Aurora Store install (blueprint item 3) + APK sideload
# Aurora in anonymous mode pulls official ARM64 Roblox split-APKs from Google's
# servers with no Google account, and can auto-update them silently.

AURORA_APK_URL_FDROID_API="https://f-droid.org/api/v1/packages/com.aurora.store"
AURORA_APK_URL_FDROID_REPO="https://f-droid.org/repo"
AURORA_APK_URL_GITLAB_API="https://gitlab.com/api/v4/projects/AuroraOSS%2FAuroraStore/releases/per_latest"

android_pkg_installed() {
    # android_pkg_installed PKG
    waydroid shell pm list packages 2>/dev/null | grep -qx "package:$1"
}

android_pkg_version() {
    # Prints versionName of an installed package (empty when unknown)
    waydroid shell dumpsys package "$1" 2>/dev/null \
        | awk '/^    versionName=/ {sub(/^    versionName=/,""); print; exit}'
}

# Resolve an Aurora Store APK URL. Tries F-Droid API, then F-Droid page, then
# GitLab releases. Prints the URL; empty on failure.
aurora_resolve_apk_url() {
    local code url

    # 1) F-Droid API: suggestedVersionCode -> repo APK
    code="$(curl -fsSL --retry 2 --max-time 30 "$AURORA_APK_URL_FDROID_API" 2>/dev/null \
        | grep -o '"suggestedVersionCode":[0-9]*' | head -n 1 | grep -o '[0-9]*$' || true)"
    if [ -n "$code" ]; then
        url="$AURORA_APK_URL_FDROID_REPO/com.aurora.store_${code}.apk"
        if curl -fsIL --max-time 20 "$url" >/dev/null 2>&1; then
            printf '%s' "$url"; return 0
        fi
    fi

    # 2) GitLab release asset (direct_asset_url)
    url="$(curl -fsSL --retry 2 --max-time 30 "$AURORA_APK_URL_GITLAB_API" 2>/dev/null \
        | grep -o '"direct_asset_url":"[^"]*\.apk"' | head -n 1 \
        | sed 's/"direct_asset_url":"//; s/"$//' || true)"
    [ -n "$url" ] && { printf '%s' "$url"; return 0; }

    # 3) F-Droid package page: first repo .apk link
    url="$(curl -fsSL --retry 2 --max-time 30 "https://f-droid.org/en/packages/com.aurora.store/" 2>/dev/null \
        | grep -o 'href="[^"]*/repo/com\.aurora\.store_[0-9]*\.apk"' | head -n 1 \
        | sed 's/^href="//; s/"$//' || true)"
    [ -n "$url" ] && { printf '%s' "$url"; return 0; }

    return 1
}

apk_sane() {
    # A valid APK is a zip: magic bytes "PK"
    [ "$(head -c 2 "$1" 2>/dev/null)" = "PK" ]
}

aurora_fetch_apk() {
    local out="$RT_CACHE_DIR/aurora-store.apk"
    local url
    log_info "Resolving latest Aurora Store release (F-Droid / GitLab)..."
    url="$(aurora_resolve_apk_url || true)"
    if [ -z "$url" ]; then
        log_warn "Could not resolve an Aurora Store APK URL automatically."
        return 1
    fi
    log_info "Downloading $url"
    if ! curl -fSL --retry 3 --max-time 300 -o "$out" "$url"; then
        log_warn "Download failed."
        return 1
    fi
    if ! apk_sane "$out"; then
        log_warn "Downloaded file is not a valid APK (bad magic bytes)."
        rm -f "$out"
        return 1
    fi
    log_ok "Aurora Store APK downloaded to $out"
    printf '%s' "$out"
    return 0
}

aurora_install() {
    banner "Aurora Store (anonymous mode)"
    if android_pkg_installed "$AURORA_ANDROID_PKG"; then
        log_ok "Aurora Store already installed (version $(android_pkg_version "$AURORA_ANDROID_PKG" 2>/dev/null || echo '?'))."
        return 0
    fi

    local apk
    apk="$(aurora_fetch_apk || true)"
    if [ -z "$apk" ] || [ ! -f "$apk" ]; then
        log_warn "Automatic Aurora Store download failed."
        log_warn "Manual fallback: download the APK from https://f-droid.org/en/packages/com.aurora.store/"
        log_warn "then run: roblox-launcher app install /path/to/aurora-store.apk"
        return 1
    fi

    ensure_container
    if waydroid app install "$apk"; then
        log_ok "Aurora Store installed."
    else
        stop_container_fully
        die "waydroid app install failed for Aurora Store." 1
    fi
    stop_container_fully

    log_ok "Anonymous mode: open Aurora once - it signs in ANONYMOUSLY, no Google account needed."
    log_ok "Auto-updates: in Aurora go to Settings -> Updates -> enable 'Automatic app updates';"
    log_ok "official ARM64 Roblox split-APKs then update silently from Google's servers,"
    log_ok "without wiping login tokens."
    return 0
}

# Sideload entry point: roblox-launcher app install FILE.apk [FILE2.apk ...]
app_install_apks() {
    local apks=("$@")
    [ "${#apks[@]}" -gt 0 ] || die "Usage: roblox-launcher app install FILE.apk [FILE2.apk ...]" 2
    local f
    for f in "${apks[@]}"; do
        [ -f "$f" ] || die "Not a file: $f" 2
        apk_sane "$f" || die "Not a valid APK (bad magic bytes): $f" 2
    done
    ensure_container
    log_info "Installing ${#apks[@]} APK file(s) (split-APK lists supported)..."
    if waydroid app install "${apks[@]}"; then
        log_ok "APK install finished."
    else
        stop_container_fully
        die "waydroid app install failed." 1
    fi
    stop_container_fully
}

app_list_installed() {
    ensure_container >/dev/null 2>&1 || true
    waydroid app list 2>/dev/null || true
    return 0
}

# Launch Aurora Store (used by `update` and first-run install guidance)
open_aurora() {
    if ! android_pkg_installed "$AURORA_ANDROID_PKG"; then
        log_err "Aurora Store is not installed. Run 'roblox-launcher setup' first." 1
        return 1
    fi
    ensure_container
    log_info "Starting Waydroid session for Aurora Store..."
    waydroid session start >/dev/null 2>&1 &
    local i=0
    while [ $i -lt 30 ]; do
        waydroid status 2>/dev/null | grep -q "Session:.*RUNNING" && break
        sleep 1; i=$((i+1))
    done
    force_uimode_normal
    waydroid app launch "$AURORA_ANDROID_PKG" || die "Could not launch Aurora Store." 1
    log_ok "Aurora Store launched. Anonymous session requires no Google account."
    log_ok "To auto-update Roblox silently: Settings -> Updates -> Automatic app updates."
    info_msg "Aurora Store opened.\n\nFirst time: it signs in ANONYMOUSLY (no Google account).\nSearch 'Roblox' and install it.\n\nEnable Settings -> Updates -> 'Automatic app updates'\nso Roblox keeps itself current."
}
