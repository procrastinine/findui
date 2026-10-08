# Documents and archives

[FindUI](../README.md) · [Documentation](../README.md#documentation)

Search converted text locally, with archive expansion and other costly readers enabled explicitly. For setup, see [optional document readers](installation.md#optional-document-readers).

## Enable document and archive search

**Search inside documents** and **Expand archives and attachments** are separate checkboxes in **Scope & Options**, both off by default. Ordinary searches read names, metadata and plain text without starting converters or decompressing archives. Turning on document readers never enables archive expansion. Search and content-index preparation both skip archive payloads unless expansion is explicitly enabled; even previously cached member contents stay excluded. History from the former combined default is migrated with both conversions off; newly saved explicit choices persist. Type into Contents as usual; the selected Tika version is used automatically when available. New saved searches and presets preserve those explicit choices. Imported `rg` commands keep plain-text semantics. Converter downloads, availability, and cache maintenance live in **Settings → Tools**; per-search limits and cache overrides live under **Scope & Options → Advanced**. Folder browsing has an **Include subfolders** checkbox and **Add Folder…** chooser; custom depth and worker counts are advanced options.

Documents also includes MIME email, mbox mailboxes and read-only SQLite tables, with message/table/row provenance. Attachments in email and PDFs require **Expand archives and attachments**; PDF attachment extraction uses Poppler. The SQLite reader skips BLOBs, views and virtual tables, uses a read transaction, and never executes stored views or writes source data. Bounded header detection recognizes supported extensionless or mislabeled documents.

This uses local FOSS converters independently of Spotlight: Poppler for PDF, Pandoc for DOCX/ODT/e-books/HTML, optional Tika for additional Office formats, and macOS's libarchive for containers. Pandoc and Poppler run directly; the previous `rga` wrapper and its second cache are no longer needed. Missing readers preserve ordinary text matches: the GUI retains partial results with diagnostics, and the CLI returns those results with a nonzero status.

## Results and previews

Results have structured archive-member identities and PDF page, spreadsheet sheet, or slide locations. Names and location labels are separate from searchable body text. **Same document / member** keeps Boolean conditions within one member; **Whole file / container** intentionally permits conditions across members and returns outer files. The inspector reads cached context, navigates PDF pages, and opens an extracted copy of the exact member, including duplicate names. Changed archive identities are rejected. Copies are private temporary files, removed when FindUI quits; editing a copy does not update the archive.

## Supported containers and limits

ZIP/JAR, TAR and compressed streams, 7z, XAR/PKG, and Python wheels use libarchive without another tool installation. Extensionless compressed installer payloads are recognized from bytes already read. RAR, CAB, ISO, RPM and DEB decoding depends on the system library's format/codec support. Unsupported, encrypted, corrupt, timed-out and over-limit files produce diagnostics. There is no OCR or DMG mounting; scanned PDFs need a text layer. Limits bound expanded bytes, extracted text per outer file, conversion time, and nested archive layers.

## Caching and repeated searches

**Reuse cached document text** stores compressed text, metadata and locations under `~/Library/Caches/FindUI/ExtractedText/` in a private directory. Device/inode, size, modification/change timestamps, converter identity and settings control reuse. Concurrent searches share completed conversions. Successful archive members remain cached when another member fails. Unchanged deterministic reader failures are remembered for 15 minutes, with their diagnostics, so each keystroke does not launch the same failing converter. Changed sources/settings/tools invalidate that failure; cancellation and transient errors are retried. **Settings → Tools → Search cache → Retry Failed Readers**, or `FindUI --cli cache retry`, clears failures while retaining successful text. Member-name conditions prune irrelevant payloads before conversion, and outer members convert in bounded parallel batches. **Calculate Size / Clear Cache** includes text and content signatures, with CLI equivalents. Disabling text caching uses disposable conversion files. Clearing is rejected while a search holds a lease. Conversion scratch files are removed on completion or cancellation.

## Media metadata and subtitles

**Media metadata and subtitles**, also off by default, uses optional FOSS FFmpeg tools (`brew install ffmpeg`) for media headers and existing text subtitle tracks. Results retain track/timecode locations. It does not transcribe audio or recognize images. Reader limits and conversion concurrency also apply to media.

## Custom readers

**Settings → Tools → Custom readers** configures installed programs for additional extensions. Choose an executable and enter literal arguments, one per line, using `{path}` for the source file. The program must return UTF-8 text; there is no shell interpolation. Enable **Use custom readers** for searches that should run them. Reader definitions are shared with `FindUI --cli readers list/import/export/enable/disable/remove` in `~/Library/Application Support/FindUI/readers.json`; `FINDUI_READER_CONFIG` overrides that path. Import/export preserves definitions, and executable/argument changes invalidate cached conversions. Output size, time, parallelism and cancellation use the same controls as built-in readers.

## Document conditions and archive names

**Rules → Add** includes **Near words**, **Document title**, **Author**, and **Archive member name**. Near words accepts 2–16 words, an allowance of intervening words across the whole span, and optional ordering. It crosses lines but never archive-member boundaries. Title/author availability depends on the document's stored metadata and reader. With expansion off, a query consisting only of member-name conditions reads the ZIP/JAR/wheel central directory with rawzip. This includes file and directory names without reading/decompressing member bodies, following symlinks or entering nested archives. Metadata results are labeled “not expanded” and opening one reveals the archive in Finder. Other formats report that expansion is required; nothing silently opts in. Enable expansion explicitly for nested names and member contents.

## Headless usage

```sh
FindUI --cli index contents @saved-search.json
FindUI --cli search @saved-search.json --stats
FindUI --cli search @saved-search.json --within results.nul
FindUI --cli presets save filter "Review documents" @saved-search.json
FindUI --cli presets apply "Review documents" @another-search.json
FindUI --cli presets export > presets.json
FindUI --cli text preview @text-location.json
FindUI --cli document preview @location.json
FindUI --cli document materialize @location.json
```

`presets apply` emits a SearchState for `search`. Document requests contain `path`, the match JSON's `findui_origin` as `origin`, and optional extraction/context/encoding settings. Text preview accepts `{path, line, context?, encoding?}` and uses the search decoder, including Unicode BOM detection. Materialization prints a temporary path owned by the caller. All operations run without constructing a GUI. See `FindUI --cli --help` for import and cache commands.

For isolated CLI projects or audits, `FINDUI_PRESETS_DIRECTORY` selects a separate preset library and `FINDUI_CACHE_DIRECTORY` selects a separate managed content cache. Both accept absolute directory paths.

`--stats` writes `findui-stats:` JSON to standard error without mixing statistics
into results. Native ripgrep plans include its summary under `engine: "ripgrep"`
and `data`; shared-worker plans report file reads, cache reuse and converter work.
