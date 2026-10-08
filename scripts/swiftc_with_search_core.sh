#!/bin/bash
# Compile native audit executables against the same headless module as the app.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
source_root="${FINDUI_AUDIT_SOURCE_ROOT:-$root}"
module_dir=$(mktemp -d /tmp/findui-search-core.XXXXXX)
trap 'rm -rf "$module_dir"' EXIT
swiftc -whole-module-optimization -O -swift-version 6 -parse-as-library -module-name SearchCore \
  -module-cache-path /tmp/findui-clang-module-cache -emit-library -static -emit-module \
  -emit-module-path "$module_dir/SearchCore.swiftmodule" \
  "$source_root"/Sources/SearchCore/*.swift -o "$module_dir/libSearchCore.a"
swiftc -whole-module-optimization -O -swift-version 6 -parse-as-library -module-name SearchBackend \
  -package-name FindUI -I "$module_dir" -L "$module_dir" -lSearchCore \
  -module-cache-path /tmp/findui-clang-module-cache -emit-library -static -emit-module \
  -emit-module-path "$module_dir/SearchBackend.swiftmodule" \
  "$source_root"/Sources/SearchBackend/*.swift -o "$module_dir/libSearchBackend.a"
swiftc -whole-module-optimization -package-name FindUI -I "$module_dir" -L "$module_dir" -lSearchBackend -lSearchCore "$@"
