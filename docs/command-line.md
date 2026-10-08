# Command-line reference

[FindUI](../README.md) · [Documentation](../README.md#documentation)

The bundled CLI uses the same search backend as the app. For pasting shell commands into the interface, see [command import](command-import.md).

The packaged executable accepts `--cli` without starting windows. These examples run from the repository root after building; for an installed app, replace `dist/FindUI.app` with `/Applications/FindUI.app`.

```sh
dist/FindUI.app/Contents/MacOS/FindUI --cli --help
dist/FindUI.app/Contents/MacOS/FindUI --cli search @search-state.json
dist/FindUI.app/Contents/MacOS/FindUI --cli search @search-state.json --print-command
dist/FindUI.app/Contents/MacOS/FindUI --cli index build '{"scopePath":"/example/Documents","name":"Documents"}' /tmp/documents-index.sqlite
dist/FindUI.app/Contents/MacOS/FindUI --cli index watch '{"scopePath":"/example/Documents","name":"Documents"}' /tmp/documents-index.sqlite
dist/FindUI.app/Contents/MacOS/FindUI --cli search @search-state.json --snapshot /tmp/documents-index.sqlite
dist/FindUI.app/Contents/MacOS/FindUI --cli index export /tmp/documents-index.sqlite
dist/FindUI.app/Contents/MacOS/FindUI --cli index words @search-state.json
dist/FindUI.app/Contents/MacOS/FindUI --cli index status @search-state.json
dist/FindUI.app/Contents/MacOS/FindUI --cli suggest @search-state.json ne
dist/FindUI.app/Contents/MacOS/FindUI --cli readers
dist/FindUI.app/Contents/MacOS/FindUI --cli facets search @search-state.json
dist/FindUI.app/Contents/MacOS/FindUI --cli facets apply @facet.json @search-state.json
dist/FindUI.app/Contents/MacOS/FindUI --cli benchmark
dist/FindUI.app/Contents/MacOS/FindUI --cli explain @search-state.json /path/to/file
dist/FindUI.app/Contents/MacOS/FindUI --cli cache info
dist/FindUI.app/Contents/MacOS/FindUI --cli cache clear
dist/FindUI.app/Contents/MacOS/FindUI --cli tika list
dist/FindUI.app/Contents/MacOS/FindUI --cli tika check
dist/FindUI.app/Contents/MacOS/FindUI --cli tika install latest --select
dist/FindUI.app/Contents/MacOS/FindUI --cli tika select 3.3.2
dist/FindUI.app/Contents/MacOS/FindUI --cli tika select off
dist/FindUI.app/Contents/MacOS/FindUI --cli tika remove 3.3.2
```

Search JSON uses the existing saved `SearchState` format; `{"query":"report","mode":"files","scopePath":"/example/Documents"}` is a minimal example. Paths use NUL delimiters; content results are JSON lines; warnings/errors go to stderr. Copied GUI commands include all query/traversal/extraction settings and invoke these same headless backends. Existing saved searches/index arrays remain readable; exported shell programs are compiler-version-specific and can be regenerated from saved search state after upgrades.

A state with `useIndex: true` requires `--snapshot`; it cannot silently fall back to live files. `--print-command` also works with `--snapshot` and exports a command that uses that artifact.

Indexes record their ignore and folder-exclusion settings. If those options change, **Snapshot** searches request a refresh instead of silently searching an incompatible snapshot. Refresh uses the current Scope & Options settings. Older indexes continue to load; their original engine determines their default ignore behavior. Permissions and ignore rules affect coverage, including when building indexes.

See also [AI commands](ai-search.md), [document and archive commands](documents-and-archives.md#headless-usage), and [search semantics](search-guide.md).
