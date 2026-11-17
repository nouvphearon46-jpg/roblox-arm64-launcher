#!/usr/bin/env bash
# build-deb.sh - build roblox-arm64-launcher_<version>_arm64.deb
# Runs on any machine with dpkg-deb (no root needed; --root-owner-group).

set -u

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"

VERSION="$(tr -d '[:space:]' < VERSION 2>/dev/null || echo "1.0.0")"
STAGE="$here/build/pkg"
OUT_DIR="$here/dist"
PKG_NAME="roblox-arm64-launcher"

echo "== Building $PKG_NAME $VERSION (arm64) =="

# --- sanity: bash syntax check every shipped script ------------------------
fail=0
for f in src/roblox-launcher src/lib/*.sh packaging/postinst packaging/prerm packaging/postrm; do
    if bash -n "$f" 2>syntax.err; then
        echo "  syntax OK : $f"
    else
        echo "  SYNTAX ERR: $f"
        cat syntax.err
        fail=1
    fi
done
rm -f syntax.err
[ "$fail" = "0" ] || { echo "Syntax check failed; aborting."; exit 1; }

# --- stage the package tree ------------------------------------------------
rm -rf "$STAGE" "$OUT_DIR"
mkdir -p "$STAGE/DEBIAN" "$OUT_DIR"

install -Dm755 src/roblox-launcher                       "$STAGE/usr/bin/roblox-launcher"
for lib in src/lib/*.sh; do
    install -Dm644 "$lib"                                "$STAGE/usr/lib/roblox-arm64-launcher/lib/$(basename "$lib")"
done
# Keep the runtime version constant in sync with the VERSION file so the CLI
# can never drift from the package control version.
sed -i "s/^ROBLOX_LAUNCHER_VERSION=.*/ROBLOX_LAUNCHER_VERSION=\"$VERSION\"/" \
    "$STAGE/usr/lib/roblox-arm64-launcher/lib/common.sh"
install -Dm644 packaging/roblox-launcher.desktop         "$STAGE/usr/share/applications/roblox-launcher.desktop"
install -Dm644 packaging/roblox-arm64-launcher.svg       "$STAGE/usr/share/icons/hicolor/scalable/apps/roblox-arm64-launcher.svg"
install -Dm644 README.md                                 "$STAGE/usr/share/doc/$PKG_NAME/README.md"
install -Dm644 packaging/copyright                       "$STAGE/usr/share/doc/$PKG_NAME/copyright"
gzip -n -9 -c packaging/changelog > "$STAGE/usr/share/doc/$PKG_NAME/changelog.gz"

for maint in postinst prerm postrm; do
    install -Dm755 "packaging/$maint" "$STAGE/DEBIAN/$maint"
done

# --- control: substitute version + installed size ---------------------------
installed_size="$(du -sk "$STAGE" | awk '{print $1}')"
sed -e "s/@VERSION@/$VERSION/" \
    -e "s/^Installed-Size:.*/Installed-Size: $installed_size/" \
    -e "0,/^Description:/s//Installed-Size: $installed_size\nDescription:/" \
    packaging/control > "$STAGE/DEBIAN/control"

# --- build -------------------------------------------------------------------
deb="$OUT_DIR/${PKG_NAME}_${VERSION}_arm64.deb"
dpkg-deb --build --root-owner-group "$STAGE" "$deb"

# Blueprint wants a plain distributable name too:
cp "$deb" "$OUT_DIR/${PKG_NAME}.deb"

echo
echo "== Output =="
ls -lh "$OUT_DIR"
echo
dpkg-deb -I "$deb" | sed -n '1,12p'
echo
echo "Package contents:"
dpkg-deb -c "$deb"
