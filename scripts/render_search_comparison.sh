#!/bin/zsh
set -euo pipefail
ROOT_DIR="${0:A:h:h}"
OUTPUT_DIR="${1:-$ROOT_DIR/docs}"
[[ "$OUTPUT_DIR" = /* ]] || OUTPUT_DIR="$PWD/$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR" "$ROOT_DIR/.cache/search-comparison"
if [[ "${2:-}" == "--reuse-debug" ]]; then
  PRODUCT_DIR="$(swift build --package-path "$ROOT_DIR" --disable-sandbox --show-bin-path)"
  BUILD_DIR="${PRODUCT_DIR:h:h}"
  OBJECT_DIR=("$BUILD_DIR"/Intermediates.noindex/FindUI.build/Debug/FindUI-*-testable-t.build/Objects-normal/arm64)
  swiftc -D FINDUI_AUDIT_IMPORT -swift-version 6 -parse-as-library -package-name find_ui -I "$OBJECT_DIR[1]" -I "$PRODUCT_DIR" \
    -module-cache-path /tmp/findui-clang-module-cache "$ROOT_DIR/scripts/render_search_comparison.swift" \
    "$OBJECT_DIR[1]"/*.o "$PRODUCT_DIR/SearchBackend.o" "$PRODUCT_DIR/SearchCore.o" -o "$ROOT_DIR/.cache/search-comparison/render"
else
  sources=("$ROOT_DIR"/Sources/FindUI/*.swift)
  sources=("${sources[@]:#*/FindUIApp.swift}")
  bash "$ROOT_DIR/scripts/swiftc_with_search_core.sh" -swift-version 6 -parse-as-library -module-cache-path /tmp/findui-clang-module-cache \
    "${sources[@]}" "$ROOT_DIR/scripts/render_search_comparison.swift" -o "$ROOT_DIR/.cache/search-comparison/render"
fi
# Resolve real tool executables beside the renderer, without exposing the
# checkout's home directory in the command footer. Only synthetic files and
# isolated preferences are used by the renderer.
DEMO_DIR="$(mktemp -d /tmp/findui-demo-tools.XXXXXX)"
trap 'rm -rf "$DEMO_DIR"' EXIT
cp "$ROOT_DIR/.cache/search-comparison/render" "$DEMO_DIR/render"
for tool in fd rg fzf; do
  cp "$ROOT_DIR/.build/search-tools/bin/$tool" "$DEMO_DIR/$tool"
done
cp "$ROOT_DIR/.build/content-worker/release/findui-content" "$DEMO_DIR/findui-content"
"$DEMO_DIR/render" "$OUTPUT_DIR"
