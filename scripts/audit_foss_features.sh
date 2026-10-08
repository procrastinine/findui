#!/bin/zsh
set -euo pipefail
root="${0:A:h:h}"
output="${1:-$root/.cache/foss-features-ui}"
work=$(mktemp -d /tmp/findui-foss-ui.XXXXXXXX)
trap 'rm -rf "$work"' EXIT
app="$work/FindUI Feature Audit.app"
mkdir -p "$app/Contents/MacOS" "$output"
sources=("$root"/Sources/FindUI/*.swift)
sources=("${sources[@]:#*/FindUIApp.swift}")
bash "$root/scripts/swiftc_with_search_core.sh" -disable-sandbox -swift-version 6 -parse-as-library -module-cache-path /tmp/findui-clang-module-cache "${sources[@]}" "$root/scripts/audit_foss_features.swift" -o "$app/Contents/MacOS/audit"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>local.findui.feature-audit</string><key>CFBundleName</key><string>FindUI Feature Audit</string><key>CFBundleExecutable</key><string>audit</string><key>CFBundlePackageType</key><string>APPL</string><key>NSPrincipalClass</key><string>NSApplication</string></dict></plist>
PLIST
codesign --force --sign - "$app"
if [[ -f "$output/audit.log" ]]; then cp "$output/audit.log" "$output/previous-audit.log"; fi
: > "$output/audit.log"
open -W -n --stdout "$output/audit.log" --stderr "$output/audit.log" "$app" --args "$output"
cat "$output/audit.log"
if rg -q '^FAIL:' "$output/audit.log"; then exit 1; fi
rg -q 'PASS: bounded long-line previews navigate between highlights; multiline regex results render with context' "$output/audit.log"
