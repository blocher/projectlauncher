#!/bin/zsh
# Builds ProjectLauncher.app and installs it to ~/Applications.
#   ./build.sh            build + install (+ relaunch if it was running)
#   ./build.sh --no-install
set -euo pipefail

ROOT=${0:A:h}
NAME=ProjectLauncher
BUILD="$ROOT/build"
APP="$BUILD/Project Launcher.app"
DEST="$HOME/Applications/Project Launcher.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# App icon from assets/launcher.svg.
ICONSET="$BUILD/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  rsvg-convert -w $size -h $size "$ROOT/assets/launcher.svg" -o "$ICONSET/icon_${size}x${size}.png"
  rsvg-convert -w $((size * 2)) -h $((size * 2)) "$ROOT/assets/launcher.svg" -o "$ICONSET/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

swiftc -O -swift-version 5 -target arm64-apple-macos15.0 \
  -o "$APP/Contents/MacOS/$NAME" "$ROOT"/Sources/**/*.swift

# Starting point for "Create New Config" on first run. Your own config lives in ~/.config/projectlauncher.
/bin/cp -R "$ROOT/examples" "$APP/Contents/Resources/examples"
# The launcher generator (also published as the dev-launcher Claude Code skill), run with the system python3.
/bin/cp -R "$ROOT/skills/dev-launcher" "$APP/Contents/Resources/generator"
/bin/rm -rf "$APP/Contents/Resources/generator/__pycache__"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>com.benjaminlocher.ProjectLauncher</string>
  <key>CFBundleName</key><string>Project Launcher</string>
  <key>CFBundleDisplayName</key><string>Project Launcher</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Project Launcher reads your iTerm windows to show which projects are running, and switches to or closes them.</string>
</dict>
</plist>
EOF

# A stable identity keeps the iTerm Automation permission across rebuilds; ad-hoc signing would re-prompt.
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed: ${IDENTITY:-ad-hoc})"

[[ "${1:-}" == "--no-install" ]] && exit 0

was_running=0
if pgrep -xq "$NAME"; then
  was_running=1
  # SIGTERM rather than an AppleScript quit, which stalls while the picker menu is open. There's no state to save.
  pkill -x "$NAME" || true
  while pgrep -xq "$NAME"; do sleep 0.2; done
fi
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
ditto "$APP" "$DEST"
echo "Installed $DEST"
(( was_running )) && sleep 1 && open -g "$DEST" --args --background || true
