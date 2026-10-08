#!/bin/zsh
set -euo pipefail
root="${0:A:h:h}"
audit_dir=$(mktemp -d /tmp/findui-launch-audit.XXXXXX)
trap 'rm -rf "$audit_dir"' EXIT
swiftc -O -swift-version 6 -parse-as-library -module-cache-path /tmp/findui-clang-module-cache \
  "$root/scripts/audit_app_launch.swift" -o "$audit_dir/audit"
"$audit_dir/audit" "${1:-$root/dist/FindUI.app}"
