#!/bin/zsh
# Opt-in: makes real requests using the requested existing login/key file.
set -euo pipefail
root="${0:A:h:h}"
cd "$root"
output="$root/.cache/ai-live"
mkdir -p "$output"
if [[ "${FINDUI_AUDIT_REUSE_DEBUG:-0}" == 1 ]]; then
  products="${FINDUI_AUDIT_PRODUCTS:-$root/.build/out/out/Products/Debug}"
  swiftc -swift-version 6 -parse-as-library -package-name find_ui -I "$products" \
    -module-cache-path /tmp/findui-clang-module-cache "$root/scripts/audit_ai_live.swift" \
    "$products/SearchBackend.o" "$products/SearchCore.o" -o "$output/audit"
else
  bash "$root/scripts/swiftc_with_search_core.sh" -swift-version 6 -parse-as-library \
    -module-cache-path /tmp/findui-clang-module-cache "$root/scripts/audit_ai_live.swift" -o "$output/audit"
fi
"$output/audit" "$@"
