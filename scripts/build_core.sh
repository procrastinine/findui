#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CARGO_HOME="${CARGO_HOME:-$PWD/.cache/cargo}"
export CARGO_TARGET_DIR="$PWD/.build/content-worker"
export PCRE2_SYS_STATIC=1
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
source scripts/release_rust_env.sh
cargo build --manifest-path Tools/findui-content/Cargo.toml --release --locked
cargo metadata --manifest-path Tools/findui-content/Cargo.toml --format-version 1 --locked > "$CARGO_TARGET_DIR/metadata.json"
license_staging="$(mktemp -d "$CARGO_TARGET_DIR/.licenses.XXXXXX")"
trap 'rm -rf "$license_staging"' EXIT
ruby scripts/collect_core_licenses.rb "$CARGO_TARGET_DIR/metadata.json" "$license_staging"
rm -rf "$CARGO_TARGET_DIR/licenses"
mv "$license_staging" "$CARGO_TARGET_DIR/licenses"
