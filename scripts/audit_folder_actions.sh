#!/bin/zsh
set -euo pipefail
ROOT_DIR="${0:A:h:h}"
OUTPUT_DIR="${1:-$ROOT_DIR/.cache/folder-actions-audit}"
[[ "$OUTPUT_DIR" = /* ]] || OUTPUT_DIR="$PWD/$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
if [[ "${2:-}" == "--reuse-debug" ]]; then
  PRODUCT_DIR="$(swift build --package-path "$ROOT_DIR" --scratch-path "$ROOT_DIR/.build/out" --disable-sandbox --show-bin-path)"
  BUILD_DIR="${PRODUCT_DIR:h:h}"
  OBJECT_DIR=("$BUILD_DIR"/Intermediates.noindex/FindUI.build/Debug/FindUI-*-testable-t.build/Objects-normal/arm64)
  swiftc -D FINDUI_AUDIT_IMPORT -swift-version 6 -parse-as-library -package-name find_ui -I "$OBJECT_DIR[1]" -I "$PRODUCT_DIR" \
    -module-cache-path /tmp/findui-clang-module-cache "$ROOT_DIR/scripts/audit_folder_actions.swift" \
    "$OBJECT_DIR[1]"/*.o "$PRODUCT_DIR/SearchBackend.o" "$PRODUCT_DIR/SearchCore.o" -o "$OUTPUT_DIR/audit"
else
  sources=("$ROOT_DIR"/Sources/FindUI/*.swift)
  sources=("${sources[@]:#*/FindUIApp.swift}")
  bash "$ROOT_DIR/scripts/swiftc_with_search_core.sh" -swift-version 6 -parse-as-library -module-cache-path /tmp/findui-clang-module-cache \
    "${sources[@]}" "$ROOT_DIR/scripts/audit_folder_actions.swift" -o "$OUTPUT_DIR/audit"
fi
"$OUTPUT_DIR/audit" "$OUTPUT_DIR" > "$OUTPUT_DIR/audit.log" 2>&1
cat "$OUTPUT_DIR/audit.log"
