# AI search proposals

AI Search translates a description into the same typed rules used by the editor and command compiler. Open the **separate sparkle button beside the paired sidebar buttons**. If FindUI has no saved AI configuration, it detects an existing ChatGPT login in Codex and selects it automatically. Detection sends no inference request and does not save a preference. Existing choices, including explicitly disabled AI or a configured API, always take precedence. When setup is needed, the same entry opens AI settings directly. The search sheet identifies the provider and model. Describe the search and press **Search**: a validated response applies once, closes the sheet and searches immediately. Inspect the resulting controls, options and command in the main interface. Simple searches use the simple controls; mixed or otherwise unrepresentable conditions retain their Rules tree. Errors and clarification questions stay in the sheet without changing the current search. Closing the sheet, Stop, editing the description or changing provider settings cancels the request, including late responses from transports that ignore cancellation.

The provider receives the description, current folder and search settings, current date and time zone. FindUI does not upload file contents or result rows. It does not send imported source commands or API keys in the prompt. Search proposals do not execute programs. They pass through local grammar validation and the ordinary search normalizer/compiler before becoming controls or commands.

Choose OpenRouter, OpenAI, Anthropic (Claude), Google (Gemini), or Custom URL from the provider menu. Built-in choices supply the correct URL and model ID; Custom URL also offers an OpenAI compatible or Anthropic API format. Existing configurations keep their model and URL. New API setup defaults to OpenRouter.

| Provider | API base URL | Initial model |
| --- | --- | --- |
| OpenRouter | `https://openrouter.ai/api/v1` | `google/gemini-3.8-flash` |
| OpenAI | `https://api.openai.com/v1` | `gpt-6.1-sol` |
| Anthropic (Claude) | `https://api.anthropic.com/v1` | `claude-sonnet-5-5` |
| Google (Gemini) | `https://generativelanguage.googleapis.com/v1beta/openai` | `gemini-3.8-flash` |

The model dropdown searches friendly names and model IDs and also accepts a manually entered ID. Up/Down chooses a row, Return applies it, and Escape closes the list. Its first opening fetches the selected provider's catalog; typing and reopening reuse it until Refresh, a provider/URL change, or a saved-key change. OpenRouter's public catalog needs no key. Other catalogs use only that endpoint's saved key. Anthropic's catalog follows pagination and displays friendly model names. The API-key row shows **Key saved**, **No key saved**, or an unavailable status for the selected URL; a saved key changes the field prompt to **Replace saved key**.

HTTPS is required except for loopback servers. Each API URL has its own macOS Keychain entry, scoped to the exact generation endpoint (`/chat/completions` or Anthropic's `/messages`). Keys are absent from preferences and search exports. Switching providers clears unsaved key input and checks the newly selected URL's saved-key status. Switching back reuses that URL's key; saving or removing one does not affect another. Custom URLs on the same host with different paths also have distinct entries. A local server can use an empty key. Redirects are refused.

OpenAI, Google and OpenRouter use chat completions; Claude uses Anthropic's native Messages API and authentication headers. All responses pass the same strict local validator. Anthropic's structured output [does not support recursive schemas](https://platform.claude.com/docs/en/build-with-claude/structured-outputs), so the complete recursive grammar goes in its system prompt, without tool calls or truncated rule shapes. The endpoints and defaults follow [OpenAI's model documentation](https://developers.openai.com/api/docs/models/gpt-6.1-sol), [Google's compatibility interface](https://ai.google.dev/gemini-api/docs/openai), and [Anthropic's model catalog](https://platform.claude.com/docs/en/models/overview).

**ChatGPT via Codex** detects a local Codex executable and uses `codex login status`. It requires a ChatGPT login, not an API-key login. FindUI never reads `auth.json` or copies OAuth tokens. Codex owns authentication and refresh. Generation uses the supported noninteractive CLI with the complete output grammar in its prompt, an ephemeral session, an isolated temporary working folder, no user config or project rules, and disabled tools/plugins/apps/browser/skills. Its response passes the same strict local validator and bounded repair as an API response. Native recursive output constraints are avoided because they lost compound conditions in live tests. The installed version must support the isolation controls. The preferred model is `gpt-6.1-sol`; its dropdown uses Codex's local public model metadata and also supports custom IDs or Codex's own default. The optional executable chooser supports installations outside normal locations. Codex is a separate optional dependency, not needed for ordinary searches or the API provider.

The wire grammar is an explicit recursive tree, not Swift's internal enum encoding and not shell text. A node is a file or content condition, or `all`, `any`, or `none` with `children`. `none` means NOT(OR(children)). Mixed branches retain their relationships. There are at most 64 nodes and 8 nested levels, matching the detailed editor. Options set to `null` preserve current settings. Costly document readers and archive expansion remain unchanged unless requested. A response needing clarification cannot contain runnable rules or changed options. Duplicate keys (including escaped aliases), missing or unknown fields, type coercions, contradictory date fields and oversized responses are rejected. Invalid model output receives one repair attempt with bounded local validation feedback; repeated invalid output fails visibly. Network errors, refusals, partial responses, unexpected tool calls, excessive output, and unsupported searches are errors rather than approximate searches. Schema validation establishes a valid search representation; it cannot prove the model understood the user's intent. The main controls and copied command expose the actual search, and independent fixture tests check representative meanings.

Proposals preserve the selected folder, additional search roots and any selected-results scope. Change those in the regular Scope controls before generating; descriptions requiring a different scope receive a clarification. Snapshot and Spotlight sources are also preserved unless an explicit source change is requested, and unsupported combinations fail validation.

Simple generated searches still normalize into native `fd`/`rg` commands. AI does not choose the execution backend or add performance options. The same compiler factors separable conjunctions and retains mixed branches when necessary.

The headless interface is available from the app's bundled `Contents/MacOS/FindUI`:

```sh
FindUI --cli ai schema
FindUI --cli ai status
FindUI --cli ai models openrouter
FindUI --cli ai models openai
FindUI --cli ai models anthropic
FindUI --cli ai models google
FindUI --cli ai configure @ai-settings.json
FindUI --cli ai key set < api-key.txt
FindUI --cli ai propose 'Swift files containing TODO' @state.json > proposal.json
FindUI --cli search @proposal.json --print-command
```

`ai propose` prints a validated `{state, referenceDate, summary, clarification}` search description; it does not run the search. A clarification result has no state. `ai apply @model-output.json @state.json` validates a model's grammar JSON entirely offline and prints the resulting `SearchState`. `ai schema` is suitable for another LLM client or manual structured generation. `ai key remove` removes the key for the configured endpoint. Avoid putting keys in command arguments; `ai key set` accepts stdin.

Example settings file:

```json
{
  "enabled": true,
  "provider": "compatible",
  "baseURL": "https://openrouter.ai/api/v1",
  "model": "google/gemini-3.8-flash",
  "codexModel": "gpt-6.1-sol",
  "codexPath": ""
}
```

Use `"provider": "codex"` for the existing ChatGPT login, `"compatible"` for OpenAI/Google/OpenRouter or a compatible server, and `"anthropic"` for Claude's Messages API. Set `baseURL` and `model` from the table for direct API access. Settings contain no key. The GUI and CLI use the same preferences domain, Keychain service, and automatic resolution for an unconfigured installation. `ai status` reports whether its configuration was detected automatically.

The shared behavioral instructions are 336 words, followed by compact current settings. The exact schema is supplied once per request, through native structured output where supported or in the prompt otherwise. OpenRouter Gemini uses JSON-object mode: its native recursive schema conversion returned empty objects during live testing. Both transports use the same local validator; malformed output gets at most one repair. The default Gemini 3.8 Flash request uses low reasoning effort and an 8,192-token output ceiling.

Verification is repeatable: `swift test --scratch-path .build/out --disable-sandbox --no-parallel --filter ai` covers mixed Boolean truth tables, simple normalization, validation bounds and coercions, clarification handling, reader opt-in, prompt privacy, repair limits, API request shape, and subprocess timeout/cancellation. `ruby scripts/audit_ai_codex.rb` checks the actual installed Codex against a local fake provider with an empty temporary login directory; it asserts that the outbound request exposes zero tools and makes no external model call. This was verified with Codex 0.159.2. Native UI checks use `zsh scripts/audit_ai_search.sh` with isolated preferences and fake providers.

Live provider checks are separately opt-in and use synthetic fixtures. The harness compares generated result sets, scope and reader options, and clarification behavior with independently specified expectations. Its document case checks proposal settings; extraction is covered by the separate backend audit. These fixed examples do not establish general language-understanding accuracy.

The following commands make real requests and may consume provider quota. Use a model available to your account. Reports stay under ignored `.cache/`; the harness does not save preferences or keys.

```sh
zsh scripts/audit_ai_live.sh --provider codex --model gpt-6.1-sol \
  --output .cache/ai-live/codex.json
zsh scripts/audit_ai_live.sh --provider openrouter --model google/gemini-3.8-flash \
  --key-file /path/to/key.txt --output .cache/ai-live/openrouter.json
```

Use `--cases filename,mixed` for a smaller run or `--binary /path/to/FindUI.app/Contents/MacOS/FindUI` to check another build. Ordinary builds and automated tests make no live provider requests.

The integration follows [Codex noninteractive mode](https://learn.chatgpt.com/docs/non-interactive-mode) and [OpenAI structured outputs](https://developers.openai.com/api/docs/guides/structured-outputs). Model and CLI availability can change; configuration and local checks report actionable errors.
