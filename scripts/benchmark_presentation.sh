#!/bin/zsh
# Compile before timing; use an isolated profile and disposable search fixtures.
set -euo pipefail
root="${0:A:h:h}"
cd "$root"
mkdir -p .cache
temporary=$(mktemp -d "$root/.cache/presentation-audit.XXXXXX")
trap 'rm -rf "$temporary"' EXIT
bash scripts/swiftc_with_search_core.sh -O -swift-version 6 -parse-as-library \
  -module-cache-path /tmp/findui-clang-module-cache scripts/benchmark_presentation.swift -o "$temporary/probe"
benchmark_app="${FINDUI_BENCHMARK_APP:-$root/dist/FindUI.app}"
for tool in fd rg fzf findui-content; do cp "$benchmark_app/Contents/MacOS/$tool" "$temporary/$tool"; done
FINDUI_DATA_DIRECTORY="$temporary/data" FINDUI_CACHE_DIRECTORY="$temporary/cache" \
  FINDUI_QUERY_CACHE_DIRECTORY="$temporary/queries" FINDUI_TIKA_JAR='' "$temporary/probe" "$temporary/fixtures"
cp "$temporary/fixtures/presentation.json" "${REPORT:-$root/.cache/presentation-audit.json}"
