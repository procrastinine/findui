# Unified grouped-search contract

[FindUI](../README.md) · [Documentation](../README.md#documentation)

Manual controls, editable command imports, saved searches, and optional AI proposals share one grouped root state and compiler. AI requests require the user to press Search, and their output passes through a strict structured grammar and local validation. See [AI search](ai-search.md) for provider configuration and proposal behavior.

## One scope and one expression

The root state owns scope/traversal and one recursive rule tree. Each leaf selects
its condition type: filename, path, file type, size, date, Finder tags, contents,
proximity, document metadata or Spotlight text. AND, OR and NOT groups can contain
any of these conditions, including other groups. For example,
`((Swift AND TODO) OR (Markdown AND FIXME)) AND modified-this-week` keeps the two
content conditions attached to their own file types. Legacy saved file/content
trees migrate to an AND expression without changing their meaning.

| Area | Meaning | Controls |
| --- | --- | --- |
| Where | Candidate universe for the whole search | Folders, source, hidden/ignored entries, depth, symbolic links |
| Rules | Which candidates qualify | One type picker per condition; nested All (AND), Any (OR), None (NOT) groups |

Every condition has one home in the expression. A rule outside an OR applies to
every branch; a rule inside a branch applies only there. Traversal rules are
global and never silently become branch filters. None means NOT(OR(children));
put an All group inside None to negate a conjunction.

The detailed view has one Match / Add header and a scrolling tree. Each row can
change its condition type. Every group has its own operator, Add and remove
controls; a row's context menu can wrap it in a group or move it up/down.
Removing the final top-level condition clears the search. An empty nested group
remains an incomplete edit until filled or removed. Scope, item kinds and folder
exclusions stay in Scope & Options. File/text case options and the content
matching unit are shared settings, never duplicated hidden predicates.

The ordinary filename and contents inputs are compact projections of this state.
The existing simple interface is a subset, not another query store. When a tree
cannot be shown faithfully as one field plus simple filters, that section expands
to its grouped editor. Do not display only its first branch in the main field.
Do not keep a second active collection of hidden filters behind the grouped view.

## State transitions

- Adding grouping preserves every existing predicate and matching option.
- Empty unfinished rows do not run a broader query; keep the previous results
  until the edited query is complete and show the incomplete row inline.
- Removing one condition changes only that condition.
- Returning to compact controls is allowed only for a lossless projection.
- Complex history entries restore every branch in the single scrolling editor.
- Command import, history, and the UI all enter the same root state.
- Copy always compiles the full tree, including strict bounds and branch scope.
- Keep stable control widths/heights and native pickers. Deliberate expansion is
  different from transient movement during an ordinary selection change.

Contents have an explicit persisted matching unit. Legacy multi-term content
expressions match on one line. "All on one line" and "all somewhere in the same
file" are different operations, covered by copied-command fixtures. Whole-file
negation complements the tool's match set within the candidate files, including
empty files; line negation can only return real lines. One-term positive searches
have the same membership for either unit.

Mixed expressions return each matching file once. A branch satisfied
entirely by file conditions also matches an empty or binary file without reading
its contents. Other branches retain the selected same-line, same-document or
same-file text semantics. File conditions never change value between lines or
archive members. Indexed words still use the prepared index; Spotlight remains
a separate metadata source and cannot combine Spotlight text with live text.

## Compilation and performance

The compiler partitions independent AND factors without expanding OR groups.
Separable expressions reuse the existing fd/rg/find plans, including a single rg
traversal for eligible file-type plus content filters. Mixed branches compile to
one worker request. It evaluates file conditions before opening bodies, skips
impossible candidates, immediately returns file-only matches, and shares one
parallel content scan among distinct conditions. External fuzzy/Spotlight
membership uses bounded temporary storage and carries its file masks forward;
indexed words join those masks with FTS Boolean conditions. There is no shell
pipeline per branch and no distributive expansion.

Include hidden is a scope constraint. Native fd/rg exports explicitly exclude
dot names when it is off, because rg types and ignore-file whitelists can otherwise
override the tools' implicit hidden filtering. Live walks and saved-file admission
apply the same policy. An explicitly selected hidden root remains searchable;
hidden descendants still require Include hidden.

## Command import and export

Editable fd/rg/find/fzf imports use the structured CLI parser. Single fd, rg, and
find invocations can also run in command mode with all tool options; output that
does not map to file rows is displayed as text. See [command import](command-import.md).
Simple native
exports are ordinary commands; importing them preserves search semantics, even
when equivalent controls use a different representation. Compound exports carry
a `FindUI search v1` comment that describes their root state and, when needed,
the time used to calculate relative date bounds. Pasting an export with this
metadata regenerates its entire script and requires an exact match.
The app then restores the state and compiles with its own resolved executables;
it never executes the pasted script. Changing the shell program without matching
its search state is rejected.

Compound export imports require this compiler format; arbitrary edited shell
scripts remain outside the importer. Snapshot descriptions are still not portable
live-search commands.

## Required semantic regressions

1. `svg, pdf, illustrator, but not postscript` is the listed positive suffixes
   AND exclusion of `.ps`; the word "vector" does not broaden an explicit list.
2. Photoshop OR (Illustrator AND basename starts with `edit_`) matches all `.psd`
   and `.psb`, plus `edit_*.ai`. The prefix must not apply to Photoshop files.
3. (Vector formats AND size <= 10 MB) OR (image formats AND size <= 100 MB) keeps
   separate size bounds. Overlapping format groups retain ordinary OR semantics;
   do not invent exclusions to make the groups disjoint.
4. A content condition ANDed with a group searches only files admitted by that
   group; a content condition inside one OR branch does not constrain its siblings.
5. Blank file predicates retain the direct-rg opportunity. Blank contents still
   produces file results. Pipeline selection is the compiler's responsibility.
6. Literal `email`, raw regex `email`, and preset `email` remain distinct.
7. A typo in a selected folder can be resolved with filesystem evidence; the same
   spelling inside a literal query or pasted command remains unchanged.
