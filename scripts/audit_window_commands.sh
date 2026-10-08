#!/bin/zsh
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
AUDIT_DIR="$(mktemp -d /tmp/findui-window-commands.XXXXXX)"
trap 'rm -rf "$AUDIT_DIR"' EXIT
sources=("$ROOT_DIR"/Sources/FindUI/*.swift)
sources=("${sources[@]:#*/FindUIApp.swift}")
APP="$AUDIT_DIR/FindUI Window Audit.app"
mkdir -p "$APP/Contents/MacOS"
bash "$ROOT_DIR/scripts/swiftc_with_search_core.sh" -disable-sandbox -swift-version 6 -parse-as-library -module-cache-path /tmp/findui-clang-module-cache \
  "${sources[@]}" "$ROOT_DIR/scripts/audit_window_commands.swift" -o "$APP/Contents/MacOS/audit"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.findui.window-audit</string>
<key>CFBundleName</key><string>FindUI Window Audit</string>
<key>CFBundleExecutable</key><string>audit</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
open -W -n --stdout "$AUDIT_DIR/audit.log" --stderr "$AUDIT_DIR/audit.log" "$APP"
cp "$AUDIT_DIR/audit.log" "$ROOT_DIR/.cache/window-commands-audit.log"
cat "$AUDIT_DIR/audit.log"
rg -q 'Command-N, Command-T, Command-W, Settings.*passed' "$AUDIT_DIR/audit.log"
