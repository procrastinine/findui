#!/bin/zsh
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${1:-$ROOT_DIR/.cache/settings-polish}"
[[ "$OUTPUT_DIR" = /* ]] || OUTPUT_DIR="$PWD/$OUTPUT_DIR"
APP="$OUTPUT_DIR/FindUI Settings Audit.app"
mkdir -p "$APP/Contents/MacOS" "$OUTPUT_DIR"
if [[ "${@:2}" != *--skip-build* ]]; then
if [[ "${@:2}" == *--reuse-debug* ]]; then
PRODUCT_DIR="$ROOT_DIR/.build/out/out/Products/Debug"
OBJECT_DIR=("$ROOT_DIR"/.build/out/out/Intermediates.noindex/FindUI.build/Debug/FindUI-*-testable-t.build/Objects-normal/arm64)
swiftc -D FINDUI_AUDIT_IMPORT -swift-version 6 -parse-as-library -package-name find_ui \
  -I "$OBJECT_DIR[1]" -I "$PRODUCT_DIR" -module-cache-path /tmp/findui-clang-module-cache \
  "$ROOT_DIR/scripts/audit_settings.swift" "$OBJECT_DIR[1]"/*.o \
  "$PRODUCT_DIR/SearchBackend.o" "$PRODUCT_DIR/SearchCore.o" -o "$APP/Contents/MacOS/audit"
else
sources=("$ROOT_DIR"/Sources/FindUI/*.swift)
sources=("${sources[@]:#*/FindUIApp.swift}")
bash "$ROOT_DIR/scripts/swiftc_with_search_core.sh" -disable-sandbox -swift-version 6 -parse-as-library -module-cache-path /tmp/findui-clang-module-cache \
  "${sources[@]}" "$ROOT_DIR/scripts/audit_settings.swift" -o "$APP/Contents/MacOS/audit"
fi
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.findui.settings-audit</string>
<key>CFBundleName</key><string>FindUI Settings Audit</string>
<key>CFBundleExecutable</key><string>audit</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
fi
: > "$OUTPUT_DIR/audit.log"
"$APP/Contents/MacOS/audit" "$OUTPUT_DIR" "${@:2}" > "$OUTPUT_DIR/audit.log" 2>&1
cat "$OUTPUT_DIR/audit.log"
if [[ "${2:-}" == "--layout-only" ]]; then
  rg -q 'PASS: Search UI layouts and accessibility actions audited without desktop activation' "$OUTPUT_DIR/audit.log"
else
  rg -q 'PASS: Settings interactions, minimum-size layout, wide/dark layout and Advanced disclosure audited' "$OUTPUT_DIR/audit.log"
fi
