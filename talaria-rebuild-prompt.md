# Talaria — Rebuild Prompt for Claude Code

> Given to Claude Code pointing at the Talaria Xcode project directory.
> Source repo for reference: `https://github.com/devpoole2907/Anvil-for-OpenCode` (branch `perf-improvements`)

You are rebuilding the Anvil-for-OpenCode iOS app as **Talaria** — a native iOS 26.2 SwiftUI client for **Hermes Agent API Server** (not OpenCode Go).

---

## 1. What You're Starting From

The Anvil-for-OpenCode codebase at the path I'll give you is a working, well-structured Swift 6.2 / iOS 26 SwiftUI app. It connects to an OpenCode Go server over HTTP with Basic auth. Study it thoroughly — it's your template. You are NOT writing from scratch. You are refactoring, renaming, stripping, and replacing.

### What Anvil Has (Keep)
- `@MainActor @Observable` state architecture
- Pure SwiftUI, no third-party packages
- Keychain-backed server profile storage
- SSE streaming via `URLSession.bytes(for:)`
- Session list with create/delete/rename
- Chat view with turn-based message timeline
- Tool-call rendering with per-tool views
- Permission approval flow
- Diff rendering
- Model picker
- Design tokens (`DesignTokens.swift`)
- All code style rules from the PLAN.md
- Multi-profile server switching

### What Anvil Has (Strip Completely)
- Everything specific to the OpenCode wire protocol
- `API/OpencodeClient.swift` — all OpenCode REST endpoints
- `Models/ServerEvent.swift` — OpenCode SSE event types
- `Models/Part.swift` — OpenCode part types (text, reasoning, tool, compaction, file, agent)
- `Models/ToolPart.swift` — OpenCode tool state model
- `Models/Project.swift` / `State/ProjectStore.swift` — project concept doesn't exist in Hermes
- `Models/Permission.swift` — Hermes has a different approval model
- `Models/ProviderInfo.swift` / `Models/Provider.swift` — replace with Hermes model discovery
- `Features/Projects/` — no project picker needed
- `Realtime/DeltaApplier.swift` — Hermes SSE deltas are different
- Any tool views specific to OpenCode tools (`bash`, `edit`, `write`, `read`, `grep`, `glob`, `list`, `task`, `question`)
- Basic auth (`API/BasicAuth.swift`) — Hermes uses Bearer tokens

### What Anvil Has (Rename/Adapt)
- `OpencodeApp.swift` → `TalariaApp.swift`
- `OpencodeClient.swift` → `HermesClient.swift`
- `AppModel.swift` — keep the pattern but adapt for Hermes
- `SessionStore.swift` — keep but connect to Hermes Sessions API
- `ChatStore.swift` — major rewrite for Hermes agent loop
- `SetupView.swift` — change to Bearer token auth
- `ServerProfile.swift` — change `username`/`password` to `apiKey`
- Bundle ID → `ai.talaria.client.ios`

---

## 2. What You're Building Toward — Hermes API Server

The target backend is **Hermes Agent API Server** (documented in the attached `hermes-api-reference.md`).

### Auth
- **Bearer token** (`Authorization: Bearer <API_SERVER_KEY>`)
- No username. Just the key.
- Server profile stores: `name`, `url`, `apiKey`
- Setup screen: name, URL (e.g. `http://forge:8642`), API key field

### Key API Surface

| What | Hermes Endpoint | Notes |
|---|---|---|
| Health check | `GET /health` | `{"status": "ok"}` |
| Model list | `GET /v1/models` | Returns `hermes-agent` (or profile name) |
| Session list | `GET /api/sessions` | Paginated |
| Create session | `POST /api/sessions` | Empty session |
| Session messages | `GET /api/sessions/{id}/messages` | Message history |
| Delete session | `DELETE /api/sessions/{id}` | |
| Update session | `PATCH /api/sessions/{id}` | Title only |
| **Chat (stateless)** | `POST /v1/chat/completions` | Full `messages` array each request |
| **Chat with SSE** | `POST /v1/chat/completions` with `stream: true` | SSE token-by-token |
| **Chat (session)** | `POST /api/sessions/{id}/chat/stream` | SSE: `assistant.delta`, `tool.started`, `tool.completed`, `run.completed` |
| **Runs (recommended)** | `POST /v1/runs` → `GET /v1/runs/{id}/events` | SSE with tool progress, reconnectable |
| Stop run | `POST /v1/runs/{run_id}/stop` | |
| Approval | `POST /v1/runs/{run_id}/approval` | |
| Capabilities | `GET /v1/capabilities` | Feature detection |
| Skills list | `GET /v1/skills` | Read-only |
| Toolsets list | `GET /v1/toolsets` | Read-only |

### Recommended Flow for Talaria
Use the **Runs API** as the primary chat mechanism — it's the most native-Hermes path and gives you tool progress, stop, and approval all in one surface.

```
1. GET /health              → confirm connectivity
2. GET /v1/capabilities     → discover feature set
3. GET /v1/models           → confirm model name
4. GET /api/sessions        → list user's sessions
5. POST /api/sessions       → new session (optional)
6. POST /v1/runs            → send prompt, get run_id
7. GET /v1/runs/{id}/events → SSE stream: text deltas, tool.started, tool.completed, run.completed
8. POST /v1/runs/{id}/stop  → interrupt (user cancel)
```

For **Chat Completions** fallback (simpler, stateless):
- Send full `messages` history each time
- Streaming with `"stream": true` gives `chat.completion.chunk` SSE events + `hermes.tool.progress` events
- No server-side session needed, but you lose the richer Runs API events

### Headers
- `Authorization: Bearer <key>` — required on every request
- `X-Hermes-Session-Key: <stable-id>` — for persistent memory across sessions (e.g. `talaria:user-<uuid>`)
- `Idempotency-Key: <unique>` — safe retry for 5 minutes

### Tool Calls in Hermes
Hermes tools are NOT the same as OpenCode tools. Hermes uses:
- `terminal` — shell commands
- `read_file` — file reading
- `write_file` — file writing
- `patch` — targeted file edits
- `search_files` — grep/find
- `web_search` — web search
- `web_extract` — page content
- `browser_*` — browser automation
- `delegate_task` — subagent spawn
- `memory` — persistent memory
- etc.

Tool calls appear in Chat Completions as standard OpenAI `tool_calls` with `function.name` and `function.arguments` (JSON string). In the Runs API, they appear as structured events.

**Do not** build per-tool views like Anvil's `BashToolView`, `EditToolView`, etc. Instead, build a **generic tool call view** that renders:
- Tool name (with icon)
- Arguments (inline or expandable, truncated if long)
- Status indicator (pending → running → completed/error)
- Result/output (collapsible)

This is more future-proof since Hermes tools evolve independently.

---

## 3. Architecture Decisions (Locked In)

1. **iOS 26.2 minimum.** Swift 6.2, latest SwiftUI.
2. **Pure SwiftUI.** No UIKit wrappers.
3. **No third-party packages.** Markdown via `AttributedString(markdown:)`, SSE via `URLSession.bytes(for:)`, Keychain via `Security` framework.
4. **Single app target.** No Swift package.
5. **`@Observable` + `@MainActor`** everywhere for view-bound state.
6. **Strict concurrency.** No `DispatchQueue`. No `Task.detached` without comment.
7. **`NavigationStack` only.** No `NavigationSplitView`.
8. **No SwiftData/CoreData.** Server is source of truth. Keychain for profiles, `UserDefaults` for small prefs. Chat state is in-memory.
9. **No project concept.** Hermes doesn't have server-side projects. The session list is flat.
10. **Runs API primary, Chat Completions fallback.** The app should prefer the Runs API path when `/v1/capabilities` shows it's available.
11. **Bearer token auth.** One field: API key. Store in Keychain.

---

## 4. Target File Structure

```
Talaria/
├── App/
│   ├── TalariaApp.swift
│   ├── RootView.swift
│   ├── LaunchScreenView.swift
│   └── AppModel.swift
├── API/
│   ├── HermesClient.swift          // actor-isolated HTTP client for Hermes
│   ├── HermesError.swift
│   └── HTTPMethod.swift            // keep as-is
├── Realtime/
│   ├── EventStream.swift           // SSE parser (adapted for Hermes SSE format)
│   └── DeltaApplier.swift          // text delta accumulator
├── Models/
│   ├── Session.swift               // Hermes session (from /api/sessions)
│   ├── Message.swift               // Chat message envelope
│   ├── MessagePart.swift           // Text, tool_call, etc.
│   ├── Run.swift                   // From /v1/runs
│   ├── RunEvent.swift              // SSE events from /v1/runs/{id}/events
│   ├── ChatRequest.swift           // For /v1/chat/completions
│   ├── ChatResponse.swift          //
│   ├── ModelInfo.swift             // From /v1/models
│   ├── HealthInfo.swift            // From /health
│   ├── Capabilities.swift          // From /v1/capabilities
│   ├── SkillInfo.swift             // From /v1/skills
│   ├── ToolsetInfo.swift           // From /v1/toolsets
│   ├── ToolCall.swift              // Tool call within a message
│   ├── TokenUsage.swift            //
│   ├── AnyCodable.swift            // keep from Anvil
│   └── Turn.swift                  // UI grouping: user message + assistant response + tools
├── Storage/
│   ├── ServerProfile.swift         // name, url, apiKey (no username/password)
│   ├── ServerProfileStore.swift    // Keychain CRUD
│   └── AppPreferences.swift        // UserDefaults prefs
├── State/
│   ├── SessionStore.swift          // session list + CRUD
│   ├── ChatStore.swift             // chat state, sends to Hermes, applies SSE
│   └── ModelStore.swift            // model list from /v1/models
├── Features/
│   ├── Setup/
│   │   ├── SetupView.swift         // add server: name, url, api key, test connection
│   │   └── SetupModel.swift
│   ├── Profiles/
│   │   ├── ServerProfilePickerSheet.swift
│   │   ├── ServerProfileRow.swift
│   │   └── AddProfileSheet.swift
│   ├── Sessions/
│   │   ├── SessionListView.swift
│   │   ├── SessionRowView.swift
│   │   └── EmptySessionListView.swift
│   ├── Chat/
│   │   ├── ChatView.swift
│   │   ├── ChatToolbar.swift
│   │   ├── ChatComposer.swift      // text input + send/stop
│   │   ├── AttachmentPickerSheet.swift
│   │   └── Messages/
│   │       ├── MessageTimelineView.swift
│   │       ├── TurnView.swift
│   │       ├── UserMessageView.swift
│   │       ├── AssistantMessageView.swift
│   │       └── ThinkingIndicatorView.swift
│   ├── Tools/
│   │   ├── ToolCallView.swift      // generic tool call card
│   │   ├── ToolCallRow.swift       // compact row for collapsed tools
│   │   └── ToolStatusIndicator.swift
│   ├── Models/
│   │   └── ModelPickerSheet.swift
│   └── Settings/
│       ├── SettingsView.swift
│       └── ProfileEditView.swift
├── Shared/
│   ├── DesignTokens.swift
│   ├── MarkdownText.swift
│   ├── CopyButton.swift
│   ├── ShimmerView.swift
│   ├── CollapsibleSection.swift
│   ├── ContentUnavailableViews.swift
│   ├── DateFormatting.swift
│   ├── HapticFeedback.swift
│   └── EnvironmentKeys.swift
└── Tests/
    ├── HermesClientTests.swift
    ├── EventStreamTests.swift
    ├── PartCodingTests.swift
    └── EndpointBuilderTests.swift
```

---

## 5. Code Style Rules (Non-Negotiable)

These are the same rules Anvil follows. Do not deviate:

### Modern SwiftUI API
- `foregroundStyle(...)`, never `foregroundColor(...)`
- `clipShape(.rect(cornerRadius:))`, never `cornerRadius(...)`
- `onChange(of:)` 0- or 2-parameter form only
- `sensoryFeedback(...)` for haptics
- `@Entry` macro for environment values
- `.topBarLeading` / `.topBarTrailing`, never `.navigationBar*`
- `.scrollIndicators(.hidden)` not `showsIndicators: false`
- `if let value {` shorthand
- Static member lookup: `.circle` not `Circle()`

### Swift Language
- `async`/`await`, no `DispatchQueue`
- `Task.sleep(for:)` not `Task.sleep(nanoseconds:)`
- `Date.now` not `Date()`
- `Double` over `CGFloat`
- No force unwraps `!` or `try!`
- Single-expression functions: omit `return`

### View Construction
- Extract subviews into separate `View` structs — no `@ViewBuilder` computed properties
- Button actions in methods, not inline closures
- Logic out of `body` — into stores
- One type per file
- `#Preview` not `PreviewProvider`

### Data Flow
- `@Observable` classes are `@MainActor`
- Local `@State` is `private`
- No `@AppStorage` inside `@Observable` classes
- Bindings: never `Binding(get:set:)` in body

### Navigation
- `NavigationStack` only
- `navigationDestination(for:)` for destinations
- `sheet(item:)` for optional-driven sheets

### Design
- Centralize tokens in `DesignTokens.swift`
- 44×44 minimum tap targets
- `ContentUnavailableView` for empty/error states
- `Label` over `HStack` for icon + text
- No `AnyView`

### Accessibility
- Dynamic Type — never hard-code font sizes
- Decorative images: `Image(decorative:)` or `accessibilityHidden(true)`
- Buttons must have text labels
- `accessibilityDifferentiateWithoutColor` — icons alongside color-only signals

### Hygiene
- No secrets in repo (Keychain handles API keys)
- Comment non-obvious logic only
- Tests for Codable round-tripping

---

## 6. Design System

Keep `DesignTokens.swift` from Anvil but rename `Palette` entries:

```swift
enum Spacing {
    static let xs: Double = 4
    static let s: Double = 8
    static let m: Double = 12
    static let l: Double = 16
    static let xl: Double = 24
    static let xxl: Double = 32
}

enum Radii {
    static let small: Double = 6
    static let medium: Double = 10
    static let large: Double = 16
}

enum AnimationDurations {
    static let quick: Duration = .milliseconds(150)
    static let standard: Duration = .milliseconds(250)
}

enum Palette {
    static let user: Color = .accentColor
    static let assistant: Color = .primary
    static let toolPending: Color = .orange
    static let toolRunning: Color = .blue
    static let toolComplete: Color = .green
    static let toolError: Color = .red
}
```

Liquid Glass is default in iOS 26 — use `.background(.regularMaterial)` and `.glassEffect()` where appropriate.

---

## 7. Key Data Models (Hermes-specific)

### ServerProfile
```swift
struct ServerProfile: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var url: URL          // e.g. http://forge:8642
    var apiKey: String    // stored in Keychain
}
```

### Session (from `/api/sessions`)
```swift
struct Session: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var title: String?
    let source: String?
    let time: SessionTime
}

struct SessionTime: Codable, Hashable, Sendable {
    let created: Double
    let updated: Double
}
```

### Run (from `/v1/runs`)
```swift
struct Run: Codable, Identifiable, Sendable {
    let runID: String
    let status: RunStatus   // started, running, completed, failed, cancelled
    let sessionID: String?
    let model: String?
    let output: String?
}
```

### RunEvent (SSE from `/v1/runs/{id}/events`)
```swift
enum RunEvent: Sendable {
    case textDelta(String)
    case toolStarted(name: String, callID: String, arguments: String)
    case toolCompleted(callID: String, output: String)
    case toolErrored(callID: String, error: String)
    case runCompleted
    case runFailed(error: String)
    case approvalRequired(approvalID: String, prompt: String)
}
```

### Message (for session history)
```swift
struct Message: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let role: String          // "user" or "assistant"
    let content: [MessagePart]
    let toolCalls: [ToolCall]?
    let usage: TokenUsage?
}
```

### ToolCall
```swift
struct ToolCall: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let arguments: [String: AnyCodable]
    var result: String?
    var status: ToolCallStatus  // pending, running, completed, error
}
```

### Capabilities
```swift
struct Capabilities: Codable, Sendable {
    let object: String
    let platform: String
    let model: String
    let auth: AuthInfo
    let features: Features

    struct AuthInfo: Codable, Sendable {
        let type: String
        let required: Bool
    }

    struct Features: Codable, Sendable {
        let chatCompletions: Bool
        let responsesAPI: Bool
        let runSubmission: Bool
        let runStatus: Bool
        let runEventsSSE: Bool
        let runStop: Bool
    }
}
```

---

## 8. HermesClient Design

The client actor should expose:

```swift
actor HermesClient {
    init(baseURL: URL, apiKey: String)

    // Health & Discovery
    func health() async throws -> HealthInfo
    func capabilities() async throws -> Capabilities
    func models() async throws -> [ModelInfo]
    func skills() async throws -> [SkillInfo]
    func toolsets() async throws -> [ToolsetInfo]

    // Sessions
    func listSessions() async throws -> [Session]
    func createSession(title: String?) async throws -> Session
    func getSession(id: String) async throws -> Session
    func updateSession(id: String, title: String) async throws -> Session
    func deleteSession(id: String) async throws
    func sessionMessages(id: String) async throws -> [Message]

    // Chat (stateless)
    func chatCompletion(messages: [ChatMessage], stream: Bool) async throws -> ChatResponse
    func chatCompletionStream(messages: [ChatMessage]) -> AsyncThrowingStream<String, Error>

    // Session-based chat (SSE)
    func sessionChatStream(sessionID: String, input: String) -> AsyncThrowingStream<SessionChatEvent, Error>

    // Runs API (primary)
    func createRun(input: String, sessionID: String?) async throws -> Run
    func runEvents(runID: String) -> AsyncThrowingStream<RunEvent, Error>
    func runStatus(runID: String) async throws -> Run
    func stopRun(runID: String) async throws
    func approveRun(runID: String, decision: String) async throws
}
```

Auth header on every request:
```
Authorization: Bearer <apiKey>
```

Also send `X-Hermes-Session-Key` on chat/run requests for persistent memory.

---

## 9. Critical Behavioral Differences from Anvil

### No Project Concept
Anvil has `ProjectStore` and a project picker because OpenCode requires a `directory` query parameter. Hermes has no such concept. Strip all of it. Sessions are flat — no project grouping.

### Tool Rendering
**Do not** build specialized tool views per tool name. Hermes tools are numerous and evolving. Build **one** generic `ToolCallView` that renders:
- Tool name + emoji (use a simple name→emoji map)
- Arguments (truncated, expandable)
- Status spinner/checkmark/xmark
- Output (expandable, monospaced)
- Timing information

### Permission Flow
Hermes has an approval system through `/v1/runs/{id}/approval`. When an approval is needed:
1. RunEvent indicates `approvalRequired`
2. Show a non-blocking sheet/dock with the prompt
3. POST decision to `/v1/runs/{id}/approval`
4. Run resumes

This is simpler than Anvil's multi-mode permission flow (allow once/always/reject).

### SSE Event Format
Hermes SSE streams are different from OpenCode:
- **Chat Completions SSE**: standard `data: {"choices":[{"delta":{"content":"..."}}]}` format with `[DONE]` terminator. Plus `event: hermes.tool.progress` for tool indicators.
- **Runs API SSE**: Hermes-specific events. Parse carefully — the format may not be standard OpenAI SSE.
- **Session chat/stream SSE**: emits `assistant.delta`, `tool.started`, `tool.completed`, `run.completed`.

Build the SSE parser to handle all three formats. Start with Runs API SSE as the primary target.

### Model Selection
Hermes advertises ONE model on `/v1/models` (the profile name or `hermes-agent`). The model picker can still exist but will typically show just one entry. The `model` field in requests is accepted but cosmetic — the actual model is server-configured.

---

## 10. What NOT to Build (v1 Scope)

- Terminal panel
- File tree browsing/editing
- Full Hermes config/settings UI
- Web search results browser
- iCloud sync
- Push notifications
- iPad-optimized layout (iPhone-first)
- RAG/document upload
- Voice input
- Multi-user support (single profile is fine for v1)

---

## 11. The Plan

1. **Read every file** in the Anvil source tree first. Understand the patterns before touching anything.

2. **Create the Talaria project structure** — all new files go here. Don't modify Anvil files; create Talaria files that reuse/adapt Anvil patterns.

3. **Build in this order:**
   a. `Shared/` — DesignTokens, MarkdownText, CopyButton, ShimmerView, etc. (mostly copy from Anvil)
   b. `Storage/` — ServerProfile (adapted), ServerProfileStore, AppPreferences
   c. `Models/` — all Codable types for Hermes API
   d. `API/` — HermesClient actor with all endpoints
   e. `Realtime/` — SSE parser for Hermes formats
   f. `State/` — SessionStore, ChatStore, ModelStore
   g. `Features/Setup/` — server setup screen
   h. `Features/Profiles/` — profile picker
   i. `Features/Sessions/` — session list
   j. `Features/Chat/` — chat view, composer, timeline
   k. `Features/Tools/` — generic tool call view
   l. `Features/Models/` — model picker (simple)
   m. `Features/Settings/` — settings, profile edit
   n. `App/` — TalariaApp, RootView, AppModel, LaunchScreenView
   o. `Tests/` — at least Codable round-trip tests

4. **AppModel flow:**
   - `start()` → health check → capabilities → load sessions
   - On session tap → `openChat(session)` → `ChatStore` created
   - ChatStore sends via Runs API if `features.runSubmission` is true, else falls back to Chat Completions
   - SSE events dispatched to ChatStore.apply(event)

5. **Every file must compile.** No placeholder stubs. Write complete implementations.

6. **Test with the Hermes API reference doc** attached. Use the exact endpoint paths, request shapes, and response shapes shown there.

---

## 12. Bundle & Branding

- App name: **Talaria**
- Bundle ID: `ai.talaria.client.ios`
- App icon: winged sandal (you don't need to create the asset, just reference it)
- Accent color: keep system accent or a warm gold/amber (Hermes-themed)

---

## Attached Reference

The file `hermes-api-reference.md` contains the complete Hermes API Server endpoint documentation. It is your source of truth for all endpoint paths, request/response shapes, headers, SSE event formats, and auth patterns. Read it first.
