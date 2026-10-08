#!/bin/zsh
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${1:-$ROOT_DIR/.cache/ai-search-audit}"
[[ "$OUTPUT_DIR" = /* ]] || OUTPUT_DIR="$PWD/$OUTPUT_DIR"
APP="$OUTPUT_DIR/FindUI AI Audit.app"
mkdir -p "$APP/Contents/MacOS" "$OUTPUT_DIR"
if [[ "${2:-}" != "--skip-build" ]]; then
if [[ "${2:-}" == "--reuse-debug" ]]; then
  PRODUCT_DIR="$ROOT_DIR/.build/out/out/Products/Debug"
  OBJECT_DIR=("$ROOT_DIR"/.build/out/out/Intermediates.noindex/FindUI.build/Debug/FindUI-*-testable-t.build/Objects-normal/arm64)
  swiftc -D FINDUI_AUDIT_IMPORT -swift-version 6 -parse-as-library -package-name find_ui -I "$OBJECT_DIR[1]" -I "$PRODUCT_DIR" \
    -module-cache-path /tmp/findui-clang-module-cache "$ROOT_DIR/scripts/audit_ai_search.swift" \
    "$OBJECT_DIR[1]"/*.o "$PRODUCT_DIR/SearchBackend.o" "$PRODUCT_DIR/SearchCore.o" -o "$APP/Contents/MacOS/audit"
else
sources=("$ROOT_DIR"/Sources/FindUI/*.swift)
sources=("${sources[@]:#*/FindUIApp.swift}")
bash "$ROOT_DIR/scripts/swiftc_with_search_core.sh" -disable-sandbox -swift-version 6 -parse-as-library -module-cache-path /tmp/findui-clang-module-cache \
  "${sources[@]}" "$ROOT_DIR/scripts/audit_ai_search.swift" -o "$APP/Contents/MacOS/audit"
fi
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.findui.ai-audit</string>
<key>CFBundleName</key><string>FindUI AI Audit</string>
<key>CFBundleExecutable</key><string>audit</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
fi
# Read through independent defaults processes so a cached UserDefaults instance
# cannot conceal an accidental write to the real app's configuration. Keep the
# bytes in memory, report only equality, and never restore or alter user data.
REAL_AI_CONFIGURATION_BEFORE="$(/usr/bin/defaults read com.codex.findui AISearchConfiguration 2>/dev/null || print -r -- '__FINDUI_CONFIGURATION_MISSING__')"
AUDIT_EXIT=0
"$APP/Contents/MacOS/audit" "$OUTPUT_DIR" > "$OUTPUT_DIR/audit.log" 2>&1 || AUDIT_EXIT=$?
REAL_AI_CONFIGURATION_AFTER="$(/usr/bin/defaults read com.codex.findui AISearchConfiguration 2>/dev/null || print -r -- '__FINDUI_CONFIGURATION_MISSING__')"
if [[ "$REAL_AI_CONFIGURATION_BEFORE" != "$REAL_AI_CONFIGURATION_AFTER" ]]; then
  print -r -- 'FAIL: Real AISearchConfiguration changed during the audit; no restoration was attempted.' >> "$OUTPUT_DIR/audit.log"
  AUDIT_EXIT=1
else
  print -r -- 'PASS: Real AISearchConfiguration is byte-for-byte unchanged.' >> "$OUTPUT_DIR/audit.log"
fi
unset REAL_AI_CONFIGURATION_BEFORE REAL_AI_CONFIGURATION_AFTER
cat "$OUTPUT_DIR/audit.log"
[[ "$AUDIT_EXIT" -eq 0 ]]
rg -q 'PASS: AI settings at 860 points' "$OUTPUT_DIR/audit.log"
