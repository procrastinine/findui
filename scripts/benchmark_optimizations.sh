#!/bin/zsh
# Maintainer suite. App recipients can run FindUI --cli benchmark directly.
set -euo pipefail
root="${0:A:h:h}"
cd "$root"
output="${1:-$root/.cache/optimization-benchmark}"
mkdir -p "$output"
output="${output:A}"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/findui-optimization-benchmark.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
export FINDUI_QUERY_CACHE_DIRECTORY="$fixture/query-cache"
export FINDUI_CONTENT="${FINDUI_CONTENT:-$root/dist/FindUI.app/Contents/MacOS/findui-content}"
binary="${FINDUI_BINARY:-$root/dist/FindUI.app/Contents/MacOS/FindUI}"
sources=(Sources/FindUI/*.swift)
sources=("${sources[@]:#*/FindUIApp.swift}")
bash "$root/scripts/swiftc_with_search_core.sh" -O -swift-version 6 -parse-as-library -module-cache-path /tmp/findui-clang-module-cache \
  "${sources[@]}" scripts/benchmark_optimizations.swift -o "$fixture/benchmark"
"$binary" --cli benchmark > "$output/primitives.json"
ruby scripts/benchmark_word_updates.rb > "$output/words.json"
"$fixture/benchmark" "$fixture" "$output/scaling.json" > "$output/scaling.log"
echo "Benchmark results: $output"
