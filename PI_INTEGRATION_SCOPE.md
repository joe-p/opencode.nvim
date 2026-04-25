# Pi Agent Integration — Scope of Work

## Goal
Add a compatibility layer that lets opencode.nvim’s chat UI (input/output windows, renderer, keymaps) drive a **pi** subprocess via its [JSONL RPC protocol](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/rpc.md). The pi process runs as `pi --mode rpc` and speaks JSONL over stdin/stdout.

## Current Architecture (opencode.nvim)

| Layer | Responsibility | File(s) |
|-------|---------------|---------|
| **Server** | Spawns/manages the `opencode` binary in `serve` mode (HTTP) | `opencode_server.lua`, `server_job.lua` |
| **API Client** | HTTP REST calls to opencode server (`/session`, `/message`, `/event` SSE stream) | `api_client.lua` |
| **Event Manager** | Subscribes to SSE, normalizes `message.part.delta` → `message.part.updated`, throttles/collapses events, emits to renderer | `event_manager.lua` |
| **Renderer / Events** | Consumes `message.updated`, `message.part.updated`, `permission.asked`, `session.updated`, etc. and flushes to output buffer | `ui/renderer/events.lua`, `ui/renderer/flush.lua` |
| **Formatter** | Turns `OpencodeMessage` + `OpencodeMessagePart[]` into `Output` (lines + extmarks + actions) | `ui/formatter.lua`, `ui/formatter/tools/*.lua` |
| **Input Window** | Captures user prompt, mentions, slash commands; sends via `services/messaging.lua` → `api_client:create_message()` | `ui/input_window.lua` |
| **State** | Central store for `active_session`, `messages`, `opencode_server`, `api_client`, `pending_permissions`, etc. | `state/*.lua` |

### Key Types
- **`OpencodeMessage`** = `{ info: MessageInfo, parts: OpencodeMessagePart[], ... }`
- **`OpencodeMessagePart`** = `{ type: 'text'|'tool'|'reasoning'|'patch'|'file'|..., id, messageID, sessionID, text?, tool?, state?, ... }`
- **Events** = `message.updated`, `message.part.updated`, `message.part.removed`, `permission.asked`, `permission.replied`, `session.updated`, `file.edited`, etc.

## Pi RPC Protocol (what we must adapt to)

### Transport
- **Commands** → stdin as JSONL (`{"type":"prompt","message":"hello"}`)
- **Responses** ← stdout as JSONL (`{"type":"response","command":"prompt","success":true}`)
- **Events** ← stdout as JSONL (interleaved with responses)

### Relevant Commands
| Pi Command | Purpose | Maps to opencode API |
|-----------|---------|---------------------|
| `prompt` | Send user message (+ optional images) | `POST /session/{id}/message` |
| `steer` / `follow_up` | Queue messages while streaming | (no direct equivalent) |
| `abort` | Cancel current operation | `POST /session/{id}/abort` |
| `new_session` | Start fresh session | `POST /session` |
| `get_messages` | Fetch conversation | `GET /session/{id}/message` |
| `get_state` | Fetch model, streaming status, session metadata | `GET /session/{id}` (partial) |
| `set_model` | Switch model | (modeled via opencode config/model state) |
| `bash` | Execute shell command, add result to context | `POST /session/{id}/shell` |
| `fork` / `clone` / `switch_session` | Session branching | `POST /session/{id}/fork` etc. |

### Relevant Events
| Pi Event | What it means | Target opencode Event |
|----------|--------------|----------------------|
| `agent_start` | Agent begins processing | `session.status` (or custom) |
| `agent_end` | Agent completes | `session.idle` |
| `turn_start` / `turn_end` | Assistant turn boundaries | (can be ignored or mapped to status) |
| `message_start` / `message_end` | Message boundaries | `message.updated` |
| `message_update` | Streaming delta (`text_delta`, `thinking_delta`, `toolcall_delta`, `done`, `error`) | `message.part.updated` / `message.part.delta` |
| `tool_execution_start` | Tool begins | `message.part.updated` (status=`running`) |
| `tool_execution_update` | Tool partial output | `message.part.updated` (update output) |
| `tool_execution_end` | Tool completes | `message.part.updated` (status=`completed`/`failed`) |
| `queue_update` | Steering/follow-up queue changed | (can be displayed as synthetic part or ignored) |
| `compaction_start` / `compaction_end` | Context compaction | `session.compacted` |
| `auto_retry_start` / `auto_retry_end` | Retry on transient errors | `session.status` |
| `extension_ui_request` | Extension wants UI interaction (`select`, `confirm`, `input`, `editor`, `notify`, `setStatus`, `setWidget`, `set_editor_text`) | `permission.asked` (for blocking dialogs) or direct UI calls (for fire-and-forget) |
| `extension_error` | Extension threw | `session.error` |

### Pi Message Types → Opencode Part Mapping
| Pi message / block | Opencode `OpencodeMessagePart` representation |
|--------------------|----------------------------------------------|
| `UserMessage` | `message.info.role='user'` + `type='text'` part (plus `type='file'` parts for images) |
| `AssistantMessage.content[].type='text'` | `type='text'` part |
| `AssistantMessage.content[].type='thinking'` | `type='reasoning'` part |
| `AssistantMessage.content[].type='toolCall'` | `type='tool'` part with `state.status='pending'` |
| `ToolResultMessage` | `type='tool'` part with `state.status='completed'`, `state.output`, `state.error` |
| `BashExecutionMessage` | `type='tool'` part with `tool='bash'` (or synthetic) |

### Pi Tool State → Opencode `MessagePartState`
Pi tool events carry:
- `toolCallId`, `toolName`, `args` → map to `part.id`, `part.tool`, `part.state.input`
- `partialResult.content[].text` → `part.state.output` (accumulated)
- `result.content[].text`, `isError` → `part.state.output`, `part.state.error`, `part.state.status='completed'` or `'failed'`
- Timing: pi does not stream tool start/end timestamps in events; we may need to record them client-side.

## Work Packages

### 1. Pi Server Process Manager (`lua/opencode/pi/server.lua`)
**New file.** Wraps the `pi` subprocess.

- **Spawn**: `vim.system({'pi', '--mode', 'rpc', ...}, {stdin='pipe', stdout=..., stderr=...})`
- **Write loop**: queue JSONL commands to stdin, each terminated with `\n`
- **Read loop**: buffer stdout, split on `\n` only (not generic line readers — pi warns about `U+2028`/`U+2029`), parse JSON
- **Demux**: distinguish `type='response'` from event types; correlate responses with command `id`
- **Lifecycle**: handle process crash / unexpected exit; surface to user
- **Config integration**: accept `config.pi_executable`, `config.pi_args` (provider, model, no-session, session-dir, etc.)

**Complexity**: Medium. Need robust JSONL parsing, request/response correlation, and stderr logging.

### 2. Pi API Client (`lua/opencode/pi/api_client.lua`)
**New file.** Implements the same surface area as `OpencodeApiClient` but translates to pi commands.

Because pi is session-centric (one RPC process ≈ one active session), many opencode session APIs need to be emulated or simplified.

| Opencode API | Pi Implementation Strategy |
|-------------|---------------------------|
| `create_message(session_id, params)` | Send `prompt` command with `params.parts` converted to text + images. If streaming, queue with `steer` or reject. |
| `abort_session(id)` | Send `abort` command. |
| `list_sessions()` | **Hard**: pi stores sessions as files on disk. We can scan `session-dir` for `*.jsonl` and build synthetic `Session[]`. Or we can support only a single active session when using pi. |
| `create_session(data)` | Send `new_session`. If `parentID` given, maybe `fork` or `clone`. |
| `get_session(id)` | Send `get_state` and build synthetic `Session`. |
| `get_messages(id)` | Send `get_messages` and convert `AgentMessage[]` → `OpencodeMessage[]`. |
| `list_providers()` | Send `get_available_models` and group by provider. |
| `update_config()` | **Not supported** by pi RPC; no-op or store locally. |
| `run_shell(id, shell_data)` | Send `bash` command. Note: pi `bash` does not emit an event; the result is only included in the next prompt. We may need to synthesize a part or skip. |
| `revert_message()` / `fork_session()` | Use pi `fork`, `clone`, `switch_session`. |
| `subscribe_to_events()` | **Not HTTP SSE**. Instead, the pi server process pushes all events to a callback. The client simply registers a listener on the server process. |

**Key decision**: Do we try to make pi look like a full opencode server (sessions, projects, providers), or do we branch the UI to handle a simpler pi-only mode?

**Recommendation**: Start with a **single-session pi mode** where:
- Session list/fork/clone are either disabled in the UI or backed by pi’s file-based sessions.
- The `active_session` is always the one attached to the current pi process.
- `session_id` becomes the pi `sessionId` from `get_state`.

**Complexity**: High. Requires building a compatibility shim over a protocol with different semantics.

### 3. Event Translation / Adapter (`lua/opencode/pi/event_adapter.lua`)
**New file.** Converts pi stdout events into opencode events and feeds them into the existing `EventManager`.

Responsibilities:
1. **Accumulate streaming assistant messages**:
   - On `message_start`: create a new `OpencodeMessage` skeleton with `info.role='assistant'`.
   - On `message_update` (`text_start`/`text_delta`/`text_end`): maintain a `text` buffer, emit `message.part.delta` (or `message.part.updated`) for a synthetic `type='text'` part.
   - On `message_update` (`thinking_start`/`thinking_delta`/`thinking_end`): same but `type='reasoning'`.
   - On `message_update` (`toolcall_start`/`toolcall_delta`/`toolcall_end`): create `type='tool'` part, populate `part.state.input` with the accumulating arguments.
   - On `message_update` (`done`/`error`): finalize message metadata (`stopReason`, `usage`, `model`, `provider`).

2. **Tool execution mapping**:
   - `tool_execution_start` → create/update `type='tool'` part, `state.status='running'`, `state.time.start=now()`.
   - `tool_execution_update` → update `part.state.output` with `partialResult.content`.
   - `tool_execution_end` → set `part.state.status = isError and 'failed' or 'completed'`, `state.time.end=now()`.

3. **User message mapping**:
   - After sending a `prompt` and receiving the `response`, we should synthesize a `message.updated` event for the user message so it appears in the output window.
   - Alternatively, call `get_messages` after `agent_end` and diff.

4. **Session lifecycle**:
   - `agent_start` → emit `session.status` `{type='running'}`.
   - `agent_end` → emit `session.idle`.
   - `compaction_start` / `compaction_end` → emit `session.compacted`.

5. **Extension UI protocol**:
   - `extension_ui_request` with `method='confirm'` or `select'` → map to opencode’s `permission.asked` event (blocking user decision required).
   - `extension_ui_request` with `method='input'` or `'editor'` → could use `vim.ui.input` or open a temp buffer; need to send `extension_ui_response` back on stdin.
   - `extension_ui_request` with `method='notify'` → `vim.notify`.
   - `extension_ui_request` with `method='setStatus'` / `setWidget'` / `setTitle'` / `set_editor_text'` → map to opencode footer, widgets, input window prefill.

**Complexity**: High. This is the heart of the integration. Must correctly reconstruct opencode’s part-centric model from pi’s delta-centric stream.

### 4. Message Format Converter (`lua/opencode/pi/message_converter.lua`)
**New file.** Bidirectional conversion between pi message types and opencode types.

- `pi_agent_message_to_opencode(agentMsg) -> OpencodeMessage`
  - Handles `UserMessage`, `AssistantMessage`, `ToolResultMessage`, `BashExecutionMessage`
- `opencode_parts_to_pi_prompt(parts) -> { message: string, images: ImageContent[] }`
  - Collapses text parts into the prompt string.
  - Extracts image attachments into pi’s `ImageContent` format.
  - Context parts (files, selections, diagnostics) need to be inlined into the prompt text or dropped.
- `pi_content_blocks_to_opencode_parts(contentBlocks, messageId, sessionId) -> OpencodeMessagePart[]`
  - Maps `text` → `type='text'`, `thinking` → `type='reasoning'`, `toolCall` → `type='tool'`.

**Complexity**: Medium. Mostly data transformation, but edge cases around multi-modal content and context inlining.

### 5. UI / Formatter Compatibility
The good news: the output window and renderer are largely agnostic to the backend **as long as the event types and part shapes are correct**.

**Minimal changes expected**:
- `ui/formatter/tools/init.lua` may need to recognize additional pi tool names if they differ from opencode’s (pi seems to use similar names: `bash`, `read`, `edit`, `write`, etc.).
- Tool metadata shapes may differ slightly; the formatter `tool_formatters[tool]` dispatch needs to handle pi-specific metadata.
- `permission_window.lua` and `question_window.lua` may need minor adjustments if pi extension UI requests have different shapes than opencode permissions.

**Complexity**: Low to Medium. Mostly testing and small tweaks.

### 6. Input / Context Adaptation
- `services/messaging.lua` currently calls `api_client:create_message()`. If using pi, it should call the pi API client instead.
- **Context inlining**: pi’s `prompt` command does not accept arbitrary context parts (file contents, selections, diagnostics) as structured attachments. We need to prepend context to the prompt string before sending.
  - `context.format_message(prompt, context_config)` currently returns `OpencodeMessagePart[]`.
  - For pi mode, we need a `format_message_for_pi(prompt, context)` that returns a single string with context inlined (e.g., "Here is the current file:\n```\n...\n```\n\nUser prompt here").
- **Image attachments**: pi supports images via base64. We can map opencode image parts to pi’s `images` array.

**Complexity**: Medium. Requires a new context formatter for pi mode.

### 7. Configuration & Bootstrapping
- Add `pi` section to `config.lua`:
  ```lua
  pi = {
    executable = 'pi',
    args = {}, -- e.g. {'--provider', 'anthropic', '--model', 'claude-sonnet-4'}
    enabled = false, -- toggle between opencode and pi mode
  }
  ```
- In `init.lua`, branch server setup based on `config.pi.enabled`:
  - If `pi.enabled`, spawn `PiServer` instead of `OpencodeServer`.
  - Set `state.api_client` to `PiApiClient` instead of `OpencodeApiClient`.
  - Start the pi event adapter instead of the HTTP SSE subscription.

**Complexity**: Low.

### 8. Session Management Simplification (for v1)
Pi’s RPC protocol is designed around a single active session per process. To avoid rebuilding half of pi’s session logic inside the plugin, **v1 should**:
- Disable or simplify the session picker when in pi mode.
- Use `new_session` to create a session on first open.
- Use `get_state` to read the current session id/name.
- Support `fork` for branching (pi has this natively).
- Store the session file path; `switch_session` can load a different `.jsonl`.
- **Do not** try to emulate opencode’s multi-project session storage in the first pass.

**Complexity**: Medium (mostly UI gating).

## High-Level Data Flow (Pi Mode)

```
User types prompt → Input Window
         ↓
  services/messaging.send_message()
         ↓
  PiApiClient:create_message()
    - Inline context into prompt string
    - Convert image parts to pi ImageContent
    - Send {"type":"prompt","message":"...","images":[...]} to pi stdin
         ↓
  PiServer stdout JSONL
    - Demux responses vs events
         ↓
  PiEventAdapter
    - Accumulate deltas into OpencodeMessagePart objects
    - Emit opencode events (message.updated, message.part.updated, session.idle, etc.)
         ↓
  EventManager (existing)
    - Throttle, collapse, normalize deltas
         ↓
  Renderer / Events (existing)
    - Update state.messages, mark parts dirty
         ↓
  Flush (existing)
    - Format via ui/formatter.lua → Output buffer
```

## Risks & Open Questions

1. **Session mismatch** (highest risk)
   - opencode.nvim’s UI expects to list, rename, delete, and switch between multiple sessions via REST APIs.
   - pi RPC has no `list_sessions` command. We’d need to scan the filesystem or limit the UI.
   - **Mitigation**: v1 supports only one active session at a time; session picker is disabled or file-based.

2. **Context loss**
   - opencode’s rich context (diagnostics, cursor data, git diff, file mentions) is sent as structured `OpencodeMessagePart`s.
   - pi only accepts a text string + images in `prompt`.
   - **Mitigation**: Build a text-based context inserter that renders context as markdown/text before the user prompt.

3. **Tool output parity**
   - opencode tool parts have rich metadata (diffs, file types, match counts, HTTP status).
   - pi tool results are mostly text blocks.
   - **Mitigation**: Generic text rendering for pi tools; enhance later if pi exposes more metadata.

4. **Permission / Extension UI impedance mismatch**
   - opencode permissions are tied to tool call IDs and have `allow`/`deny`/`always` semantics.
   - pi extension UI `confirm`/`select` are generic and return arbitrary values.
   - **Mitigation**: Treat pi extension UI requests as a new event type (`pi.extension_ui_request`) with its own handler. For `confirm` that looks like a permission, map it to the permission window.

5. **Abort / Cancel behavior**
   - opencode `abort_session` is per-session HTTP POST.
   - pi `abort` is global to the process.
   - **Mitigation**: Pi mode abort is simpler; just send `abort`.

6. **Model / Provider configuration**
   - opencode lets users switch models via REST and has a provider/model picker.
   - pi models are set at startup (`--provider`, `--model`) or via `set_model` / `cycle_model` commands.
   - **Mitigation**: Support `set_model` via pi commands; disable provider picker or make it issue `set_model`.

## Recommended Implementation Order

1. **PiServer process wrapper** — spawn pi, JSONL read/write, basic command/response correlation.
2. **PiApiClient skeleton** — implement `prompt`, `abort`, `new_session`, `get_state`, `get_messages`. Ignore session listing for now.
3. **Message converter** — `pi_to_opencode` and `opencode_to_pi` message transforms.
4. **Event adapter (minimal)** — handle `message_update` (text only) and `agent_end` to get basic streaming working.
5. **Config + bootstrap branching** — `pi.enabled` flag, wire up pi client in `init.lua`.
6. **Input window integration** — inline context, send prompt via pi client.
7. **Event adapter (tools)** — add `tool_execution_*` event handling.
8. **Event adapter (extension UI)** — handle `confirm`/`select`/`notify`/`set_editor_text`.
9. **Session management simplification** — file-based session switching, fork support.
10. **Polish** — model switching, permission parity, formatter tweaks, tests.

## Files to Create

| File | Purpose |
|------|---------|
| `lua/opencode/pi/server.lua` | Subprocess management, JSONL I/O |
| `lua/opencode/pi/api_client.lua` | Pi command API surface |
| `lua/opencode/pi/event_adapter.lua` | Pi event → opencode event translation |
| `lua/opencode/pi/message_converter.lua` | Bidirectional message type conversion |
| `lua/opencode/pi/context_formatter.lua` | Inline context into pi prompt string |
| `tests/unit/pi_server_spec.lua` | JSONL parsing, command/response correlation |
| `tests/unit/pi_event_adapter_spec.lua` | Event translation tests |
| `tests/unit/pi_message_converter_spec.lua` | Converter unit tests |

## Files to Modify

| File | Change |
|------|--------|
| `lua/opencode/config.lua` | Add `pi` config section |
| `lua/opencode/init.lua` | Branch server/client initialization on `config.pi.enabled` |
| `lua/opencode/server_job.lua` | Optionally delegate to pi server instead of opencode server |
| `lua/opencode/services/messaging.lua` | Use pi client when in pi mode |
| `lua/opencode/context.lua` or new formatter | Inline context for pi prompts |
| `lua/opencode/ui/formatter/tools/init.lua` | Add any missing pi tool formatters |
| `lua/opencode/event_manager.lua` | Accept events from pi adapter (already decoupled via `emit()`) |

## Effort Estimate

| Work Package | Effort |
|-------------|--------|
| PiServer (subprocess + JSONL) | 1–2 days |
| PiApiClient (command mapping) | 2–3 days |
| Message Converter | 1 day |
| Event Adapter (streaming + tools) | 3–5 days |
| Context inlining / Input adaptation | 1–2 days |
| Extension UI handling | 1–2 days |
| Session mgmt simplification | 1–2 days |
| Config, bootstrap, polish, tests | 2–3 days |
| **Total** | **~12–20 days** |

The main unknown is how much of opencode.nvim’s feature surface (session picker, timeline, diff revert, sharing, MCP) you want to preserve in pi mode. If the scope is strictly **chat UI (input + output) with basic streaming and tool display**, the lower end (~12 days) is realistic. If you want full feature parity, the upper end grows significantly due to session and permission model mismatches.
