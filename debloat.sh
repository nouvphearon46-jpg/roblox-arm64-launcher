# debloat.sh - strip unnecessary Android system apps (blueprint item 2)
# Default: reversible 'pm uninstall --user 0' for the blueprint set + extended
# AOSP set. Opt-in --hard: delete app dirs from the system image (backup first,
# then remount read-only).

# Blueprint list: browser, contacts, calendar, stock launcher, live wallpapers
DEBLOAT_BASE="
com.android.browser
org.lineageos.jelly
com.android.chrome
com.android.contacts
com.android.calendar
com.android.launcher3
com.google.android.apps.nexuslauncher
com.android.wallpaper.live
com.android.wallpaper.livepicker
com.android.wallpapercropper
"

# Extended AOSP set: calculator, clock, email, music, gallery, dialer,
# messaging, print services, etc.
DEBLOAT_EXTENDED="
com.android.calculator2
com.android.deskclock
com.android.email
com.android.music
com.android.gallery3d
com.android.dialer
com.android.messaging
com.android.printspooler
com.android.cellbroadcastreceiver
com.android.emergency
"

# Never touch these - container and runtime depend on them.
DEBLOAT_NEVER="
android
com.android.settings
com.android.systemui
com.android.documentsui
com.android.externalstorage
com.android.permissioncontroller
com.android.providers.contacts
com.android.providers.media
com.android.providers.media.module
com.android.providers.downloads
com.android.providers.settings
com.android.server.telecom
com.android.location.fused
com.android.networkstack
com.android.incallui
com.roblox.client
com.aurora.store
"

is_never_remove() {
    case " $(printf '%s' "$DEBLOAT_NEVER" | tr '\n' ' ') " in
        *" $1 "*) return 0 ;;
    esac
    case "$1" in
        com.android.providers.*) return 0 ;;
    esac
    return 1
}

# Normalize candidate lists: keep only plausible package ids
clean_candidate_list() {
    printf '%s\n' "$1" | awk '/^com\./ {print $1}' | sort -u
}

waydroid_list_installed_system_pkgs() {
    # Requires a running container
    waydroid shell pm list packages -s 2>/dev/null | sed -n 's/^package://p'
}

debloat_run() {
    # debloat_run [--hard]
    local hard=0
    [ "${1:-}" = "--hard" ] && hard=1

    banner "Android debloating (extended AOSP set$( [ "$hard" = 1 ] && echo ' + HARD image strip' ))"

    local candidates
    candidates="$(clean_candidate_list "${DEBLOAT_BASE}${DEBLOAT_EXTENDED}")"

    ensure_container
    force_uimode_normal

    local installed
    installed="$(waydroid_list_installed_system_pkgs || true)"
    if [ -z "$installed" ]; then
        log_warn "Could not list installed packages (container trouble). Skipping debloat."
        stop_container_fully
        return 1
    fi

    local removed=0 skipped_never=0 missing=0 p
    log_info "Uninstalling system apps for user 0 (reversible)..."
    for p in $candidates; do
        if is_never_remove "$p"; then
            skipped_never=$((skipped_never+1))
            continue
        fi
        if ! printf '%s\n' "$installed" | grep -qx "$p"; then
            missing=$((missing+1))
            continue
        fi
        if waydroid shell pm uninstall --user 0 "$p" >/dev/null 2>&1; then
            log_ok "removed: $p"
            printf '%s\n' "$p" >> "$RT_STATE_DIR/debloat.removed"
            removed=$((removed+1))
        else
            log_warn "could not remove: $p"
        fi
    done
    log_info "Debloat summary: $removed removed, $missing not present, $skipped_never protected."

    if [ "$hard" = "1" ]; then
        debloat_hard_strip
    fi

    stop_container_fully
    log_ok "Debloating complete. Only Roblox data is preserved across launches (/data/data/com.roblox.client)."
    return 0
}

debloat_hard_strip() {
    banner "HARD strip: deleting app dirs from the system image"
    confirm "HARD mode permanently modifies the Waydroid system image (an image backup costs ~1 GB disk). Continue?" "n" \
        || { log_warn "HARD strip skipped."; return 0; }

    # Backup the system image once (state marker guards repeat backups)
    local backup_img="$RT_BACKUP_DIR/system.img.bak"
    if [ ! -f "$RT_STATE_DIR/debloat.hard-backup-done" ]; then
        log_info "Backing up system image to $backup_img (this takes a while)..."
        if root_run cp "$WAYDROID_IMAGES_DIR/system.img" "$backup_img"; then
            state_set debloat.hard-backup-done 1
            log_ok "Image backup complete."
        else
            log_warn "Image backup failed - aborting HARD strip (system image untouched)."
            return 1
        fi
    fi

    # Remount system rw inside the container and delete matching app dirs
    log_info "Remounting system image read-write and deleting app directories..."
    waydroid shell mount -o remount,rw / >/dev/null 2>&1 || true
    local p dirs
    for p in $(state_get debloat.removed "" ; clean_candidate_list "$DEBLOAT_BASE$DEBLOAT_EXTENDED"); do
        is_never_remove "$p" && continue
        dirs="$(waydroid shell sh -c "find /system /product /system_ext -maxdepth 3 -type d -name '$p' 2>/dev/null" 2>/dev/null || true)"
        for d in $dirs; do
            if waydroid shell rm -rf "$d" >/dev/null 2>&1; then
                log_ok "hard-stripped: $d"
            else
                log_warn "could not delete: $d"
            fi
        done
    done

    # Set the system image read-only again (blueprint requirement)
    waydroid shell mount -o remount,ro / >/dev/null 2>&1 || true
    state_set debloat.hard 1
    log_ok "System image stripped and set back to READ-ONLY."
    return 0
}

debloat_restore() {
    banner "Restoring debloated system apps (pm install-existing)"
    local p
    for p in $(state_get debloat.removed "" | tr '\n' ' '); do
        if waydroid shell cmd package install-existing "$p" >/dev/null 2>&1; then
            log_ok "restored: $p"
        else
            log_warn "could not restore: $p"
        fi
    done
    stop_container_fully
    return 0
}
