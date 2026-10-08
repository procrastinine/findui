#!/bin/zsh
# Reproduce the backend choice, separately from the installed-app benchmark.
set -euo pipefail
root="${0:A:h:h}"
cd "$root"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export CARGO_HOME="${CARGO_HOME:-$root/.cache/cargo}"
export CARGO_TARGET_DIR="$root/.build/primitive-benchmarks"
output="${1:-$root/.cache/primitive-benchmark}"
mkdir -p "$output"
output="${output:A}"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/findui-primitives.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
# Finish every compilation before collecting any samples.
for backend in software accelerated; do
  cargo build --release --locked --manifest-path Tools/benchmarks/hash/Cargo.toml --features "$backend"
  cp "$CARGO_TARGET_DIR/release/findui-hash-benchmark" "$fixture/hash-$backend"
done
for backend in miniz zlib-rs; do
  cargo build --release --locked --manifest-path Tools/benchmarks/codec/Cargo.toml --features "$backend"
  cp "$CARGO_TARGET_DIR/release/findui-codec-benchmark" "$fixture/codec-$backend"
done
"$fixture/hash-software" > "$output/hash-software.jsonl"
"$fixture/hash-accelerated" > "$output/hash-accelerated.jsonl"
env -u FINDUI_BUFFER_JSON "$fixture/codec-miniz" "$fixture/unbuffered.gz" > "$output/codec-miniz.jsonl"
FINDUI_BUFFER_JSON=1 "$fixture/codec-miniz" "$fixture/miniz.gz" "$fixture/unbuffered.gz" > "$output/codec-miniz-buffered.jsonl"
FINDUI_BUFFER_JSON=1 "$fixture/codec-zlib-rs" "$fixture/zlib.gz" "$fixture/miniz.gz" > "$output/codec-zlib-buffered.jsonl"
ruby -rjson -e 'a,b=ARGV.map { |p| File.readlines(p).map { |l| JSON.parse(l).fetch("digest") } }; abort "SHA digests differ" unless a==b; puts "PASS: software/accelerated digests and cross-backend gzip round-trips"' "$output/hash-software.jsonl" "$output/hash-accelerated.jsonl"
echo "Primitive comparisons: $output"
