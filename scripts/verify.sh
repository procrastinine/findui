#!/bin/zsh
# Build/test the checked-out sources and then verify the actual distributable.
set -euo pipefail
root="${0:A:h:h}"
cd "$root"
for option in "$@"; do
  case "$option" in --bench|--ui) ;; *) echo 'Usage: zsh scripts/verify.sh [--bench] [--ui]' >&2; exit 2 ;; esac
done
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export CARGO_HOME="${CARGO_HOME:-$root/.cache/cargo}"
export CARGO_TARGET_DIR="$root/.build/content-worker"
export PCRE2_SYS_STATIC=1
bash scripts/build_core.sh
bash scripts/build_search_tools.sh
cargo test --manifest-path Tools/findui-content/Cargo.toml --locked
ruby scripts/audit_backend_boundary.rb
ruby Tests/PublicationTests/audit_publication_test.rb
swift test --scratch-path .build/out --disable-sandbox --no-parallel
zsh scripts/build_app.sh
ruby scripts/verify_app.rb "$root/dist/FindUI.app"
export FINDUI_BINARY="$root/dist/FindUI.app/Contents/MacOS/FindUI"
export FINDUI_CONTENT="$root/dist/FindUI.app/Contents/MacOS/findui-content"
if [[ " $* " == *" --bench "* ]]; then
  ruby scripts/benchmark_planner.rb
  ruby scripts/benchmark_startup.rb
  zsh scripts/benchmark_optimizations.sh
  ruby scripts/benchmark_search_lifecycle.rb
  ruby scripts/process_tree_sampler.rb
  ruby scripts/benchmark_responsiveness.rb
  ruby scripts/benchmark_word_freshness.rb
  zsh scripts/benchmark_presentation.sh
fi
if [[ " $* " == *" --ui "* ]]; then
  zsh scripts/audit_app_launch.sh
  FINDUI_AUDIT_OUTPUT="$root/.cache/verification/main.png" zsh scripts/render_screenshot.sh --allow-inactive
  zsh scripts/audit_settings.sh "$root/.cache/verification/settings" --allow-inactive
  zsh scripts/audit_foss_features.sh "$root/.cache/verification/features"
  zsh scripts/audit_window_commands.sh
  if [[ " $* " == *" --bench "* ]]; then zsh scripts/benchmark_gui.sh "$root/.cache/verification/responsiveness"; fi
fi
