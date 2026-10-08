# Search architecture

The default plan is the ordinary tool command. More machinery needs either a
semantic reason or a measured advantage for composition. A warm microbenchmark
cannot establish a universally fastest plan across disks, caches and workloads.

## Boundaries and invariants

| Responsibility | Owner | Invariant |
| --- | --- | --- |
| Controls | FindUI GUI target | Edits shared state; no frontend membership implementation |
| Saved state, presets, safe imports, normalization and execution services | `SearchBackend` target | One implementation used by both executables; no UI framework imports |
| Normalize persisted controls | `SearchBackend/SearchNormalization.swift` | One typed query, resolved date clock, scope and matching units |
| Query and physical plan | Foundation-only `SearchCore` target | No AppKit, SwiftUI, shell parsing or directory enumeration |
| Native capability checks | `SearchPlanner`, `NativeFileTypes`, `NativeFind`, `NativeBoolean` | Choose a command only when all requested semantics are preserved |
| Invocation and export | `ExecutionPlan`, `SearchPipeline` | GUI and CLI execute the same argv; shell rendering is not an execution intermediate |
| Compound execution | Rust `execution`, `input`, `query`, `paths`, `search` | One candidate traversal, shared metadata, one body scan per selected file |
| Record transport | Rust `records`/`output`, Swift `CommandRunner`/`SearchDiagnostics` | Versioned worker completion, raw backend match ranges, explicit errors and partial results |
| Presentation | `SearchService`, result store and views | Decode records, enrich display metadata once per file, page/sort without changing membership |

`FindUI --cli search @state.json --explain-plan` prints the normalized query,
stages, stream contracts, budget and selection reasons. `--print-command` emits
the executable command. A plain fd/rg command needs no FindUI wrapper. Compound
exports retain validated import metadata so the controls can be restored exactly.
Native command imports preserve semantics even when equivalent controls have a
different representation.

## Executables and shared backend

The package builds two executables. `FindUI` is the terminal entry and retains
the `--cli` interface. `FindUIApp` owns SwiftUI/AppKit and is the `.app` bundle's
Finder entry point. Both depend on `SearchBackend`, which depends on
`SearchCore`; neither backend imports UI frameworks. Models and APIs shared
between these targets use Swift package access rather than a public library API.
Presentation views, pasteboard operations and editor launching remain in the GUI
target. Bundled tools are located beside the actual process image, including
when the CLI is invoked through a symlink. CLI commands work without the GUI
executable present, and installation checks reject UI linkage in the CLI.

`ruby scripts/audit_backend_boundary.rb` enforces the target dependency graph
and an explicit allowlist of headless imports, then builds the CLI product in a
fresh build directory. It rejects compilation of the GUI target, UI framework
linkage and UI framework loading at startup. The standard verification script
runs this audit. CoreServices remains a backend dependency for filesystem
events and metadata; no windowing API is needed.

`ruby scripts/verify_app.rb dist/FindUI.app` removes the GUI executable from a
disposable app copy before running its search, index, preset, preview,
extraction and command-export checks. Installation probes also trace runtime
libraries, so dynamically loaded UI frameworks fail verification. Only the
temporary copy is modified; the distributable stays intact.

## Native plans and conservative fallbacks

Filename conjunctions use fd's native type, name, path, extension, size, depth,
ignore and thread controls. Filename literals accept composed/decomposed Unicode
forms using the same bounded regex in fd and the shared worker; explicit regexes
retain native regex semantics. fd's extension option ignores case independently
of `--case-sensitive`, so case-sensitive extension queries use its regex engine.
Absolute predicates under root aliases require the shared path selector when
fd's canonical output spelling would alter the predicate.

Ordinary text uses rg, including fixed strings, regex, whole words, encoding,
files-only results, exclusions and thread settings. Eligible basename predicates
and extension groups become custom rg types. Positive `--glob` flags are not used
as ordinary file filters because they can override ignore and hidden-file rules.
ASCII case folds with Unicode partners use explicit glob alternatives. Other
Unicode or intersecting filename conditions fall back to shared selection.

Same-line Boolean groups of ASCII literals can also use rg's PCRE2 engine when
only matching filenames are requested. Byte-mode lookaheads and explicit simple
case folds preserve the shared semantics, including invalid UTF-8 source text.
This requires the pinned PCRE2-capable rg, has a bounded generated pattern, and
does not reinterpret user regexes. Highlighted lines, whole-word groups, Unicode
patterns and whole-file groups retain the shared executor.

Complex file/content groups share one `ignore` walk and ripgrep matcher pool.
File-kind, scope and exclusion constraints apply outside the Boolean tree so NOT
cannot admit a rejected directory or scope. Unique predicates are compiled once;
AND/OR/NOT retain their matching unit: same line, extracted document, or whole
outer file. Positive filename conjunctions can run fd → fzf when root spelling
and ranking remain equivalent. General fuzzy groups spool candidates once, run
each distinct fzf filter once, and join membership/ranking in temporary SQLite.

Overlapping roots use the shared walker with exact deduplication. Small sets stay
in memory and large sets spill to disk. Metadata travels with a candidate instead
of being lost in a path pipe and fetched by every predicate. Word searches query
candidate IDs once, intersect current admission/file conditions and explicit
saved-result membership, then render only selected documents.

## Freshness, resource costs and failures

Live searches enumerate again for every query. There is no time-based candidate
cache. Frozen filename snapshots and saved result manifests are explicit source
choices. Live reads are not an atomic filesystem snapshot: concurrent edits may
change a file during the search. Snapshots hold immutable database generations;
word indexes report prepared coverage and staleness independently of hits.

Document readers and archive/attachment expansion remain separate opt-ins. ZIP
name listing reads the central directory without decompression. Plain text does
not implicitly prepare signatures or read document caches. Content signatures
are an explicit option; unsupported signature predicates conservatively scan.

Parallel compositions divide requested workers; the shared executor uses a
single traversal/scan pool. Conversions have a separate cap of four. Ordered
output has at most one spool per worker (1 MiB in memory, then disk). Unranked
output flushes its first record immediately. Dense producers use private 64 KiB
batches to avoid contending on stdout for every matching line; the shared 20 ms
timer also drains these buffers when a scanner is busy or matches become sparse.
Short outputs avoid allocating a producer buffer. Large set operations use bounded SQLite caches. These are
scratch-buffer controls, not a promise about total RSS: tool regex engines,
large lines, converters, OS caches and the GUI have their own memory costs.

The GUI starts tools directly with `posix_spawn` and a process group. Cancellation
terminates descendants, escalating to KILL for a stuck child. A worker reports
complete, partial, cancelled or failed through a versioned completion record;
missing/malformed completion is an error. Native no-match exit codes are handled
per stage. Diagnostics are drained with bounded retained text, preserving final
completion. GUI transport rejects invalid UTF-8 paths and records above 64 MiB
explicitly rather than inventing a different filename. The CLI can pass native
path bytes directly to the terminal. Match snippets can retain invalid source
bytes in the JSON base64 form with verified byte offsets.

The CLI replaces itself with a non-transforming search command. For native rg
JSON it uses a chunked envelope filter to retain matches without decoding and
re-encoding every snippet. Startup/planning still costs more than invoking the
copied tool command directly; this overhead must be reported separately.

## Verification and measured selection

The tests compare complete native and worker records, including path aliases,
case, Unicode, size boundaries, ignores, mixed file/content predicates, matching
units and ranking. Boolean tests use independent truth-table/fixture oracles;
snapshot posting candidates are compared with scanning the entire frozen source.
GUI/CLI parity alone is insufficient when both use the same mistaken predicate.

`ruby scripts/benchmark_planner.rb` creates isolated fixtures, checks every path,
line, snippet and highlight, warms each case, rotates execution order and reports
full-process medians. It compares simple exports with direct fd/rg and compound
exports with fd→rg or equivalent native predicates. Run it without builds/tests
in parallel. GUI materialization, cold caches and network disks are outside that
benchmark. Measurements and the policy changes they justify are recorded beside
the report, rather than replacing native defaults with unmeasured heuristics.

`zsh scripts/verify.sh` builds pinned tools, runs Rust/Swift tests, verifies the
relocated `.app`, and exercises packaged CLI regressions. `--ui` adds native
window/layout interactions; `--bench` adds the repeatable benchmark suite. The app
contains fd, rg, fzf, the shared executor, their licenses and input provenance.
Recipients install the `.app`; they do not compile these tools.
