# Search guide

[FindUI](../README.md) · [Documentation](../README.md#documentation)

[Basics](#searching) · [Scope](#scope-and-options) · [Presets](#presets-and-searching-within-results) · [Results](#file-actions-and-content-matches) · [Indexes](#optional-indexes) · [Documents and archives](documents-and-archives.md)

## Searching

**Filename** and **Contents** describe one search. Leave Contents blank to search filenames; leave Filename blank to search file contents; fill both to search inside matching files. **Find** chooses Files, Directories, or both for name searches. The bundled worker uses ripgrep's libraries for live text searches.

For example, enter `*.swift` in Filename with the default **Quick** matching, and enter `timeout` in Contents. This finds text only in matching Swift files. Additional file or metadata filters narrow the candidates before reading their contents.

| Filename matching | Meaning |
| --- | --- |
| Quick (default) | Contains for bare text; whole-name wildcard matching when the input includes `*` or `?` |
| Contains | Literal text anywhere in the basename |
| Exact | The complete basename, including its extension |
| Wildcard | `*` matches any number of characters; `?` matches one |
| Regex | A PCRE2 regular expression against the basename |
| Fuzzy | `fzf` subsequence matching: `srchvm` can find `SearchViewModel.swift` |

Filename and Contents have separate **Match case** controls. Contents defaults to **Expression**: `retry timeout` requires both terms on the same line; `"retry timeout"` is a phrase; `-draft` excludes lines containing draft. **Literal** treats the entire input as one phrase, including punctuation. **Regex** uses ripgrep syntax; **Spotlight text** uses macOS's existing document index. Live document extraction is a checkbox under **Scope & Options** and supports ordinary literal, expression, and regex matching. The **File types** and **Patterns** menus provide extension groups and common regexes.

**Rules…** expands the same search into one tree of **All (AND)**, **Any (OR)**, and **None (NOT)** groups. Each row has a condition type; filenames, contents, size, dates and tags can share any branch. Each group has its own **Add** menu. Right-click a condition to wrap it in a group, negate it or move it. For example, `((Swift AND TODO) OR (Markdown AND FIXME)) AND modified this week` keeps each text condition attached to its file type. Text conditions can match on the same line, in the same document/member, or anywhere in the outer file/container. Mixed expressions return matching files once. Removing the last condition clears the tree; an unfinished nested group stays visibly incomplete until filled or removed. **Simple controls** is enabled when every condition fits without changing its meaning.

**Scope & Options** contains shared folders, search source, depth, hidden/ignored files, and folder exclusions. In simple mode it also contains path, size, and date filters; in Rules those conditions are rows in the same tree. Path wildcards use `**` to cross directory separators. Invalid regular expressions and filter values report errors. Fuzzy uses the installed `fzf` tool and can narrow filenames before searching their contents.

Incomplete expressions, including an unclosed quote or `name:`, `path:`, or `ext:` without a value, retain the previous results and show an error. Select Literal or quote the entire term to search that punctuation as text.

**Advanced → Path patterns** applies ordered, case-sensitive traversal rules: `*.swift` includes matching paths and `!build` excludes them. Later rules win; explicit inclusions can admit ignored files, while hidden entries still require **Include hidden**. Patterns containing `/` are relative to the primary search folder. Excluded directories are pruned before their contents are searched. Active rules appear below the folder with **Edit…** and **Clear**, and are preserved in scope presets and snapshots. Live searches enumerate the current scope; snapshots and saved result scopes reuse explicitly frozen membership.

Choose a folder, enter its path, or drag a folder onto **In folder**. A typed path applies on Return, leaving the field, or pressing Search. With all search filters empty, FindUI browses that folder; active filters search recursively. Searches update as you type. The round magnifying-glass button searches immediately and becomes a stop button while searching. **⌘F** focuses Filename or the enabled Contents field; **Return** or **⌘Return** runs the search.

**Import Command…**, beside the command display in the footer, imports supported `fd`, `rg`, `find`, and NUL-delimited `fzf` / `xargs rg` pipelines. Paste a command and select **Apply & Search**. For example:

```sh
fd --type f --glob '*.swift' --print0 . | xargs -0 rg --fixed-strings timeout
```

Import fills the corresponding controls and saves the original command in history. Nested `find` groups preserve AND/OR/NOT precedence; repeated `rg -e` patterns and `rg -v` become content groups. Input is parsed into allowed options, then FindUI compiles its own pipeline. FindUI’s own exported pipelines can also be imported: their embedded search state must reproduce the exact pasted script before the controls change.

Copied snapshot searches reopen in command mode with their explicit index path and reference date. They retain frozen membership even if the live files change. Generated filename type filters restore compact controls and the native `rg` path when their meaning fits those controls; other filters retain their exact rule tree.

When a read-only `fd`, `rg`, or `find` option cannot be represented by editable controls, select **Run as a command instead of editing controls**. FindUI displays the original command and working folder and streams results into the same table. It uses the installed tool with literal arguments, adapts output to JSON/NUL records, and rejects shell actions, external programs, mutations and unsupported flags. **Use Search Controls** leaves this mode; **Search Within These Results** captures its files before adding ordinary filters. The backend also exposes `FindUI --cli import-command COMMAND --directory /folder [--native]`, which prints validated SearchState JSON without searching. See [command import details](command-import.md).

Representable `rg --glob` options appear as **Path rules**, preserving traversal pruning, case sensitivity, inclusion overrides, and rule ordering. Raw positive globs/type filters can admit hidden files while skipping hidden directories; import explains that distinction and offers command mode unless `--hidden` or a final `--glob '!.*'` makes the hidden setting explicit. In an `xargs rg` stage, explicit file arguments bypass ripgrep's traversal globs, so those globs do not become extra filters. Imported `find -path` patterns use an equivalent path regex because find's wildcards cross directory separators. Relative-root spellings that cannot be represented faithfully are rejected with an explanation.

Previously saved filename expressions, including `name:budget path:2025 ext:xlsx`, remain visible and editable as **Name / path**. They keep their semantics when enabling Contents or switching to Rules.

Searches continue to the end of the selected scope without a 300-match cutoff. Results are stored in a temporary SQLite database, with **1,000 rows per page** in the native table. Sorting covers the whole result set, and **Export All Results** includes every page. Fuzzy ranking waits for candidate enumeration to finish so its first result is the highest-ranked match. Other searches publish their first match while work continues. Stop preserves the results found so far and terminates the pipeline's child processes.

The default table order follows the search pipeline; fuzzy searches use `fzf` relevance. Click column headers to sort, then **Search Order** to restore pipeline order. Grouping and multi-selection use the displayed page. Document counts cover all results, and previous/next content-match navigation loads adjacent pages when needed.

Every live search enumerates the current scope. Prepared filename snapshots and explicit **Search within results** have frozen membership; the UI identifies those sources. Matching results and their sort indexes are stored in a temporary SQLite database and removed when the result store is released. Document conversions and prepared content indexes have separate validated caches.

The planner is described in [search architecture](search-architecture.md), with repeatable checks in the [development guide](development.md). Run `ruby scripts/benchmark_planner.rb` to compare full exported commands and the packaged CLI with native tools, fd→rg composition and overlapping branch scans.

Startup measurements separate query preparation from fresh CLI process costs. Run `ruby scripts/benchmark_startup.rb` against an existing app, or `zsh scripts/benchmark_startup.sh` to also profile preparation in the checked-out Swift sources.

## Scope and options

Open **Scope & Options** in simple mode to combine minimum/maximum file sizes with a modified, created, last-opened, or document-created date. In Rules, add Size or Date conditions to the same rule tree. Sizes accept bytes, decimal units (`KB`, `MB`, `GB`, `TB`), and binary units such as `MiB`. Size bounds are inclusive and apply to files, not directory totals. Dates support today, yesterday, the past 7/30/365 days, before a date, after a date, or a range inclusive of both calendar dates in your local time zone. Before/after exclude the chosen calendar day. Creation-time comparisons use macOS birth times at one-second resolution.

For example, set Filename to `*.pdf` with **Wildcard** and **Modified → Last 7 days**, or leave Filename empty and set a **500 MB** minimum to find large files. Every membership filter is part of the command pipeline and is saved with history entries. Live search reads current metadata; indexed search uses metadata from the last refresh.

The panel groups **Folders and scope**, **File filters**, **Content matches**, and **Exclusions**. Additional roots use removable folder rows; exclusions use multiline editors. **Add dependencies and builds** adds folder exclusions while preserving existing entries; **Clear exclusions** clears both folder and file exclusions. Exclusions are exact, case-sensitive directory names at any depth below the selected search root; similarly named files remain searchable. **Include hidden files** is separate from **Include ignored files**, and `.git` is an explicit default folder exclusion. These options control recursive searches and index builds; an empty, unfiltered directory listing is for browsing.

The Scope & Options icon indicates additional options. Selecting a history entry restores both search fields or rule trees, every option, and its imported command. **Reset Options** keeps the primary search fields in simple mode; in Rules it keeps all file/content conditions and resets the shared options.

Filename searches and snapshots use fd semantics: `.gitignore`, `.ignore`, `.fdignore`, and applicable global rules. Contents searches use ripgrep semantics: `.gitignore`, `.ignore`, `.rgignore`, and applicable global rules. Adding file filters or switching between simple controls and Rules preserves the selected policy. Use `.ignore` for rules shared by both modes. **Include ignored files** disables ignore-file rules while retaining explicit exclusions. The shared worker uses these same policies. `find` is a fallback only when ignore files are explicitly disabled.

Scope & Options provides an independent **Path** condition in simple mode (contains, exact, wildcard, regex, fuzzy), extension groups, excluded-file wildcards, and literal file-query conditions. Path conditions normally match relative or full paths; imported `fd --full-path` commands select **Full absolute path only** to preserve anchored patterns. These combine with the main Filename and Contents fields, so a content regex can use a filename glob, path constraint, size and date bounds together. Contents offers whole-word matching, matching files instead of matching lines, and 0–20 preview context lines.

Add search roots with **Additional folders → Add Folder…**. Depth counts the direct children of each root as 1; leave the maximum empty for recursion, or choose **This folder** for depth 1. Overlapping roots do not duplicate matches. **Follow symbolic links** is explicit and off by default.

**Search inside app bundles and packages** controls traversal into common macOS package directories, including `.app`, `.bundle`, `.framework`, `.pkg`, and project/document bundles. Turning it off prunes their contents while retaining the package directory itself in folder results. This is an extension-based policy shared by live commands and indexes.

Choose **Spotlight** as the source to query macOS's existing index with `mdfind`. This source uses that existing index. The same filename and metadata filters apply; Contents uses the shared worker to read the returned candidates. Spotlight can omit unindexed or recently changed files and does not apply ignore files. Its copied command reproduces an indexed query, not an exhaustive live scan.

**Last opened** dates use Spotlight's `kMDItemLastUsedDate`, not filesystem access times. Choosing that date field selects Spotlight automatically. Applications do not all update this metadata; unknown dates remain unknown. Older saved snapshots do not expose their previous access-time values as opening dates.

## Finder tags

**Finder tags** are exact-name file conditions under **Scope & Options → File filters**, with All, Any, or None matching. Tags come directly from Finder's extended attributes, including snapshots and FSEvents refreshes, without Spotlight. Colors are not part of tag names. Older snapshots need refreshing before tag conditions can use them.

## Presets and searching within results

**Presets**, beside Scope & Options, saves complete searches, additive filters, or scopes. Filters add conditions using the current matching options; incompatible content units are reported instead of changing meaning. Rename, replace, delete, import and export share a process-locked library with the CLI. Imports are additive. **Results → Actions → Search Within These Results** captures all result pages as a durable NUL file list; later queries consume that list as their candidate source. The scope row shows this list instead of a folder; **Use Folder** returns to the previous folder. This refines outer files, not individual archive members. Presets referencing result lists require those lists to remain available on the same machine.

## File actions and content matches

- Use **Command-click**, **Shift-click**, or **Command-A** in the results table to select several results. Drag selected rows into Finder or another app, or use **Copy Files** / **Command-C** to put file URLs on the clipboard. Copying files or paths deduplicates repeated content hits from the same file.
- The **Actions** menu and right-click menu provide Open, Show in Finder, Copy Files, Copy Paths, Copy Matching Lines, and CSV export. **Export All Results** exports every stored page, including collapsed matches. During a running search, it exports the matches stored when the export begins.
- Open files, reveal them in Finder, or press **Space** for Quick Look. **↑/↓** move through results; **Space**, **Escape**, or the small **×** closes the preview. Navigation and close controls use the same native circular buttons as other compact app actions.
- **Group by File** keeps a file's first match in the group row and lets you collapse its additional hits. Counts refer to loaded matching lines, not every occurrence on disk. **Actions** also expands or collapses all file groups.
- Open the Inspector for highlighted matching text with a configurable number of surrounding lines on either side (three by default). The arrows move to the previous/next loaded match in that file. Context is read on demand; changed or unavailable files are reported. Preview reads stop at 16 MB and very long lines are shortened; the editor action opens the full file.
- The Finder and Terminal buttons beside **In folder** open that folder. The Inspector’s Terminal button opens a selected directory itself, or the containing directory for a file or archive member. Opening Terminal does not extract archives.
- Right-click a content match and choose **Open in Editor at Line…**, or use the Inspector button.
- Choose **Automatic**, **Visual Studio Code**, **VS Code Insiders**, **Cursor**, or **VSCodium** in Settings → General. Automatic chooses the first installed supported editor in that order. The editor must be installed; FindUI does not download it.
- Revisit searches through history and pin frequently used searches.

**Click the command in the footer to copy it immediately.** Right-click it and choose **Show Full Command…** for a selectable full view. The copied text is a self-contained shell command or pipeline containing every membership filter and fuzzy-ranking stage. The app executes the same compiled stages; Swift only decodes records and supplies presentation metadata. Filename output is NUL-delimited; content matches are ripgrep JSON. Direct rg exports also include its begin/end/summary records; these carry no additional matches. The CLI and GUI consume the same match records. Given the same filesystem/tool state, the command reproduces the match set and fuzzy ranking. Column sorting and page/group layout are presentation choices. Commands for compound searches can be long; the footer shows an abbreviated pipeline and the full view exposes every stage. **Search Details** describes searches using a saved index or a native directory listing.

## Windows and tabs

**⌘N** opens a new window; **⌘T** adds a native macOS tab to the current search window. Each has its own query, rules, scope, results, sorting, selection, inspector, and command input. History and pinned searches are shared and update immediately. App-wide settings remain in Settings; changing a search in one tab never edits another tab.

**⌘Q** quits FindUI and stops its active searches. **⌘W** closes the selected tab or window. The red close button also quits when you close the last search window, even with Settings open, after saving the shared library. Other search windows, including minimized windows, keep the app open. The native tab bar also supports adding tabs, moving a tab to another window, and merging windows.

The history and inspector toolbar buttons collapse native split panes without rebuilding the results table. History keeps its scroll position, and dragging a divider adjusts the pane width.

## Optional indexes

Enable **Snapshot** to search a saved filename index for the current drive. Build, inspect, refresh, or delete indexes in **Settings → Indexes**. You can also refresh beside the index timestamp in the search window.

A saved snapshot stores filenames, paths, and metadata such as dates and sizes. Snapshot filters use that saved metadata even if live files have changed or disappeared. The same predicate compiler and `fzf` ranking are used; copied snapshot search commands run against the saved index through the headless CLI. It **does not index file contents**. Contents searches live files and optional extracted text.

Indexes can be refreshed manually or kept current with **Keep this index updated while FindUI is open** in Settings → Indexes. The shared headless service coalesces FSEvents, updates touched entries and new/renamed subtrees, and replays recorded events after downtime. It rescans on dropped/wrapped events or changed ignore rules. SQLite commits changed entries transactionally; each generation publishes atomically, competing writers are rejected, and failures retain the previous snapshot. Updates are asynchronous; the displayed timestamp identifies the saved generation. **Copy Terminal Update Command** runs the same service without the GUI. No login item or launch agent is installed automatically.

## Optional indexed words and matching options

Choose **Indexed words** in the Contents matching menu for explicitly prepared word/phrase search, ranked by SQLite FTS5 BM25. Use **Update** beside the indexed-word status in the scope row, or **Scope & Options → Content matches → Update Word Index**, to prepare or refresh the selected folders. Unchanged sources and completed conversions are reused. **Related word forms** offers 18 Snowball stemming languages through a **Language** picker. ICU dictionary segmentation also recognizes word boundaries in scripts without spaces; punctuation still separates filename-like tokens. Adding a language builds its tokenizer index from stored text. Boolean groups can match each document separately or the whole outer container. Filename filters, ignore rules, saved-result scopes and optional fzf ranking still apply.

Ordinary indexed content conditions search document text; title, author and archive-member names require their corresponding conditions. Concurrent preparations recheck the committed source after acquiring a shared cache lock, so they do not write the same unchanged source twice.

Word preparation is explicit: it does not run a background crawler. New files and new terms appear after an update. Scope coverage and source/directory identities are checked independently of query hits, so even an empty search reports changed or unprepared coverage. Small scopes use bounded parallel metadata checks. Larger scopes can reuse a complete check after verified macOS filesystem-journal replay. Missing/dropped events, changed roots, hard links, followed symlinks or unsupported filesystems retain the complete metadata fallback. Neither verification route reads source contents or converts documents. Successful updates reconcile deleted sources; unavailable volumes and files outside a filtered update retain their prepared data. Current document, attachment, media and custom-reader choices also gate cached results. This mode matches case-insensitive words and phrases, not arbitrary substrings, regexes or proximity. Select Literal, Expression or Regex for live matching. Regular live search never silently switches to token search.

The Contents header in **Rules** also selects **Live text** or **Indexed words**, preserving the Boolean conditions when switching. Indexed words requires word/phrase or metadata conditions; regex and proximity remain live searches. Scope presets retain the source required by existing conditions, and incompatible combinations report an error before applying.

For live text, **Scope & Options → Advanced** offers an explicit text encoding and **Allow typos** (one or two edits per literal word/phrase). Regex, proximity and metadata conditions retain their existing semantics. Invalid UTF-8 in a snippet no longer drops a real backend match; highlighting respects backend byte offsets. Converters return Unicode independently of a plain-text encoding override.

**Scope & Options → Content matches → Match across line breaks** enables multiline regexes, including native `rg --multiline` for simple searches. Add `(?s)` when `.` should match newlines. Boolean conditions use the same matching block in this mode; choose **Same document / member** or **Whole file / container** to combine separate blocks. Converted text uses the same matcher as plain text, and previews show the complete matching span. This is explicit because multiline search may buffer a file; compound execution bounds its aggregate search heap. Imported `rg -U` commands and saved searches preserve the choice.

**Explain a File…**, in the command details/menu, reports the same backend's scope/ignore, file-filter and content decisions for a selected file. Its **Copy Command** reproduces the explanation without opening the GUI.

## Optional AI Search

Use the **separate sparkle button beside the paired sidebar buttons** to describe a search in plain language. A new installation detects and selects an existing ChatGPT login in Codex; saved API or disabled settings remain authoritative. The icon opens setup directly when needed. New API setup defaults to **OpenRouter / Gemini 3.8 Flash**, and Codex defaults to **GPT-6.1 Sol**. The provider menu includes OpenAI, Anthropic (Claude), Google (Gemini), OpenRouter and Custom URL. Each URL has its own saved Keychain key. The searchable model dropdown lists the selected provider’s models and accepts custom IDs. Ordinary search stays entirely local and works with AI disabled. AI sends your description and current search settings only when you generate; it does not upload file contents or results.

AI Search displays the provider and model, then applies a validated search directly to the main interface. Searches that fit the simple controls use them; mixed or more complex conditions open in Rules. Inspect or edit the resulting controls, options and compiled command there. Simple searches retain native fast paths. Invalid output gets one repair attempt; errors and clarification requests leave the current search untouched. Settings changes, editing the request, Stop and Cancel discard pending results. See [AI search setup, grammar and headless commands](ai-search.md).
