# Installation and local data

[FindUI](../README.md) · [Documentation](../README.md#documentation)

Install the packaged app, add optional readers, and manage access to your files.

## Install the app

Download the app ZIP from [GitHub Releases](https://github.com/procrastinine/findui/releases/latest), unzip it, and move **FindUI.app** to Applications. Open it normally. **No Swift, Rust, compiler, Homebrew, or separate search-worker installation is needed for core search, filename snapshots, or prepared word search.** The current packaged build supports Apple Silicon (`arm64`) on macOS 14 or newer. An Intel build needs separate packaging and verification; this ZIP is not universal.

The current build is ad-hoc signed, not Developer ID signed or notarized. macOS may block a downloaded copy on first launch. After checking that you trust its source, use the per-app **System Settings → Privacy & Security → Open Anyway** action described by [Apple](https://support.apple.com/en-us/102445). Normal downloaded-app launch without this exception still requires a signed and notarized release.

Each release ZIP has a `.sha256` checksum and a JSON manifest with its architecture and executable hashes. The app includes dependency licenses and `Contents/Resources/BuildInfo.json`, recording source/dependency fingerprints and compiler versions. Recipients can check the installed core without building anything:

```sh
/Applications/FindUI.app/Contents/MacOS/FindUI --cli benchmark
```

This runs bounded synthetic SHA-256 and production cache round-trip measurements in temporary storage, then removes the fixtures. It does not read personal files or alter search settings. Run it with the computer idle; component timings are not whole-search speed guarantees.

## Optional document readers

```sh
brew install poppler pandoc
```

For XLS/XLSX, PPT/PPTX, DOC, ODS/ODP and RTF, open **Settings → Tools → Download Tika**. FindUI downloads and selects the recommended compatible version. **Use version** switches among installed versions or turns Tika off; **Manage versions** downloads older releases, reveals installation files, and removes versions you no longer need. **Check for Updates** refreshes the available releases. Downloads show progress, can be cancelled, and verify Apache's SHA-512 checksum before publishing an installation. Changing versions needs no restart, and already installed versions are reused without downloading them again.

The adapter uses Apache's [supported Tika 3.x line](https://tika.apache.org/download.html), which requires Java 11 or newer. Settings checks for Java and links to the FOSS Temurin distribution if it is missing. Tika runs with an explicit Office-only parser list. No OCR, Tesseract, remote parser, or model is configured. Downloads and update checks only happen when requested; opening Settings never contacts Apache. Installed versions, checksums, source URLs, and the selected version are stored in `~/Library/Application Support/FindUI/Tools/Tika/` and shared with the CLI. Versions being used by a search cannot be removed until that search finishes or is cancelled.

Advanced headless overrides remain available: `FINDUI_TIKA_JAR=/absolute/path/tika-app-3.3.2.jar` takes precedence over managed selection; `FINDUI_TIKA_DIRECTORY=/absolute/folder` chooses a separate version store. Existing manually selected jars remain a fallback until you make a managed selection.

## Full Disk Access

Open **FindUI → Settings → General → Full Disk Access**. **Open Full Disk Access…** opens the macOS permission pane; enable FindUI there. If it is missing, use **Show FindUI in Finder**, then click **+** in System Settings and select that copy of `FindUI.app`. Quit and reopen FindUI after enabling access, then reload the search or rebuild any partial index.

No paid Apple Developer account is needed. [macOS requires you to grant this permission yourself](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox); an app cannot grant it programmatically. Launch the packaged app through Finder or `open dist/FindUI.app` so permission belongs to FindUI. The development build is ad-hoc signed: replacing it after a rebuild can require removing and re-adding it in Full Disk Access. File ownership, Unix permissions, and other system protections still apply.

Permission failures keep partial results and expose **File Access…** in the search footer. FindUI uses actual search errors; it does not read unrelated protected files to guess whether the permission is enabled.

## Local data and limitations

Settings, history, presets and SQLite filename snapshots (plus legacy JSON snapshots) are stored in:

```text
~/Library/Application Support/FindUI/
```

Closing the last search window quits FindUI and stops its searches and in-app index watchers. FindUI has no account, telemetry, cloud search, automatic updater, or automatically installed background service. Search runs through local tools. An explicitly selected mounted network directory is still accessed through that mount.

Literal, Expression, and Regex content searches read plain text/source code and, when enabled, extracted document/archive text. **Spotlight text** remains the separate indexed-content mode. No OCR or semantic search is included. Protected macOS directories may require Full Disk Access; search errors preserve partial results and do not become successful empty searches.
