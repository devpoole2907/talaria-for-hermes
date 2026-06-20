# Talaria — Implementation Plan (for Sonnet)

> Authoritative build spec for **Talaria**, a native iOS SwiftUI client for the **Hermes Agent API Server**.
> This plan supersedes `talaria-rebuild-prompt.md` wherever they conflict — it was written *after* probing the **live Hermes server** at `http://forge.local:8642`, so the API shapes here are empirical, not guessed.
> Read `talaria-rebuild-prompt.md` for intent/style and `hermes-api-reference.md` for prose docs, but trust **this file** for endpoint/SSE/model shapes.

---

## 0. TL;DR of What Changed After Hitting the Real Server

The rebuild prompt made educated guesses. Live probing corrected several of them. **These corrections are the most important part of this plan — do not revert to the prompt's shapes.**

1. **Hermes messages are flat OpenAI-style objects, NOT OpenCode "parts".** A message is `{id, session_id, role, content, tool_calls, tool_call_id, tool_name, reasoning, ...}`. There is no `parts` array, no `Part` enum, no `TextPart`/`ToolPart`/`MessagePartDelta`. Throw out Anvil's entire `Models/Part*.swift` mental model.

2. **Primary transport is `POST /api/sessions/{id}/chat/stream`, NOT the Runs API.** The prompt said "Runs API primary." Reality: the session chat/stream endpoint is strictly richer for our use case — it is session-bound (so it shows up in the session list the whole UI is built around), and in **one** streaming POST it emits text deltas, tool calls **with arguments**, thinking deltas, AND a complete final `messages` array including tool outputs. The Runs `events` stream omits tool arguments and tool outputs. We still use Runs control endpoints (`/stop`, `/approval`) keyed by the `run_id` that the chat/stream emits. See §4 for the full rationale.

3. **Two distinct SSE wire formats.** Session chat/stream uses named SSE events (`event: tool.started\ndata: {...}`). Chat Completions uses standard OpenAI `data: {chat.completion.chunk}` lines. The Runs events stream is a third format (event name *inside* the JSON as `"event": "..."`). The parser must handle named-event SSE and OpenAI-chunk SSE. (Runs-events format documented in §4.4 but not required for v1.)

4. **Tool names are arbitrary and MCP-prefixed** (e.g. `mcp_ssh_manager_ssh_execute`, `execute_code`, `web_search`). This *confirms* the prompt's "generic tool view only" rule — there is no fixed tool vocabulary. Even the documented `terminal` tool was absent on this server; the agent fell back to other tools. Never hard-code tool names.

5. **The Xcode project uses file-system-synchronized groups.** Any `.swift` file placed inside the `Talaria for Hermes/` folder is auto-compiled — **no `project.pbxproj` editing required.** Just create files in the right subfolders.

6. **Snake_case everywhere.** All Hermes JSON keys are snake_case (`session_id`, `tool_calls`, `input_tokens`). Use a single `JSONDecoder` with `.convertFromSnakeCase` (and matching encoder `.convertToSnakeCase`), or explicit `CodingKeys`. Pick `.convertFromSnakeCase` globally for less boilerplate; override per-type only where it collides.

7. **`id` types differ by resource.** Session `id` is a `String` (`"api_1781926357_4f06397d"`). Message `id` is an **`Int`** (`8530`) when read from history, and **absent** in streamed `run.completed` messages. Model this carefully (see §3).

---

## 1. Project Setup (do this first)

The repo currently contains a stock SwiftData Xcode template (`Item.swift`, `ContentView.swift`, `Talaria_for_HermesApp.swift`). Convert it:

1. **Delete** `Item.swift` and `ContentView.swift`.
2. **Replace** `Talaria_for_HermesApp.swift` with the new `App/TalariaApp.swift` entry point (you may keep the filename `Talaria_for_HermesApp.swift` if renaming the `@main` type is awkward in the synchronized group — the *type* should be `TalariaApp`; filename is cosmetic. Simplest: create `App/TalariaApp.swift` with `@main struct TalariaApp`, and delete the old app file).
3. Remove **all** SwiftData usage (`import SwiftData`, `@Model`, `ModelContainer`, `@Query`). The prompt forbids SwiftData/CoreData.
4. Build settings to change in `Talaria for Hermes.xcodeproj/project.pbxproj` (these *do* require pbxproj edits — they're the only ones):
   - `SWIFT_VERSION = 6.0` (was 5.0). Enable strict concurrency (`SWIFT_STRICT_CONCURRENCY = complete` if not implied by Swift 6 language mode).
   - `PRODUCT_BUNDLE_IDENTIFIER = ai.talaria.client.ios` (was `com.poole.james.Talaria-for-Hermes`), both Debug & Release.
   - `IPHONEOS_DEPLOYMENT_TARGET` — make consistent. The project currently mixes `27.0` and `26.2`. The installed SDK is iOS 27. Set all to `26.2` (prompt's stated minimum) unless that fails to build against the 27 SDK, in which case use `26.2` for the app target and leave test target matching.
5. **All new source files live under `Talaria for Hermes/<Subfolder>/`** (the synchronized root group). Mirror the structure in §2. Because the group is synchronized, no manual target membership wiring is needed.
6. Keep `Assets.xcassets`. Set the accent color to a warm gold/amber (Hermes theme) in `AccentColor.colorset`. App icon: leave the placeholder (winged-sandal asset is out of scope), but don't break the build.

**Verify the build compiles after setup, before writing features.**

---

## 2. Target File Structure

All paths are relative to `Talaria for Hermes/`. One type per file. `#Preview` not `PreviewProvider`.

```
App/
  TalariaApp.swift            // @main, owns AppModel, RootView
  RootView.swift              // routes: no-profile → Setup; profile → LoadedRootView
  LoadedRootView.swift        // NavigationStack: session list root
  LaunchScreenView.swift
  AppModel.swift              // @MainActor @Observable; owns client + stores; start()
API/
  HTTPMethod.swift            // copy from Anvil verbatim
  HermesError.swift           // adapt from Anvil OpencodeError (rename, drop Basic-auth cases)
  HermesClient.swift          // actor; all REST + stream factory methods
Realtime/
  SSEAccumulator.swift        // line→(event,data) accumulator (extracted from Anvil EventStream)
  HermesEventStream.swift     // builds AsyncThrowingStream<HermesStreamEvent> for chat/stream
  ChatCompletionStream.swift  // builds AsyncThrowingStream<String> for /v1/chat/completions fallback
Models/
  AnyCodable.swift            // copy from Anvil verbatim
  HealthInfo.swift
  Capabilities.swift
  ModelInfo.swift
  SkillInfo.swift
  ToolsetInfo.swift
  Session.swift               // + SessionListResponse, SessionEnvelope wrappers
  HermesMessage.swift         // wire message (flat OpenAI-style)
  WireToolCall.swift          // tool_calls[] element on a message
  MessageListResponse.swift
  TokenUsage.swift
  RunHandle.swift             // {run_id, status} from POST /v1/runs and run.started
  HermesStreamEvent.swift     // decoded SSE event enum for chat/stream
State/
  SessionStore.swift          // session list + CRUD
  ChatStore.swift             // one per open session; sends + applies stream events
  ModelStore.swift            // /v1/models (usually one entry)
Storage/
  ServerProfile.swift         // {id, name, url, apiKey} — NO username/password
  ServerProfileStore.swift    // Keychain CRUD (adapt Anvil; new service id)
  AppPreferences.swift        // UserDefaults: activeProfileID, sessionKey, etc.
Features/
  Setup/
    SetupView.swift           // name, URL, API key, Test Connection
    SetupModel.swift
    SetupTestStatusRow.swift  // adapt from Anvil
  Profiles/
    ServerProfilePickerSheet.swift
    ServerProfileRow.swift
    AddProfileSheet.swift
  Sessions/
    SessionListView.swift
    SessionRowView.swift
    EmptySessionListView.swift
  Chat/
    ChatView.swift
    ChatToolbar.swift
    ChatComposer.swift        // text input + send/stop
    Messages/
      MessageTimelineView.swift
      TurnView.swift
      UserMessageView.swift
      AssistantMessageView.swift
      ThinkingIndicatorView.swift
  Tools/
    ToolCallView.swift        // generic expandable tool card
    ToolStatusIndicator.swift // pending/running/completed/error
    ToolEmojiMap.swift        // name→emoji/SFSymbol heuristic
  Models/
    ModelPickerSheet.swift
  Settings/
    SettingsView.swift
    ProfileEditView.swift
Shared/
  DesignTokens.swift          // copy from Anvil; add toolRunning/toolComplete colors
  MarkdownText.swift          // copy from Anvil
  CopyButton.swift            // copy from Anvil
  ShimmerView.swift           // copy from Anvil
  CollapsibleSection.swift    // copy from Anvil
  ContentUnavailableViews.swift
  DateFormatting.swift
  HapticFeedback.swift
  EnvironmentKeys.swift       // @Entry-based environment values
Tests/                        // (test target)
  HermesCodingTests.swift     // Codable round-trips for every wire model
  SSEParsingTests.swift       // chat/stream + chat-completion chunk parsing
  EndpointBuilderTests.swift  // URL building incl. session ids with slashes
```

Files you should **copy almost verbatim from Anvil** (`/Users/jamespoole/Documents/Anvil for OpenCode/`): `API/HTTPMethod.swift`, `Models/AnyCodable.swift`, `Shared/DesignTokens.swift`, `Shared/MarkdownText.swift`, `Shared/CopyButton.swift`, `Shared/ShimmerView.swift`, `Shared/CollapsibleSection.swift`, `Shared/ContentUnavailableViews.swift`, `Shared/DateFormatting.swift`, `Shared/HapticFeedback.swift`, `Shared/EnvironmentKeys.swift`. Read each before copying; strip OpenCode-specific bits.

Files to **adapt** from Anvil patterns: `Storage/ServerProfileStore.swift` (change `service` to `ai.talaria.client.ios`), `Features/Setup/*`, `Features/Profiles/*`, `Features/Sessions/*`, `Features/Chat/ChatComposer.swift`, `Features/Chat/Messages/*` structure, `Features/Models/ModelPickerSheet.swift`.

Do **NOT** port: anything under `Features/Parts/`, `Features/Parts/Tools/`, `Features/Diff/`, `Features/Projects/`, `Models/Part*.swift`, `Models/*Part.swift`, `Models/ServerEvent.swift`, `Models/Permission.swift`, `Models/Project.swift`, `Models/Provider*.swift`, `State/ProjectStore.swift`, `State/ProviderStore.swift`, `State/PermissionStore.swift`, `Realtime/DeltaApplier.swift`, `API/BasicAuth.swift`.

---

## 3. Data Models (empirical — exact wire shapes)

Use one shared decoder/encoder configured with `.convertFromSnakeCase` / `.convertToSnakeCase`. All structs `Codable, Sendable`; add `Hashable, Identifiable` where used in lists/navigation.

### 3.1 Health — `GET /health`
```json
{"status": "ok", "platform": "hermes-agent", "version": "0.16.0"}
```
```swift
struct HealthInfo: Codable, Sendable {
    let status: String
    let platform: String?
    let version: String?
}
```

### 3.2 Capabilities — `GET /v1/capabilities`
Real payload is larger than the prompt claimed; keys are snake_case and there are nested `runtime`, `features` (≈25 bools), and `endpoints` maps. Decode defensively — only the fields you use should be required; make the rest optional. **Drive transport selection from `features`.**
```json
{
  "object": "hermes.api_server.capabilities",
  "platform": "hermes-agent",
  "model": "hermes-agent",
  "auth": {"type": "bearer", "required": true},
  "features": {
    "chat_completions": true, "chat_completions_streaming": true,
    "responses_api": true, "responses_streaming": true,
    "run_submission": true, "run_status": true, "run_events_sse": true,
    "run_stop": true, "run_approval_response": true,
    "tool_progress_events": true, "approval_events": true,
    "session_resources": true, "session_chat": true, "session_chat_streaming": true,
    "session_fork": true, "skills_api": true,
    "session_key_header": "X-Hermes-Session-Key", "cors": false
  }
}
```
```swift
struct Capabilities: Codable, Sendable {
    let object: String?
    let platform: String?
    let model: String?
    let auth: Auth?
    let features: Features?

    struct Auth: Codable, Sendable { let type: String?; let required: Bool? }

    struct Features: Codable, Sendable {
        // Decode the subset Talaria branches on; everything optional.
        let chatCompletions: Bool?
        let chatCompletionsStreaming: Bool?
        let sessionChat: Bool?
        let sessionChatStreaming: Bool?
        let runSubmission: Bool?
        let runStop: Bool?
        let runApprovalResponse: Bool?
        let approvalEvents: Bool?
        let toolProgressEvents: Bool?
    }
}
```

### 3.3 Models — `GET /v1/models`
```json
{"object": "list", "data": [{"id": "hermes-agent", "object": "model", "created": 1781926274, "owned_by": "hermes", "root": "hermes-agent", "parent": null, "permission": []}]}
```
```swift
struct ModelListResponse: Codable, Sendable { let data: [ModelInfo] }
struct ModelInfo: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let object: String?
    let ownedBy: String?
}
```
Note: usually exactly one model. Model picker exists but is mostly cosmetic (the `model` request field is ignored server-side). Keep it minimal.

### 3.4 Session — `GET /api/sessions`, `POST /api/sessions`
List response is paginated; create response wraps the session under `session`.
```json
// GET /api/sessions?limit=&offset=&source=&include_children=
{"object":"list","data":[ {Session...} ],"limit":3,"offset":0,"has_more":true}
// POST /api/sessions  body {"title":"..."}  (title optional)
{"object":"hermes.session","session":{Session...}}
// DELETE /api/sessions/{id} → {"object":"hermes.session.deleted","id":"...","deleted":true}
```
A `Session` object (snake_case):
```json
{"id":"api_1781926357_4f06397d","source":"api_server","user_id":null,"model":"hermes-agent",
 "title":"Talaria probe","started_at":1781926357.39,"ended_at":null,"end_reason":null,
 "message_count":0,"tool_call_count":0,"input_tokens":0,"output_tokens":0,
 "cache_read_tokens":0,"cache_write_tokens":0,"reasoning_tokens":0,
 "estimated_cost_usd":null,"actual_cost_usd":null,"api_call_count":0,
 "parent_session_id":null,"last_active":1781926158.05,"preview":"hey sir...",
 "has_system_prompt":true,"has_model_config":true}
```
```swift
struct Session: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var title: String?
    let source: String?
    let model: String?
    let startedAt: Double?
    let lastActive: Double?
    let messageCount: Int?
    let toolCallCount: Int?
    let preview: String?
    let parentSessionID: String?
    let inputTokens: Int?
    let outputTokens: Int?
    // add the rest as optional if you display them; otherwise omit (decoder ignores extras)

    var displayTitle: String { title?.nilIfBlank ?? preview?.nilIfBlank ?? "Untitled session" }
    var lastActiveDate: Date? { lastActive.map { Date(timeIntervalSince1970: $0) } }
}
struct SessionListResponse: Codable, Sendable {
    let data: [Session]; let limit: Int?; let offset: Int?; let hasMore: Bool?
}
struct SessionEnvelope: Codable, Sendable { let session: Session }
```
**PATCH** `/api/sessions/{id}` body `{"title":"..."}` (also accepts `end_reason`). Returns the updated session (likely wrapped like create — decode tolerantly: try `SessionEnvelope` then bare `Session`).

### 3.5 Message — `GET /api/sessions/{id}/messages` and `run.completed.messages[]`
Flat OpenAI-style. Same shape in history and in the stream's final array, except history has integer `id` + `timestamp`; streamed final messages omit `id`.
```json
// user
{"id":8530,"session_id":"...","role":"user","content":"Run ...","tool_call_id":null,"tool_calls":null,"tool_name":null,"timestamp":1781926.0,"finish_reason":null,"reasoning":null,"reasoning_content":null}
// assistant making tool calls (content may be "" or have text)
{"id":8555,"role":"assistant","content":"","tool_calls":[
  {"id":"call_00_Q9..","call_id":"call_00_Q9..","response_item_id":"fc_00_Q9..","type":"function",
   "function":{"name":"execute_code","arguments":"{\"code\": \"print(6 * 7)\"}"}}],
 "finish_reason":"tool_calls","reasoning":"...","reasoning_content":"..."}
// tool result (matches assistant tool_call by tool_call_id)
{"id":8556,"role":"tool","content":"{\"status\": \"success\", \"output\": \"42\\n\", ...}","tool_call_id":"call_00_Q9..","tool_name":"execute_code"}
// assistant final
{"id":8557,"role":"assistant","content":"`6 * 7 = 42`","finish_reason":"stop"}
```
```swift
struct HermesMessage: Codable, Hashable, Sendable, Identifiable {
    let id: Int?                 // present in history, nil when streamed
    let sessionID: String?
    let role: String             // "user" | "assistant" | "tool" | "system"
    let content: String?         // may be "" or nil
    let toolCalls: [WireToolCall]?
    let toolCallID: String?      // set on role=="tool"
    let toolName: String?        // set on role=="tool" (sometimes nil → fall back to matching tool_call)
    let timestamp: Double?
    let finishReason: String?
    let reasoning: String?
    let reasoningContent: String?

    // Stable identity for SwiftUI even when wire id is nil (use a local UUID assigned on insert).
}
```
> **Identity caveat:** because streamed messages have `id == nil`, `ChatStore` must assign each message a stable local identity (a `UUID` generated when first appended) for `ForEach`. Wrap `HermesMessage` in a small `struct TimelineMessage: Identifiable { let localID = UUID(); var message: HermesMessage }` inside the store. Do NOT use array index as id.

`content` is a `String` in every case observed. Inline-image messages *could* theoretically be an array of parts, but image **output** never comes back that way and we don't send images in v1 — so model `content` as `String?`. If you want to be bulletproof, decode `content` via a small enum that accepts either `String` or `[ContentPart]` and flattens to text; optional for v1.

```swift
struct WireToolCall: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let callID: String?
    let type: String?            // "function"
    let function: Function
    struct Function: Codable, Hashable, Sendable {
        let name: String
        let arguments: String    // JSON-encoded string; parse lazily for display
    }
}
struct MessageListResponse: Codable, Sendable {
    let data: [HermesMessage]
}
```

### 3.6 Token usage
Appears as `{"input_tokens":N,"output_tokens":N,"total_tokens":N}` in runs/run.completed, and as `{"prompt_tokens","completion_tokens","total_tokens"}` in chat completions. Model both optionally:
```swift
struct TokenUsage: Codable, Hashable, Sendable {
    let inputTokens: Int?; let outputTokens: Int?; let totalTokens: Int?
    let promptTokens: Int?; let completionTokens: Int?
    var input: Int? { inputTokens ?? promptTokens }
    var output: Int? { outputTokens ?? completionTokens }
}
```

### 3.7 Skills / Toolsets (read-only, Settings display)
```json
// GET /v1/skills  → {"object":"list","data":[{"name":"...","description":"...","category":null}]}
// GET /v1/toolsets → {"object":"list","platform":"api_server","data":[
//   {"name":"file","label":"📁 File Operations","description":"...","enabled":true,"configured":true,"tools":["patch","read_file","search_files","write_file"]}]}
```
```swift
struct SkillInfo: Codable, Identifiable, Hashable, Sendable {
    var id: String { name }
    let name: String; let description: String?; let category: String?
}
struct ToolsetInfo: Codable, Identifiable, Hashable, Sendable {
    var id: String { name }
    let name: String; let label: String?; let description: String?
    let enabled: Bool?; let configured: Bool?; let tools: [String]?
}
struct ListResponse<T: Codable & Sendable>: Codable, Sendable { let data: [T] }
```

### 3.8 Run handle — `POST /v1/runs`
```json
{"run_id":"run_abc","status":"started"}
```
```swift
struct RunHandle: Codable, Sendable { let runID: String; let status: String? }
```
(`GET /v1/runs/{id}` status object also exists — see §4.4 — but not needed for the primary v1 flow.)

---

## 4. Streaming & Transport (the core of the app)

### 4.1 Transport decision (read this)
**Primary: `POST /api/sessions/{id}/chat/stream`.** Chosen over the Runs API because, empirically, it is the only endpoint that in a single request:
- is bound to a persistent session (the session list is the app's home screen),
- streams assistant text deltas,
- streams `tool.started` **with `tool_name` + `args`** and `tool.completed`,
- streams thinking via `tool.progress` (`tool_name == "_thinking"`),
- and ends with `run.completed` carrying the **complete final `messages` array including tool outputs**.

The Runs `events` stream lacks tool args and tool outputs, and requires a 2-step POST-then-GET with a reconnect protocol that's overkill for v1. We still capture the `run_id` from the chat/stream `run.started` event so we can call the Runs control endpoints (`/stop`, `/approval`).

**Fallback: `POST /v1/chat/completions` (stream).** Stateless. Used only if `capabilities.features.sessionChatStreaming != true`. Send the full message history each time; render text deltas; no session persistence, degraded tool visibility.

Selection logic in `ChatStore` / `AppModel`:
```
if features.sessionChatStreaming == true  → session chat/stream (primary)
else if features.chatCompletionsStreaming == true → chat completions stream (fallback)
else → chat completions non-stream (last resort)
```
Default to primary when capabilities are unknown/unreachable (the probed server supports it).

### 4.2 Session chat/stream wire format — `POST /api/sessions/{id}/chat/stream`
Request body: `{"input": "user text"}`. Headers: `Authorization: Bearer`, `Accept: text/event-stream`, and `X-Hermes-Session-Key: <stable per-user id>`. Named SSE events, captured live:

```
event: run.started
data: {"user_message":{"role":"user","content":"..."},"session_id":"...","run_id":"run_..","seq":1,"ts":...}

event: message.started
data: {"message":{"id":"msg_..","role":"assistant"},"session_id":"...","run_id":"run_..","seq":2,"ts":...}

event: assistant.delta
data: {"message_id":"msg_..","delta":"hello","session_id":"...","run_id":"run_..","seq":3,"ts":...}

event: tool.started
data: {"message_id":"msg_..","tool_name":"execute_code","preview":"print(6 * 7)","args":{"code":"print(6 * 7)"},"session_id":"...","run_id":"run_..","seq":..,"ts":...}

event: tool.completed
data: {"message_id":"msg_..","tool_name":"execute_code","preview":null,"args":null,"session_id":"...","run_id":"run_..","seq":..,"ts":...}

event: tool.progress
data: {"message_id":"msg_..","tool_name":"_thinking","delta":"`6 * 7 = 42`","session_id":"...","run_id":"run_..","seq":..,"ts":...}

event: run.completed
data: {"session_id":"...","message_id":"msg_..","completed":true,
       "messages":[ {role:"assistant",content:"",tool_calls:[...]}, {role:"tool",content:"{...}",tool_call_id:"..",tool_name:".."}, {role:"assistant",content:"`6 * 7 = 42`",finish_reason:"stop"} ],
       "usage":{"input_tokens":..,"output_tokens":..,"total_tokens":..},"run_id":"run_..","seq":..,"ts":...}
```
Notes that matter for the store:
- `tool.completed` does **not** carry the output. Output arrives only in `run.completed.messages[]` (the `role:"tool"` entries). So: on `tool.started` create a running tool card (name+args); on `tool.completed` mark it completed (still no output); on `run.completed` reconcile against the authoritative `messages` array to fill outputs and final text. The `tool.completed` `error` semantics: in the *Runs* stream there's an `error` bool; in chat/stream infer error from the tool result content / `finish_reason`.
- `tool_name` on a result can be `null`; resolve the canonical name by matching `tool_call_id` to the assistant message's `tool_calls[].id`.
- Multiple assistant↔tool loops occur within one turn. Render strictly by arrival/array order.
- `run.completed.messages` is the source of truth — after it arrives, **replace** the turn's optimistic streamed content with these messages (assigning local IDs). This avoids drift between streamed deltas and final content.

### 4.3 `HermesStreamEvent` enum + parser
```swift
enum HermesStreamEvent: Sendable {
    case runStarted(runID: String)
    case messageStarted(messageID: String)
    case assistantDelta(messageID: String, text: String)
    case thinkingDelta(messageID: String, text: String)        // tool.progress, tool_name == "_thinking"
    case toolStarted(messageID: String, name: String, arguments: String?) // serialise args dict → JSON string
    case toolCompleted(messageID: String, name: String?)
    case toolProgress(messageID: String, name: String, text: String)      // non-thinking progress, if any
    case approvalRequired(runID: String, approvalID: String, prompt: String) // best-effort; see §4.5
    case runCompleted(messages: [HermesMessage], usage: TokenUsage?)
    case runFailed(error: String)
    case unknown(event: String)
}
```
Parser (`HermesEventStream`):
1. Reuse Anvil's SSE line accumulator (`SSEAccumulator`) but emit `(eventName: String?, data: String)` pairs on blank-line boundaries.
2. For each pair, switch on `eventName`; decode `data` into a small per-event Decodable; map to `HermesStreamEvent`.
3. For `tool.progress`: if `tool_name == "_thinking"` → `.thinkingDelta`, else `.toolProgress`.
4. `tool.started.args` is a JSON object — re-encode it to a compact JSON string for `arguments` (the UI parses/pretty-prints lazily). Keep `preview` as a fallback summary.
5. Unknown event names → `.unknown` (logged, ignored). Be tolerant: Hermes will add events.

Network plumbing: copy Anvil's `URLSession.bytes(for:)` + `for try await line in bytes.lines` pattern from `EventStream.swift`. This is a POST (set `httpMethod`, `httpBody`, `Content-Type: application/json`). Build it as a `nonisolated` factory on `HermesClient` returning `AsyncThrowingStream<HermesStreamEvent, Error>`, exactly like Anvil's `eventStream(directory:)`.

### 4.4 Chat Completions stream (fallback) — `POST /v1/chat/completions`
Standard OpenAI. Body `{"model":"hermes-agent","stream":true,"messages":[...]}`. Lines are `data: {chat.completion.chunk}` ending with `data: [DONE]`. Extract `choices[0].delta.content`. Captured:
```
data: {"id":"chatcmpl-..","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant"}}]}
data: {"id":"..","choices":[{"index":0,"delta":{"content":"hello"}}]}
data: {"id":"..","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{...}}
data: [DONE]
```
`ChatCompletionStream` → `AsyncThrowingStream<String, Error>` yielding content fragments. Also custom `event: hermes.tool.progress` events may appear — parse if event name present, else treat plain `data:` as chunk. For v1 the fallback can ignore tool progress and just stream text.

### 4.4b Runs API (reference only — NOT required for v1 chat)
`POST /v1/runs` `{input, session_id?, instructions?}` → `{run_id,status}`. `GET /v1/runs/{id}/events` SSE has the event name **inside** the JSON: `data: {"event":"tool.started","run_id":"..","tool":"mcp_..","preview":"..."}`, plus `reasoning.available` (full reasoning text), `tool.completed` (`{tool,duration,error}` — no output), and `run.completed` (`{output,usage}`). It ends with a `: stream closed` comment. We only use **`POST /v1/runs/{run_id}/stop`** and **`POST /v1/runs/{run_id}/approval`** in v1, keyed by the `run_id` from chat/stream's `run.started`.

### 4.5 Stop & Approval
- **Stop:** `POST /v1/runs/{run_id}/stop` → `{"status":"stopping"}`. ChatStore stores the current `run_id` (from `run.started`); the composer's Stop button calls it and cancels the local stream task.
- **Approval:** `POST /v1/runs/{run_id}/approval`, body carries the decision. The exact approval-request event shape on chat/stream was **not observed** (this server didn't gate any tool behind approval during probing). Implement defensively: if any event arrives whose name contains `approval` (or an `approval_id`/`prompt` field is present), surface a non-blocking sheet and POST the decision. Guard the whole feature behind `capabilities.features.approvalEvents == true` and `runApprovalResponse == true`. If shapes turn out different at runtime, the `.unknown` fallback keeps the app stable. Treat approval as best-effort polish, not a v1 blocker.

---

## 5. HermesClient (actor)

Mirror Anvil's `OpencodeClient` structure (generic `send`/`performRequest` helpers, status-code→error mapping) but Bearer auth and Hermes paths. No `directory` param anywhere.

```swift
actor HermesClient {
    init(baseURL: URL, apiKey: String, sessionKey: String)

    // Discovery
    func health() async throws -> HealthInfo                 // GET /health
    func capabilities() async throws -> Capabilities         // GET /v1/capabilities
    func models() async throws -> [ModelInfo]                // GET /v1/models
    func skills() async throws -> [SkillInfo]                // GET /v1/skills
    func toolsets() async throws -> [ToolsetInfo]            // GET /v1/toolsets

    // Sessions
    func listSessions(limit: Int, offset: Int) async throws -> SessionListResponse  // GET /api/sessions
    func createSession(title: String?) async throws -> Session                       // POST /api/sessions
    func getSession(id: String) async throws -> Session                              // GET /api/sessions/{id}
    func updateSession(id: String, title: String) async throws -> Session            // PATCH
    func deleteSession(id: String) async throws                                      // DELETE
    func messages(sessionID: String) async throws -> [HermesMessage]                 // GET .../messages

    // Streaming (nonisolated factories returning AsyncThrowingStream)
    nonisolated func sessionChatStream(sessionID: String, input: String) -> AsyncThrowingStream<HermesStreamEvent, Error>
    nonisolated func chatCompletionStream(messages: [HermesMessage], model: String) -> AsyncThrowingStream<String, Error>

    // Runs control
    func stopRun(runID: String) async throws                 // POST /v1/runs/{id}/stop
    func approveRun(runID: String, approvalID: String, decision: String) async throws // POST .../approval
}
```
Implementation notes:
- Single `URLSession` (non-stream config: 60s request / 600s resource). Streams build their own session with `timeoutIntervalForResource = .infinity` like Anvil.
- Every request sets `Authorization: Bearer <apiKey>` and `Accept: application/json` (streams: `text/event-stream`).
- Chat/run/stream requests additionally set `X-Hermes-Session-Key: <sessionKey>` (stable per install, see §6.3). Validate ≤256 chars, no control chars.
- URL building: `baseURL.appending(path:)`. Session ids contain no slashes but may contain underscores — fine. Add an `EndpointBuilderTests` case anyway.
- Status mapping (`HermesError`): 200–299 ok; 401/403 → `.unauthorized`; 404 → `.notFound`; 429 → `.rateLimited`; else `.httpStatus(code, body)`. Include `.decoding`, `.network`, `.cancelled`, `.invalidURL`.
- `baseURL` handling: the user enters `http://forge.local:8642` (no `/v1`). Store the **origin**; the client appends full paths (`/v1/...`, `/api/...`, `/health`). Do NOT bake `/v1` into the stored URL since `/api/...` and `/health` are siblings of `/v1`. If the user pastes a trailing `/v1`, strip it on save.

---

## 6. State Layer

### 6.1 SessionStore (`@MainActor @Observable`)
- `sessions: [Session]`, `loading`, `lastError`.
- `refresh()` → `listSessions(limit:50, offset:0)`, store `data`, sort by `lastActive`/`startedAt` desc. (Pagination optional v1; load first 50.)
- `create(title:)` → prepend, return Session.
- `rename(id:title:)`, `delete(id:)` → optimistic update + call client; on failure revert + set error.
- No SSE-driven updates here (Hermes has no global session event bus exposed to us). Refresh on appear / pull-to-refresh, and after a chat turn completes (`run.completed`) bump the row's `lastActive`/`message_count` locally or re-fetch that session.

### 6.2 ChatStore (`@MainActor @Observable`) — one per open session
State:
```
sessionID: String
timeline: [TimelineMessage]      // local-ID-wrapped HermesMessage history
streamingText: [String: String]  // messageID(msg_..) → accumulated assistant text (during stream)
streamingThinking: [String: String]
liveTools: [String: LiveTool]    // toolCallID/name → {name, args, status}
working: Bool
currentRunID: String?
loading, lastError
```
Behavior:
- `load()` → `client.messages(sessionID:)`; map to `timeline` (assign local IDs); `working = false`.
- `send(_ text:)`:
  1. Optimistically append a user `TimelineMessage`.
  2. `working = true`.
  3. Open `client.sessionChatStream(sessionID:input:)`; consume in a `Task` stored for cancellation.
  4. Apply events (see below).
  5. On `runCompleted`: replace the in-flight assistant/tool placeholders for this turn with the authoritative `messages` (assign local IDs), clear `streamingText`/`liveTools`, `working = false`, store usage. Notify `SessionStore` to refresh the row.
  6. On error/`runFailed`: set `lastError`, `working = false`.
- `apply(_ event: HermesStreamEvent)`:
  - `.runStarted(runID)` → `currentRunID = runID`.
  - `.messageStarted(id)` → ensure a placeholder assistant `TimelineMessage` keyed to `id`.
  - `.assistantDelta(id,text)` → append to `streamingText[id]`; reflect into that message's displayed content.
  - `.thinkingDelta(id,text)` → append to `streamingThinking[id]` (drives ThinkingIndicator / collapsible reasoning).
  - `.toolStarted(id,name,args)` → add/update a `LiveTool(status:.running)` shown under the active assistant message.
  - `.toolCompleted(id,name)` → mark that `LiveTool` `.completed` (output still unknown until run.completed).
  - `.runCompleted` → reconcile (see above).
  - `.unknown` → ignore.
- `stop()` → if `currentRunID`, `client.stopRun`; cancel local stream task; `working = false`.
- Transport fallback: if `sessionChatStreaming` unavailable, `send` uses `chatCompletionStream` with full `timeline` mapped to `{role,content}` (drop tool/system internals; send user+assistant text only) and appends a single streamed assistant message.

**Turn grouping for the UI** (replaces Anvil's `turns`): walk `timeline`; a `role=="user"` message opens a turn; subsequent `assistant`/`tool` messages belong to it until the next `user`. Within a turn, produce an ordered list of render items: assistant text bubbles, tool cards (assistant `tool_calls[]` joined with the matching `role=="tool"` result by `tool_call_id`), and reasoning. Provide this as a computed `var turns: [ChatTurn]` on the store (logic in the store, not the view).

### 6.3 AppPreferences (UserDefaults)
- `activeProfileID: UUID?`
- `hermesSessionKey: String` — generate once per install: `"talaria:user-\(UUID().uuidString)"`, persist, reuse for `X-Hermes-Session-Key` so long-term memory is stable across sessions. (Per `hermes-api-reference.md`: ≤256 chars, no control chars.)
- `defaultModelID(for profile:)` — optional; usually one model.

### 6.4 ModelStore — trivial: `models: [ModelInfo]`, `refresh()`. Usually one entry.

---

## 7. UI / Features

Follow every code-style rule in `talaria-rebuild-prompt.md` §5 (modern SwiftUI APIs, extracted subview structs, no `@ViewBuilder` computed vars, `NavigationStack` only, `sheet(item:)`, `#Preview`, design tokens, 44pt tap targets, `ContentUnavailableView`, `Label`, no `AnyView`, no force-unwrap). Liquid Glass: `.background(.regularMaterial)` / `.glassEffect()` where natural.

### 7.1 App entry & routing
- `TalariaApp` builds `AppModel` (loads profiles from Keychain + active profile id from prefs) and shows `RootView`.
- `RootView`: if no active profile → `SetupView`; else `LoadedRootView` and `.task { await appModel.start() }`.
- `LoadedRootView`: `NavigationStack { SessionListView }` with `navigationDestination(for: Session.self) { ChatView }`.
- `AppModel.start()`: `health()` → `capabilities()` (store; drives transport) → `models()` (ModelStore) → `sessionStore.refresh()`. On health failure set `startupError` and show a retry state. (No global event stream to start — unlike Anvil.)

### 7.2 Setup / Profiles
- `SetupView`: fields **name**, **URL** (`http://forge.local:8642`), **API key** (secure field). "Test Connection" → `SetupModel` builds a temp `HermesClient`, calls `health()` then `capabilities()`, shows `SetupTestStatusRow` per step (adapt Anvil). Save → Keychain via `ServerProfileStore`, set active, dismiss.
- Profiles picker/add/edit/row: adapt Anvil 1:1, swapping username/password for a single API-key secure field.

### 7.3 Sessions
- `SessionListView`: list of `SessionRowView` (title/preview, relative `lastActive`, message count, source badge). Swipe to delete; context menu rename; pull-to-refresh; "+" creates a session then navigates to `ChatView`. `EmptySessionListView` via `ContentUnavailableView` with a "New Session" action. Toolbar: profile switcher (`.topBarLeading`), new session + settings (`.topBarTrailing`).

### 7.4 Chat
- `ChatView`: owns the `ChatStore` (created by `AppModel.openChat(session)`); `.task { await store.load() }`. Body = `MessageTimelineView` + `ChatComposer`. Toolbar: title (editable rename), model picker, settings.
- `MessageTimelineView`: `ScrollView` + `LazyVStack` of `TurnView`, `.scrollIndicators(.hidden)`, auto-scroll to bottom on new content (use `ScrollViewReader` or `.defaultScrollAnchor(.bottom)`), `ThinkingIndicatorView` while `working` and no text yet.
- `TurnView`: `UserMessageView` then ordered assistant items: `AssistantMessageView` (markdown via `MarkdownText`) and `ToolCallView` cards, plus collapsible reasoning.
- `ChatComposer`: multiline text field + Send; flips to **Stop** while `working` (calls `store.stop()`). `sensoryFeedback` on send. Disable Send when empty/working. (No attachments in v1 — image upload is unsupported by the API; omit the attachment picker.)

### 7.5 Tools (generic — no per-tool views)
- `ToolCallView`: card with header `Label(toolName, systemImage: symbol)` + `ToolStatusIndicator`; expandable arguments (pretty-printed JSON from `WireToolCall.function.arguments` or live `args`, truncated when collapsed); expandable output (the matched `role=="tool"` message content, monospaced, collapsible via `CollapsibleSection`); optional duration. Strip the `<untrusted_tool_result source="..">` wrapper for display if present.
- `ToolStatusIndicator`: pending/running (spinner)/completed (checkmark, green)/error (xmark, red) using `Palette.toolPending/toolRunning/toolComplete/toolError`. Provide icon **and** color (accessibility: differentiate without color).
- `ToolEmojiMap`: heuristic name→SFSymbol (`terminal`/`ssh`→`terminal`, `read_file`/`write_file`/`patch`→`doc`, `search_files`→`magnifyingglass`, `web_search`→`globe`, `execute_code`→`chevron.left.forwardslash.chevron.right`, `browser_*`→`safari`, default→`wrench.and.screwdriver`). Keep it forgiving — names are MCP-prefixed and open-ended.

### 7.6 Models & Settings
- `ModelPickerSheet`: list `ModelStore.models` (usually one). Note in footer that the model is server-configured/cosmetic.
- `SettingsView`: active profile (edit), Hermes version/platform from `HealthInfo`, capabilities summary, read-only Skills and Toolsets lists (from `/v1/skills`, `/v1/toolsets`), app version. `ProfileEditView` to edit/delete profiles.

---

## 8. Design Tokens
Copy Anvil's `DesignTokens.swift`; add the two missing tool colors so all four states exist:
```swift
enum Palette {
    static let user: Color = .accentColor
    static let assistant: Color = .primary
    static let toolPending: Color = .orange
    static let toolRunning: Color = .blue
    static let toolComplete: Color = .green
    static let toolError: Color = .red
}
```
Keep `Spacing`, `Radii`, `AnimationDurations`, `TapTarget`. Accent color = warm gold/amber in the asset catalog.

---

## 9. Tests (test target)
- `HermesCodingTests`: round-trip/decode the captured JSON in §3 for `HealthInfo`, `Capabilities`, `Session`(+list+envelope), `HermesMessage`(user/assistant-with-tool_calls/tool/assistant-final), `WireToolCall`, `ModelInfo`, `SkillInfo`, `ToolsetInfo`, `TokenUsage`. Paste the exact bodies from this doc as fixtures.
- `SSEParsingTests`: feed the literal chat/stream byte sequences from §4.2 (run.started → … → run.completed) and assert the `HermesStreamEvent` sequence, including `_thinking` → `.thinkingDelta` and `run.completed` message extraction. Add chat-completion chunk parsing incl. `[DONE]`.
- `EndpointBuilderTests`: assert URLs for `/health`, `/v1/models`, `/api/sessions`, `/api/sessions/{id}/messages`, `/api/sessions/{id}/chat/stream`, `/v1/runs/{id}/stop` from base `http://forge.local:8642`, and that a trailing `/v1` in the stored URL is stripped.

---

## 10. Build Order (checklist)
1. **Project setup** (§1): strip SwiftData, fix bundle id / Swift 6 / deployment target, confirm empty app builds.
2. **Shared/** — copy tokens, markdown, copy button, shimmer, collapsible, content-unavailable, date, haptics, environment keys.
3. **Storage/** — `ServerProfile` (apiKey), `ServerProfileStore` (Keychain, new service id), `AppPreferences` (+ sessionKey generator).
4. **Models/** — all §3 types + `AnyCodable`. Write `HermesCodingTests` alongside; run them.
5. **API/** — `HTTPMethod`, `HermesError`, `HermesClient` (REST methods first). Smoke-test against `forge.local` manually if possible.
6. **Realtime/** — `SSEAccumulator`, `HermesEventStream` (chat/stream), `ChatCompletionStream`. Write `SSEParsingTests`; run them.
7. **State/** — `ModelStore`, `SessionStore`, `ChatStore` (apply/turn-grouping/stop/fallback).
8. **App/** — `AppModel` (start flow + openChat), `TalariaApp`, `RootView`, `LoadedRootView`, `LaunchScreenView`.
9. **Features/Setup + Profiles** — get to a state where you can add a profile and pass Test Connection.
10. **Features/Sessions** — list/create/rename/delete.
11. **Features/Chat + Tools** — timeline, composer, generic tool cards, streaming, stop.
12. **Features/Models + Settings** — pickers, skills/toolsets display.
13. Full build; run on simulator; manual end-to-end against the live server (create session → send "use execute_code to compute 6*7" → watch tool card + final text).

**Every file must compile — no stubs.** Prefer `if let x {`, `Date.now`, `Task.sleep(for:)`, `foregroundStyle`, `clipShape(.rect(cornerRadius:))`. `@Observable` classes are `@MainActor`. No `DispatchQueue`, no force-unwraps, no `AnyView`.

---

## 11. Live Server (for manual testing)
```
Base URL: http://forge.local:8642
API key:  <API_SERVER_KEY>   # set locally; do not commit real keys
Model:    hermes-agent
```
Health: `curl http://forge.local:8642/health`. All other calls need `Authorization: Bearer <key>`. **Create your own throwaway sessions for testing and delete them when done** — this server has real user sessions on it.

---

## 12. Explicit Non-Goals (v1)
Terminal panel, file tree, full config UI, web-results browser, iCloud, push, iPad layout, RAG/file upload (API doesn't support it), voice, multi-user. Responses API (`/v1/responses`) and Jobs API (`/api/jobs`) are out of scope — sessions + chat/stream cover v1. Approval UI is best-effort (§4.5).
