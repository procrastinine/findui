#!/bin/zsh
set -euo pipefail
root="${0:A:h:h}"
cd "$root"
mkdir -p .cache
audit_dir=$(mktemp -d "$root/.cache/startup-profile.XXXXXX")
trap 'rm -rf "$audit_dir"' EXIT
bash scripts/swiftc_with_search_core.sh -O -swift-version 6 -parse-as-library \
  -D FINDUI_DISABLE_FOUNDATION_MODELS -module-cache-path /tmp/findui-clang-module-cache \
  scripts/benchmark_startup.swift -o "$audit_dir/profile"
FINDUI_STARTUP_PROFILE="$audit_dir/profile" ruby scripts/benchmark_startup.rb
