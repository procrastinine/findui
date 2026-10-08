#!/bin/zsh
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_PATH="${FINDUI_AUDIT_OUTPUT:-$ROOT_DIR/.cache/verification/screenshot.png}"
mkdir -p "$(dirname "$OUTPUT_PATH")"
RENDER_DIR="$(mktemp -d /tmp/findui-screenshot.XXXXXX)"
trap 'rm -rf "$RENDER_DIR"' EXIT
SOURCE_ROOT="${FINDUI_AUDIT_SOURCE_ROOT:-$ROOT_DIR}"
sources=("$SOURCE_ROOT"/Sources/FindUI/*.swift)
sources=("${sources[@]:#*/FindUIApp.swift}")
bash "$ROOT_DIR/scripts/swiftc_with_search_core.sh" -disable-sandbox -swift-version 6 -parse-as-library \
  -module-cache-path /tmp/findui-clang-module-cache \
  "${sources[@]}" "$ROOT_DIR/scripts/render_screenshot.swift" \
  -o "$RENDER_DIR/render"
if [[ " $* " == *" --layout-only "* ]]; then
  "$RENDER_DIR/render" "$OUTPUT_PATH" "$@"
else
  # LaunchServices grants normal foreground activation. A bare command-line
  # process can render AppKit but macOS may deny its key-window request.
  AUDIT_APP="$RENDER_DIR/FindUI Audit.app"
  mkdir -p "$AUDIT_APP/Contents/MacOS"
  cp "$RENDER_DIR/render" "$AUDIT_APP/Contents/MacOS/audit"
  cat > "$AUDIT_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.findui.native-audit</string>
<key>CFBundleName</key><string>FindUI Audit</string>
<key>CFBundleExecutable</key><string>audit</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
  codesign --force --sign - "$AUDIT_APP"
  AUDIT_LAUNCH_STATUS=0
  open -W -n --stdout "$RENDER_DIR/audit.log" --stderr "$RENDER_DIR/audit.log" "$AUDIT_APP" --args "$OUTPUT_PATH" "$@" || AUDIT_LAUNCH_STATUS=$?
  if [[ -f "$RENDER_DIR/audit.log" ]]; then
    cp "$RENDER_DIR/audit.log" "$ROOT_DIR/.cache/native-ui-audit-last.log"
    cat "$RENDER_DIR/audit.log"
  fi
  if (( AUDIT_LAUNCH_STATUS != 0 )); then
    exit "$AUDIT_LAUNCH_STATUS"
  fi
  rg -q 'Native grouping, multi-selection, row-click focus' "$RENDER_DIR/audit.log"
fi
