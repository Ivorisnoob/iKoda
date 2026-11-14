#!/bin/bash
# Packs Koda.app into the disk image people install from: a window of its own, laid out on
# dmg-background.tiff (Koda on the left, Applications on the right, an arrow between), no
# toolbar or status bar, and the disk wearing Koda's icon.
#
#   Packaging/make-dmg.sh path/to/Koda.app path/to/Koda.dmg
#
# Finder writes the layout into the image's .DS_Store when told to through AppleScript, so this
# needs a logged-in session with Finder (a Mac, or GitHub's macOS runners).
set -euo pipefail

app="$1"
out="$2"
here="$(cd "$(dirname "$0")" && pwd)"
# Kept in step with dmg-background.swift, where the arrow is drawn between these.
window_width=640
window_height=420
icon_size=112
app_x=176
apps_x=464
icons_y=214

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
stage="$work/stage"
mkdir -p "$stage/.background"
cp -R "$app" "$stage/Koda.app"
ln -s /Applications "$stage/Applications"
cp "$here/dmg-background.tiff" "$stage/.background/background.tiff"
# The disk's own icon, as Finder and the Desktop show it while mounted.
cp "$app/Contents/Resources/AppIcon.icns" "$stage/.VolumeIcon.icns"

# Built writable first, so Finder can save the window's layout into it.
hdiutil create -quiet -srcfolder "$stage" -volname Koda -fs HFS+ -format UDRW -ov "$work/rw.dmg"
mount="$(hdiutil attach -readwrite -noverify -noautoopen "$work/rw.dmg" | awk -F'\t' '/\/Volumes\// { print $NF }' | tail -n 1)"
volume="$(basename "$mount")"
xcrun SetFile -a C "$mount"

layout() {
    osascript <<EOF
tell application "Finder"
    tell disk "$volume"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        -- Bounds include the title bar; the picture fills what's under it.
        set the bounds of container window to {200, 120, 200 + $window_width, 120 + $window_height + 32}
        set options to the icon view options of container window
        set arrangement of options to not arranged
        set icon size of options to $icon_size
        set text size of options to 12
        set label position of options to bottom
        set shows item info of options to false
        set shows icon preview of options to true
        set background picture of options to file ".background:background.tiff"
        set position of item "Koda.app" of container window to {$app_x, $icons_y}
        set position of item "Applications" of container window to {$apps_x, $icons_y}
        update without registering applications
        delay 1
        -- Opened later, nothing should already be picked.
        tell application "Finder" to set selection to {}
        close
    end tell
end tell
EOF
}

# Finder on a fresh CI runner can be slow to answer its first Apple Event.
for attempt in 1 2 3; do
    if layout; then break; fi
    if [ "$attempt" = 3 ]; then echo "Finder couldn't lay out the window" >&2; hdiutil detach -quiet "$mount"; exit 1; fi
    sleep 5
done

# Let Finder finish writing .DS_Store before the disk goes.
for _ in $(seq 1 10); do [ -f "$mount/.DS_Store" ] && break; sleep 1; done
rm -rf "$mount/.fseventsd"
sync
hdiutil detach -quiet "$mount" || { sleep 3; hdiutil detach -force -quiet "$mount"; }

hdiutil convert -quiet "$work/rw.dmg" -format ULFO -ov -o "$out"
echo "Wrote $out"
