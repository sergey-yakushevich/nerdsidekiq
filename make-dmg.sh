#!/bin/bash
# Builds dist/NerdSidekiq.dmg — a drag-to-install disk image with a custom
# background, a custom volume icon, and the two icons pinned to the spots the
# background art was drawn around.
#
# Finder does the window styling, so this drives it over AppleScript. The first
# run asks for permission to control Finder; approve it or the layout step fails
# with "-1743 Not authorized to send Apple events".
set -euo pipefail
cd "$(dirname "$0")"

APP="build/NerdSidekiq.app"
VOL="NerdSidekiq"
OUT="dist/NerdSidekiq.dmg"
BG="assets/dmg/background.tiff"
ICNS="assets/icon/AppIcon.icns"

# Icon slots, in the same 660x480 coordinate space as the background art.
WIN_W=660; WIN_H=480
APP_X=165; APP_Y=245
LNK_X=495; LNK_Y=245
ICON_SIZE=128

[ -d "$APP" ] || { echo "no $APP — run ./build.sh first" >&2; exit 1; }

STAGE="$(mktemp -d)"
RW="$(mktemp -u).dmg"
MNT="/Volumes/$VOL"
cleanup() {
  hdiutil detach "$MNT" -quiet 2>/dev/null || true
  rm -rf "$STAGE" "$RW"
}
trap cleanup EXIT

# --- stage the volume contents -------------------------------------------
echo "staging..."
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
mkdir "$STAGE/.background"
cp "$BG" "$STAGE/.background/background.tiff"
# .VolumeIcon.icns is installed after the Finder pass — see below.

# --- create a writable image big enough for the payload + Finder metadata --
SIZE_KB=$(( $(du -sk "$STAGE" | cut -f1) + 20000 ))
hdiutil create -srcfolder "$STAGE" -volname "$VOL" -fs HFS+ \
  -format UDRW -size "${SIZE_KB}k" -ov "$RW" -quiet

hdiutil detach "$MNT" -quiet 2>/dev/null || true
hdiutil attach "$RW" -readwrite -noverify -noautoopen -quiet
sleep 1

# --- let Finder lay the window out ---------------------------------------
echo "laying out the window..."
osascript <<EOF
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, ${WIN_W} + 200, ${WIN_H} + 120}
    set vopts to the icon view options of container window
    set arrangement of vopts to not arranged
    set icon size of vopts to $ICON_SIZE
    set text size of vopts to 13
    set background picture of vopts to file ".background:background.tiff"
    set position of item "NerdSidekiq.app" of container window to {$APP_X, $APP_Y}
    set position of item "Applications" of container window to {$LNK_X, $LNK_Y}
    update without registering applications
    delay 2
    close
  end tell
end tell
EOF

# --- volume icon ---------------------------------------------------------
# This has to happen AFTER the Finder pass: Finder deletes .VolumeIcon.icns
# out of a volume it is styling, so installing it earlier loses the icon.
# The xattr flips the "has custom icon" bit (0x0400 of the Finder flags, bytes
# 8-9 of FinderInfo) — what SetFile -a C does, without the Xcode tools.
cp "$ICNS" "$MNT/.VolumeIcon.icns"
xattr -wx com.apple.FinderInfo \
  "0000000000000000040000000000000000000000000000000000000000000000" "$MNT"

[ -f "$MNT/.background/background.tiff" ] || { echo "background missing" >&2; exit 1; }
[ -f "$MNT/.DS_Store" ] || { echo "Finder never wrote the layout" >&2; exit 1; }
[ -f "$MNT/.VolumeIcon.icns" ] || { echo "volume icon missing" >&2; exit 1; }

sync
hdiutil detach "$MNT" -quiet
sleep 1

# --- compress ------------------------------------------------------------
echo "compressing..."
mkdir -p dist
rm -f "$OUT"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$OUT" -quiet

echo "built: $OUT ($(du -h "$OUT" | cut -f1))"
