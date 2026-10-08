# Backend selection

[FindUI](../README.md) · [Documentation](../README.md#documentation)

FindUI chooses a backend by search semantics and the work it can share. Simple searches retain native commands; compound searches use shared matching and traversal libraries. See [search architecture](search-architecture.md) for module boundaries and [performance](search-performance.md) for execution details.

| Job | Backend | Reason |
| --- | --- | --- |
| Simple live filename search | Bundled fd | Native filters, parallel traversal, and NUL-delimited paths. Conditions fd cannot preserve use the shared executor. BSD find is eligible only when ignore rules are disabled. |
| Simple text and eligible filename + text search | Bundled ripgrep | One direct traversal, including type filters that preserve ignore rules. |
| Compound text and mixed file/content rules | `findui-content`, using `ignore`, `grep-regex`, and `grep-searcher` | One shared walk and file read, deduplicated conditions, bounded parallelism, and ripgrep matching semantics. |
| Fuzzy filename ranking | fzf | Subsequence matching and relevance ordering, including rank preservation during content scanning. |
| ZIP member names | rawzip | Bounded central-directory reads without decompressing member bodies. |
| PDF and document text | Optional Poppler and Pandoc | One conversion shared by all conditions, location records, and a persistent validated text cache. |
| Archives and packages | System libarchive | Streaming reads, bounded nesting, numeric member identities, and temporary extraction. |
| Additional Office formats | Optional Apache Tika | Explicit Office parsers with no OCR; cached conversion avoids repeated JVM startup. |
| Filename snapshots | FSEvents and SQLite trigrams | Incremental updates, replay after downtime, verified candidates, and a conservative scan fallback. |
| Repeated content searches | Optional four-gram signatures | Skip impossible candidates while the ordinary matcher verifies every remaining file. |
| Prepared word search | Optional SQLite FTS5 | Incremental preparation, Boolean words, English Porter stemming, and BM25 ranking. |
| Email and databases | mailparse and read-only SQLite | Message/row provenance, charset decoding, bounded reads, and no stored view execution. |
| Typo-tolerant text | RapidFuzz | Bounded Levenshtein matching for literal words and phrases. |

Search-tool versions are pinned in [Tools/search-tools.json](../Tools/search-tools.json) and the Cargo lockfiles. The curated language-extension source is recorded in [Tools/language-type-source.json](../Tools/language-type-source.json), with its [Linguist license](licenses/linguist-LICENSE.txt). Packaged apps include dependency licenses under `Contents/Resources/Licenses`.

## Measure the current build

Build the app before running these disposable-fixture checks:

```sh
ruby scripts/benchmark_planner.rb
UGREP=/absolute/path/to/ugrep ruby scripts/benchmark_backends.rb
ruby scripts/benchmark_content.rb
zsh scripts/benchmark_snapshots.sh
zsh scripts/benchmark_optimizations.sh
ruby scripts/audit_search_backends.rb
ruby scripts/audit_content_index.rb
ruby scripts/audit_index_watch.rb
```

The planner benchmark compares full exported commands and the packaged CLI with native and composed tools. The backend benchmark checks complete result sets, rotates execution order, and includes streaming inputs to expose argument-list overhead. Omit `UGREP` to measure the default tools alone. Reader checks need the optional converters for the formats under test.

Keep first-use, conversion, index-preparation, and warm-search costs separate. Synthetic warm-cache measurements do not predict cold disks, network volumes, arbitrary regexes, or document conversion throughput. See [development](development.md) for native UI latency, process memory, cancellation, and publication checks.

## Alternatives

[ugrep](https://github.com/Genivia/ugrep) offers Boolean queries, archives, converter filters, and optional content indexes. Its grammar and regex semantics differ from ripgrep's, so swapping it into an existing query needs compatibility checks.

Established GUI alternatives include [Cardinal](https://github.com/cardisoft/cardinal), [EverythingMac](https://github.com/alesloa/everything-mac), [KatSearch](https://github.com/sveinbjornt/KatSearch), and [File Explorer](https://github.com/situmorang-com/file-explorer). FindUI's focus is the round trip between editable search controls, inspectable commands, and native results. Compare the actual searches and workflow you need; this is not a claim of a universal speed advantage.
