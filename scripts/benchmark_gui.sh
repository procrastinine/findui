#!/bin/zsh
set -euo pipefail
root="${0:A:h:h}"
source_root="${FINDUI_AUDIT_SOURCE_ROOT:-$root}"
output="${1:-$root/.cache/gui-benchmark}"
work=$(mktemp -d /tmp/findui-gui-benchmark.XXXXXXXX)
trap 'rm -rf "$work"' EXIT
app="$work/FindUI Benchmark.app"
mkdir -p "$app/Contents/MacOS" "$output"
sources=("$source_root"/Sources/FindUI/*.swift)
sources=("${sources[@]:#*/FindUIApp.swift}")
bash "$root/scripts/swiftc_with_search_core.sh" -O -swift-version 6 -parse-as-library \
  -module-cache-path /tmp/findui-clang-module-cache "${sources[@]}" "$root/scripts/benchmark_gui.swift" -o "$app/Contents/MacOS/audit"
benchmark_app="${FINDUI_BENCHMARK_APP:-$root/dist/FindUI.app}"
for tool in fd rg fzf findui-content; do cp "$benchmark_app/Contents/MacOS/$tool" "$app/Contents/MacOS/$tool"; done
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>local.findui.gui-benchmark</string><key>CFBundleName</key><string>FindUI Benchmark</string><key>CFBundleExecutable</key><string>audit</string><key>CFBundlePackageType</key><string>APPL</string><key>NSPrincipalClass</key><string>NSApplication</string></dict></plist>
PLIST
codesign --force --sign - "$app"
: > "$output/audit.log"
open -W -n --stdout "$output/audit.log" --stderr "$output/audit.log" "$app" --args "$output"
cat "$output/audit.log"
if rg -q '^FAIL:' "$output/audit.log"; then exit 1; fi
rg -q '^PASS: GUI responsiveness benchmark$' "$output/audit.log"
