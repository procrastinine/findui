# Build, test, and release

[FindUI](../README.md) · [Documentation](../README.md#documentation)

Maintainer instructions. App users can [install the packaged release](installation.md) without these tools.

## Build and package (maintainers)

Requires **macOS 14 or newer**, **Swift 6.3 or newer**, and **Rust/Cargo** plus **Go** to build the bundled FOSS tools. These are maintainer dependencies; the packaged app needs none of them.

Install the maintainer build tools with Homebrew:

```sh
brew install rust go
```

Run these commands from the repository root:

```sh
zsh scripts/build_app.sh
open dist/FindUI.app
```

The script builds a release executable, packages `dist/FindUI.app`, and applies a local ad-hoc signature. **No Apple Developer account or signing certificate is required.** It does not notarize, publish, install, or upload the app. Build once for distribution; recipients use the resulting app.

```sh
zsh scripts/verify.sh                 # Rust/Swift tests and packaged CLI checks
ruby scripts/audit_backend_boundary.rb # check dependencies and build the CLI independently
zsh scripts/package_release.sh       # build, isolated install check, ZIP, hashes and manifest
zsh scripts/verify.sh --bench --ui    # also run scaling measurements and native UI audits
zsh scripts/benchmark_primitives.sh  # reproduce hash/compression backend comparisons
zsh scripts/benchmark_presentation.sh # result storage, highlights and snapshot preparation
ruby scripts/benchmark_responsiveness.rb # CLI first result, completion, RSS and cancellation
ruby scripts/benchmark_word_freshness.rb # metadata versus filesystem-journal verification
zsh scripts/benchmark_gui.sh          # native input through first drawn result and completion
zsh scripts/audit_ai_search.sh        # isolated AI settings and proposal UI, with mock providers/keys
ruby scripts/audit_ai_codex.rb        # local-only Codex transport check; no user credentials or model call
```

`package_release.sh --skip-build` packages an already built app. Its installation check copies the app outside the checkout, checks system-only runtime linkage, signatures and licenses, then exercises live search, words, status, suggestions, facets, snapshots and the built-in benchmark. It uses disposable cache/preset/Tika directories. Build and benchmark scripts work with PATH or either Homebrew prefix. Release builds use the committed Cargo lockfile and portable runtime CPU feature detection; they do not assume the maintainer's CPU features.

The responsiveness probe separately samples the CLI and its complete process tree; summed RSS can count shared pages more than once and miss short peaks. The GUI probe includes normal input debounce, result publication and AppKit drawing, but not physical keyboard or display scan-out latency. Startup, planner, lifecycle, responsiveness and word-freshness probes accept `FINDUI_BENCHMARK_ROOT=/path/to/existing/folder` to create disposable fixtures on a chosen mounted volume. They do not flush operating-system caches. Reports stay in ignored `.cache/` directories; timings describe the measured build and fixture, not a general speed guarantee.

For development:

```sh
bash scripts/build_core.sh
swift build
swift run --skip-build FindUIApp
swift test --no-parallel
```

The app uses bundled fd, rg, fzf, and findui-content, then development tools or PATH fallbacks when building from source. Their versions and upstream checksums are pinned in `Tools/search-tools.json` and Cargo lockfiles. Optional document readers are located through PATH and common Homebrew directories. Check **Settings → Tools** for detected executables; the reload button beside **Document readers** refreshes them. Tika version selection takes effect without restarting. **Installed tool details** includes a copy button for optional reader installation commands.

The app contains separate GUI (`FindUIApp`) and terminal (`FindUI --cli …`) executables. Finder launches the GUI directly. Both link the same `SearchBackend` and `SearchCore` modules; the CLI does not load SwiftUI, AppKit, PDFKit or Quick Look. Live searches, snapshot searches and folder browsing share one preparation and execution path. Existing terminal commands retain their syntax. `FINDUI_DATA_DIRECTORY` selects an alternate library/index/preset directory for isolated profiles and launch checks.

## Development notes

The Swift package has no package dependencies; result paging uses system SQLite. The Rust worker has a committed Cargo.lock and uses FOSS regex/search, parallelism, serialization and XML libraries. Builds collect dependency license files into the app's Resources/Licenses directory. Search membership, extraction and indexing are all callable without a GUI; views configure them and display their output.

Additional validation commands:

```sh
bash scripts/build_core.sh
swift test --no-parallel
ruby scripts/audit_search_backends.rb
ruby scripts/audit_content_index.rb
ruby scripts/audit_cli_features.rb
ruby scripts/audit_backend_regressions.rb
ruby scripts/audit_command_roundtrips.rb
ruby scripts/audit_snapshot_reliability.rb dist/FindUI.app 50 4
zsh scripts/audit_folder_actions.sh
FINDUI_TIKA_JAR=/path/to/tika-app-3.3.2.jar ruby scripts/audit_search_backends.rb
ruby scripts/audit_index_watch.rb
ruby scripts/benchmark_content.rb
UGREP=/path/to/ugrep ruby scripts/benchmark_backends.rb
```

The backend audit creates disposable real PDF/Office/archive fixtures and checks extraction, provenance, cache reuse, bypass, clearing and failures. The watcher audit checks real create/rename/delete events, offline replay and headless snapshot queries under the workspace (macOS temporary folders do not reliably deliver these filesystem events).

The backend regression audit exercises the packaged app and copied commands, compares Boolean results to an independent oracle, and compares traversal with candidate admission across depth, hidden overrides, symlinks, package boundaries and overlapping roots. Swift regression tests compare incremental snapshots against fresh builds, including coalesced directory/child events, and check snapshot/Spotlight explanations and root aliases. Incremental updates share the bounded parallel metadata reader used by full builds and reuse compiled ignore rules across each admission batch.

`UIContractAuditTests` adds literal/control/Rules/export round trips, comparisons with installed `rg` and `find`, incomplete-expression handling, source-preserving presets, prepared-word mode transitions, explicit snapshot selection/export, and traversal-pattern admission and incremental updates. A counted-worker test verifies that filename refinements reuse one walk and changed traversal rules start another. Native rendering checks also exercise the grouped content-engine picker and the visible path-rule Clear action.

Run tests with `--no-parallel`: these fixtures launch many real processes and concurrent full-suite runs can exceed their timing deadlines. A dedicated test still runs two searches concurrently to verify independent results and shared history. Tests exercise large process output, continued streaming beyond 300 results, cancellation and early termination, live/index parity, metadata filters, wildcard quoting, extension groups, fuzzy ranking, ignore rules and index coverage, CLI-to-UI translation, content context, CSV escaping, file URL transfers, history compatibility, and editor URLs. Tests use disposable fixtures, including an isolated clipboard, and avoid loading saved user state. `zsh scripts/render_screenshot.sh` checks native focus, editing geometry, selection, grouping, tabs, and shortcuts. `zsh scripts/audit_window_commands.sh` runs the real SwiftUI menu commands for ⌘N, ⌘T, ⌘W, and Settings with a disposable library.

`zsh scripts/audit_quit.sh` launches disposable native app instances with the production shutdown delegate. It verifies actual process exit after ⌘Q, ⌘W, the red close button, closing with Settings open, closing multiple/minimized windows, repeated quit requests, and quitting with a native folder picker open. It also checks that pending settings are saved and search workers that ignore SIGTERM are killed and reaped before exit, including searches cancelled by a replacement query. A watchdog makes a stalled quit fail the audit instead of leaving a hidden test app running.

`zsh scripts/audit_settings.sh` clicks the actual Settings controls, checks drive selection and keyboard navigation, expands/collapses disclosure headers, verifies copying and version removal with disposable data, and captures small-window and dark-mode layouts. It makes no downloads and preserves the clipboard. `zsh scripts/audit_settings.sh "$PWD/.cache/settings-layout" --layout-only` checks preset actions, rule layouts and independent conversion checkboxes using accessibility actions without requiring foreground keyboard focus.

If macOS denies foreground activation, `zsh scripts/audit_settings.sh "$PWD/.cache/settings-input" --allow-inactive` runs native in-process input and accessibility checks and reports the desktop-focus limitation explicitly. `scripts/render_screenshot.sh` accepts the same flag. Where synthetic table events lack WindowServer tracking state, that mode can exercise AppKit's click handler directly and reports the limitation. It does not verify physical pointer or foreground window routing.

To regenerate the public light/dark comparison from real app views and disposable sample files:

```sh
zsh scripts/render_search_comparison.sh docs
```

This requires a logged-in macOS graphical session and the bundled search tools built by `scripts/build_app.sh`. It writes `docs/search-simple.png`, `docs/search-rules.png`, and `docs/search-comparison.png`. It captures only its own window, using synthetic files and isolated settings. The real command footer resolves tools in a temporary directory, so it does not expose the developer's checkout path.

The separate `zsh scripts/render_screenshot.sh` interaction audit writes its captures to ignored `.cache/verification/`. It checks minimum window size, stable intermediate layouts, Reload/status alignment, Copy button geometry, grouping, selection, focus, shortcuts, typing, and caret alignment. Add `--layout-only` for an off-screen audit without foreground focus checks.

If WindowServer capture is unavailable, `--bitmap-only` keeps all native interaction checks and samples the rendered search-field borders using AppKit bitmaps. Those images omit composited Liquid Glass effects. Set `FINDUI_AUDIT_OUTPUT` to choose a different local audit destination.

Use `--sidebar-preview-only` for the focused interaction audit: 150 disposable history entries, repeated sidebar toggles, retained native tables and scroll position, and Quick Look navigation, dismissal, control geometry, and unchanged-preview reuse.

## Preparing source and releases for sharing

Run the publication check before committing or creating a source archive:

```sh
ruby scripts/audit_publication.rb
ruby scripts/audit_publication.rb --app dist/FindUI.app --archive dist/FindUI-source.zip
ruby Tests/PublicationTests/audit_publication_test.rb
```

It checks the files Git would include, including already tracked files that now match ignore rules. Before `git init`, it evaluates the same rules using a temporary Git directory. It checks personal home paths, local account names, common credential formats, unexpected binaries, symlinks, and image text/metadata using local macOS Vision OCR. Findings show filenames and rule names without printing secrets. OCR and pattern matching assist review; inspect new screenshots before publishing them.

The source ZIP contains exactly the checked source files, with every extracted file verified against its audited SHA-256. Changes between the audit and packaging require another audit. A `.sha256` file accompanies the source ZIP. Experiments, backups, credentials, caches, virtual environments, native audit captures, and build output stay local under `.gitignore`. Keep `docs/` limited to current guides, architecture notes, dependency attribution, and synthetic screenshots. Ignore rules do not sanitize Git history or protect a manually uploaded copy of the entire working folder.

Release builds remove developer fallback paths and debug records, remap Rust source paths, and retain dependency licenses. `scripts/package_release.sh` checks both the source and app before packaging, then verifies the relocated app and archive. Each run refreshes both the app ZIP and `FindUI-source.zip` with their checksums. The ZIPs omit resource forks and Finder metadata.

The app icon's editable source is [packaging/FindUI.svg](../packaging/FindUI.svg). Normal builds use the checked-in ICNS. After editing the SVG, install `librsvg` and run `zsh scripts/build_icon.sh` to regenerate it.
