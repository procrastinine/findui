#!/bin/bash
# Build pinned upstream CLIs for app recipients without Homebrew or a compiler.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export CARGO_HOME="${CARGO_HOME:-$PWD/.cache/cargo}"
export CARGO_TARGET_DIR="$PWD/.build/search-tools-target"
export PCRE2_SYS_STATIC=1
export MACOSX_DEPLOYMENT_TARGET=14.0
# Stripping proc-macro dylibs removes Rust metadata on current macOS toolchains.
# Strip only the finished executables, after the locked upstream build.
export CARGO_PROFILE_RELEASE_STRIP=none
source scripts/release_rust_env.sh
install_root="$PWD/.build/search-tools"
mkdir -p "$install_root"
# cargo install otherwise reuses a matching installed version without checking
# new compiler flags. Rebuild once when the release recipe changes.
recipe=$( { cat scripts/build_search_tools.sh scripts/release_rust_env.sh Tools/search-tools.json; printf '%s' "$CARGO_ENCODED_RUSTFLAGS"; rustc --version; } | shasum -a 256 | cut -d ' ' -f 1)
reinstall=()
if [[ ! -f "$install_root/release-recipe.sha256" ]] || [[ "$(cat "$install_root/release-recipe.sha256")" != "$recipe" ]]; then
  reinstall=(--force)
fi
for crate in ripgrep fd-find; do
  version=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0])).fetch(ARGV[1])' Tools/search-tools.json "$crate")
  extra=()
  if [[ "$crate" == ripgrep ]]; then extra=(--features pcre2); fi
  cargo install "$crate" --version "=$version" --locked --root "$install_root" "${reinstall[@]}" "${extra[@]}"
done
strip -x "$install_root/bin/rg" "$install_root/bin/fd"
printf '%s\n' "$recipe" > "$install_root/release-recipe.sha256"

# Go's public checksum database authenticates the module graph. Also pin the
# top-level module checksum so updating a tag cannot silently change the input.
export GOCACHE="$PWD/.cache/go-build"
export GOMODCACHE="$PWD/.cache/go-mod"
export GOBIN="$install_root/bin"
export CGO_ENABLED=0
fzf_version=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0])).fetch("fzf").fetch("version")' Tools/search-tools.json)
go mod download -json "github.com/junegunn/fzf@v$fzf_version" > "$install_root/fzf-module.json"
ruby -rjson -e 'lock,got=ARGV.map { |p|JSON.parse(File.read(p)) }; abort "fzf checksum mismatch" unless lock.fetch("fzf").fetch("sum")==got.fetch("Sum")' Tools/search-tools.json "$install_root/fzf-module.json"
fzf_dir=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0])).fetch("Dir")' "$install_root/fzf-module.json")
go install -trimpath -ldflags "-s -w -X main.version=$fzf_version -X main.revision=findui" "github.com/junegunn/fzf@v$fzf_version"
(cd "$fzf_dir" && go list -mod=readonly -m -json all > "$install_root/go-modules.json")

license_staging=$(mktemp -d "$install_root/.licenses.XXXXXX")
trap 'rm -rf "$license_staging"' EXIT
for crate in ripgrep fd-find; do
  version=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0])).fetch(ARGV[1])' Tools/search-tools.json "$crate")
  crate_root=$(ruby -e 'puts Dir.glob(File.join(ARGV[0],"registry/src/*",ARGV[1])).first || abort("Missing downloaded crate")' "$CARGO_HOME" "$crate-$version")
  cargo metadata --manifest-path "$crate_root/Cargo.toml" --format-version 1 --locked > "$install_root/$crate-metadata.json"
  ruby scripts/collect_core_licenses.rb "$install_root/$crate-metadata.json" "$license_staging/$crate"
done
ruby scripts/collect_search_tool_licenses.rb "$install_root" "$license_staging"
rm -rf "$install_root/licenses"
mv "$license_staging" "$install_root/licenses"
