#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
root="${1:-$PWD/.cache/snapshot-benchmark}"
mkdir -p "$root"
sources=(Sources/FindUI/*.swift)
sources=("${sources[@]:#*/FindUIApp.swift}")
bash "$PWD/scripts/swiftc_with_search_core.sh" -O -swift-version 6 -parse-as-library -module-cache-path /tmp/findui-clang-module-cache \
  "${sources[@]}" scripts/benchmark_snapshots.swift -o "$root/benchmark"
"$root/benchmark" "$root"
