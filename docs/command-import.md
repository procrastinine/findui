# Command import and command searches

FindUI has two explicit ways to use a pasted command. Both execute through the headless backend and stream into the ordinary result table, history and cancellation lifecycle.

Common short-option forms work in either route: `rg -ni -ePATTERN`, `fd -HI -epdf`, and supported `xargs -0r rg` / `fzf -fPATTERN` stages. Values such as `-e '-ni'` remain literal, and `--` ends option parsing. Unsupported options cannot become editable controls; command mode passes them to the tool for validation.

**Apply & Search** translates supported `fd`, `rg`, `find`, FindUI exports, and NUL-delimited `fzf` / `xargs rg` pipelines into editable search conditions. Nested `find` parentheses, implicit/explicit AND, OR and NOT keep their precedence. `-iname` rules retain their own case setting when combined with `-name`. Repeated `rg -e` patterns become an Any group; `rg -v` becomes a None group. The compiler can then select the usual native or compound execution path.

For example, the following becomes one editable nested file expression:

```sh
find . -type f \( \( -name '*.swift' ! -name 'skip*' \) -o -iname '*.md' \) -print0
```

Conditions are only translated when their meaning is preserved. A `find` type check under OR/NOT cannot always fit a single Files/Directories selection. Likewise, ripgrep's positive glob/type whitelists may admit dotfiles while still skipping hidden directories; that does not correspond to an Include Hidden checkbox. Such cases explain the mismatch instead of changing membership. Explicit `rg --hidden` or a final `--glob '!.*'` removes that ambiguity. FindUI's own generated commands already make its selected hidden-file behavior explicit.

**Run as a command instead of editing controls** retains a single `fd`, `rg`, or `find` command and accepts the tool's full option set. For example, `rg -t swift --max-count 2 needle .` preserves the installed ripgrep type definition and per-file match limit. The main controls are replaced by the original command and working folder, with **Edit Command…** and **Use Search Controls** actions. Recognized search forms use ripgrep JSON or NUL-delimited paths in the results table; their presentation flags are adapted to that record format.

Other forms run with their original arguments and show selectable **Command Output**. This includes pattern files, preprocessing, decompression, counts, context, custom formatting, and tool actions such as `fd --exec` or `find -exec`. Unknown options reach the installed tool; its diagnostic and exit status appear in the error panel, with any output retained. The GUI shows at most the first 1 MiB of text and continues draining the process. Copied commands and the headless CLI retain complete stdout, including a missing final newline. Commands execute once; FindUI never retries a command to obtain another output format. Tool actions, including `find -delete`, have the same effects as in Terminal.

Command mode accepts one tool invocation, not a general shell program. It still rejects arbitrary top-level programs, substitutions, redirections and unsupported pipelines. Arguments go directly to the selected tool. Standard input is closed; interactive prompts and terminal applications are outside this mode. Working directories are set in the child spawn, so simultaneous searches cannot change each other's paths. Multi-line commands use ordinary backslash continuations; quoted patterns and paths may contain newlines and Unicode.

Saved command searches retain their original text and working folder. Exported FindUI wrappers regenerate and compare the complete script before restoration, then resolve tools on the current machine. Pasted executable paths never choose a different executable. A normal control edit clears command mode atomically, and the compiler rejects a persisted command combined with unrelated filters or index options. AI-generated searches use the structured rule format instead of this fallback.

Copied `FindUI --cli search … --snapshot …` and `browse … --snapshot …` commands restore in command mode. They keep the explicit artifact, scope and reference clock; they never select a different drive index or switch to a live walk. Only inline search JSON and absolute snapshot paths are accepted. Nested command searches and mutating FindUI subcommands are rejected. The local CLI runs the saved search and its filename results appear in the same table.

Generated ripgrep filename type filters are translated back to compact filename/extension controls when possible, including the complete Unicode case folds for `s` and `k`. Their subsequent searches still use native `rg`. More complex type patterns retain exact regex conditions. Adding these conditions preserves existing file/content groups without introducing empty groups.

`fd --glob` folds ASCII letters only; imported globs retain that distinction in their regex conditions. FindUI's ordinary filename controls use Unicode case folding consistently in file and content searches. The compiler still uses one native `rg` invocation for representable imported ASCII glob filters. Canonical Unicode literal patterns also translate back to literals by checking the exact generated grammar.

With the same installed tools and unchanged search options, copying a search command, importing it, and copying again produces identical command text. This is compiler reconstruction from the parsed state, not replay of a saved shell string. Complex exports also restore their reference clock and request options, such as statistics and browsing. Changed controls invalidate the old context. Relative-path fuzzy conditions rank paths relative to the selected folders; duplicate relative filenames in different folders retain their original identities. Fuzzy accent normalization is visible in Scope & Options.

The same translation is available without the app: `FindUI --cli import-command COMMAND --directory /folder` prints a validated SearchState JSON without searching. Add `--native` to retain the command and let the tool validate its options at execution time. Save that JSON and pass it to `FindUI --cli search @state.json`; `--print-command` and `--explain-plan` use the same execution plan.

To refine command results, use **Search Within These Results** (or `search … --within paths.nul` from the CLI) before adding facets or filter presets. This captures paths rather than approximating the command's predicates. Hidden/ignored files and files outside the original working folder remain candidates; only the captured manifest is read. **Use Folder** restores the command's previous working folder. A command can also be saved as a complete search preset.

The `CommandImportRobustnessTests` fixtures compare nested rules and hidden-file command searches with the installed tools, cover Unicode/newline filenames, round trips, independent working directories, rejection of shell programs, and transitions back to editable controls. `NativeCommandPassthroughTests` compares additional options with the actual tools, verifies action execution occurs once, preserves text and tool errors, bounds GUI output, and checks transitions between text output and file results.

`ruby scripts/audit_command_roundtrips.rb` checks the packaged CLI: it executes each export, reimports it, compares exact command text and result records, and repeats three times. The matrix includes filename/content controls, traversal, Unicode/newline paths, mixed nested ALL/ANY/NONE rules, all content units, prepared words, saved-result scopes, native commands and snapshots. `scripts/verify_app.rb` runs this audit from a relocated app with its GUI executable removed. A failure retains its fixture and expected/actual records instead of being dismissed by a passing retry.
