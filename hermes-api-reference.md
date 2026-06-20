# Hermes Agent API Server — Complete Reference

> Source: https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server/
> Version: Hermes 0.16.0+

The API server exposes Hermes Agent as an **OpenAI-compatible HTTP endpoint** with full agent toolset: terminal, file operations, web search, memory, skills, browser, and more.

---

## Quick Connect

```
Base URL:  http://<host>:8642/v1
Auth:      Bearer <API_SERVER_KEY>
```

Test:
```bash
curl http://localhost:8642/health
# → {"status": "ok", "platform": "hermes-agent", "version": "0.16.0"}
```

---

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `API_SERVER_ENABLED` | `false` | Enable the API server |
| `API_SERVER_PORT` | `8642` | HTTP server port |
| `API_SERVER_HOST` | `127.0.0.1` | Bind address (`0.0.0.0` for Docker/LAN) |
| `API_SERVER_KEY` | *(required)* | Bearer token for auth |
| `API_SERVER_CORS_ORIGINS` | *(none)* | Comma-separated browser origins (only if browser clients call directly) |
| `API_SERVER_MODEL_NAME` | profile name | Model name advertised on `/v1/models` |

> Config is via environment variables only; `config.yaml` support is not yet available.

---

## All Endpoints

### OpenAI-Compatible

#### `POST /v1/chat/completions`
Standard Chat Completions. **Stateless** — full conversation in `messages` array each request.

```json
// Request
{
  "model": "hermes-agent",
  "messages": [
    {"role": "system", "content": "You are a Python expert."},
    {"role": "user", "content": "Write a fibonacci function"}
  ],
  "stream": false
}

// Response
{
  "id": "chatcmpl-abc123",
  "object": "chat.completion",
  "model": "hermes-agent",
  "choices": [{
    "index": 0,
    "message": {"role": "assistant", "content": "Here's a fibonacci function..."},
    "finish_reason": "stop"
  }],
  "usage": {"prompt_tokens": 50, "completion_tokens": 200, "total_tokens": 250}
}
```

**Inline images:** Messages can include `image_url` parts (remote `http(s)` URLs and `data:image/...`). Files/`file_id`/non-image `data:` URLs not supported.

**Streaming** (`"stream": true`): SSE with `chat.completion.chunk` events + custom `event: hermes.tool.progress` events for tool visibility.

#### `POST /v1/responses`
OpenAI Responses API. **Stateful** — server stores conversation history via `previous_response_id`.

```json
// Request
{
  "model": "hermes-agent",
  "input": "What files are in my project?",
  "instructions": "You are a helpful coding assistant.",
  "store": true
}

// Response
{
  "id": "resp_abc123",
  "object": "response",
  "status": "completed",
  "model": "hermes-agent",
  "output": [
    {"type": "function_call", "name": "terminal", "arguments": "{\"command\": \"ls\"}", "call_id": "call_1"},
    {"type": "function_call_output", "call_id": "call_1", "output": "README.md src/ tests/"},
    {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "Your project has..."}]}
  ],
  "usage": {"input_tokens": 50, "output_tokens": 200, "total_tokens": 250}
}
```

**Multi-turn:**
```json
{"input": "Now show me the README", "previous_response_id": "resp_abc123"}
```

**Named conversations** (auto-chain):
```json
{"input": "Hello", "conversation": "my-project"}
{"input": "What's in src/?", "conversation": "my-project"}
```

**Streaming:** SSE with spec-native `function_call` and `function_call_output` output items for structured tool UI.

#### `GET /v1/responses/{id}`
Retrieve a stored response.

#### `DELETE /v1/responses/{id}`
Delete a stored response.

#### `GET /v1/models`
```json
{"object": "list", "data": [{"id": "hermes-agent", ...}]}
```
Model name defaults to profile name, or `hermes-agent` for default profile.

#### `GET /v1/capabilities`
Machine-readable surface for UIs/orchestrators:
```json
{
  "object": "hermes.api_server.capabilities",
  "platform": "hermes-agent",
  "model": "hermes-agent",
  "auth": {"type": "bearer", "required": true},
  "features": {
    "chat_completions": true,
    "responses_api": true,
    "run_submission": true,
    "run_status": true,
    "run_events_sse": true,
    "run_stop": true
  }
}
```

#### `GET /health`
```json
{"status": "ok"}
```
Also available at `GET /v1/health`.

#### `GET /health/detailed`
Extended check reporting active sessions, running agents, and resource usage.

---

### Runs API (Agent Control Plane)

Alternative to `/v1/chat/completions` for long-form sessions — subscribe to progress events instead of managing streaming yourself.

#### `POST /v1/runs`
Create a new agent run.
```json
// Request body
{
  "input": "Run the test suite",
  "session_id": "my-session-42",
  "instructions": "Be thorough",
  "conversation_history": [...],
  "previous_response_id": "resp_abc"
}

// Response
{"run_id": "run_abc123", "status": "started"}
```

#### `GET /v1/runs/{run_id}`
Poll current state (for dashboards/UI reconnect without holding SSE open):
```json
{
  "object": "hermes.run",
  "run_id": "run_abc123",
  "status": "completed",
  "session_id": "space-session",
  "model": "hermes-agent",
  "output": "Done.",
  "usage": {"input_tokens": 50, "output_tokens": 200, "total_tokens": 250}
}
```
Statuses briefly retained after terminal states (`completed`, `failed`, `cancelled`).

#### `GET /v1/runs/{run_id}/events`
**SSE stream** — tool-call progress, token deltas, lifecycle events. Designed for dashboards/thick clients that want to attach/detach without losing state.

#### `POST /v1/runs/{run_id}/stop`
Interrupt a running turn. Returns immediately:
```json
{"status": "stopping"}
```
Agent stops at next safe interruption point.

#### `POST /v1/runs/{run_id}/approval`
Resolve a pending approval (tool call gated behind approval policy). Body carries the decision; run resumes when recorded.

---

### Sessions API (Session Control over REST)

All endpoints gated by `API_SERVER_KEY`. Live under `/api/sessions/*`.

| Method | Path | Description |
|---|---|---|
| `GET` | `/api/sessions` | List sessions (paginated: `limit`, `offset`, `source`, `include_children`) |
| `POST` | `/api/sessions` | Create an empty session |
| `GET` | `/api/sessions/{id}` | Read session metadata |
| `PATCH` | `/api/sessions/{id}` | Update title or `end_reason` |
| `DELETE` | `/api/sessions/{id}` | Delete a session |
| `GET` | `/api/sessions/{id}/messages` | Message history for a session |
| `POST` | `/api/sessions/{id}/fork` | Branch the session (matches CLI `/branch` semantics) |
| `POST` | `/api/sessions/{id}/chat` | Run one synchronous agent turn |
| `POST` | `/api/sessions/{id}/chat/stream` | **SSE wrapper** over a single turn — emits `assistant.delta`, `tool.started`, `tool.completed`, `run.completed` events |

**Examples:**
```bash
# Fork a session
curl -X POST http://localhost:8642/api/sessions/$ID/fork \
  -H "Authorization: Bearer $KEY" \
  -d '{"title": "explore alt path"}'

# Stream a turn
curl -N -X POST http://localhost:8642/api/sessions/$ID/chat/stream \
  -H "Authorization: Bearer $KEY" \
  -d '{"input": "what files changed in the last hour?"}'
```

---

### Jobs API (Scheduled/Background Work)

CRUD surface for managing scheduled jobs. All endpoints bearer-auth gated.

| Method | Path | Description |
|---|---|---|
| `GET` | `/api/jobs` | List all scheduled jobs |
| `POST` | `/api/jobs` | Create a job (body: prompt, schedule, skills, provider override, delivery target) |
| `GET` | `/api/jobs/{job_id}` | Fetch job definition + last-run state |
| `PATCH` | `/api/jobs/{job_id}` | Partial update (prompt, schedule, etc.) |
| `DELETE` | `/api/jobs/{job_id}` | Remove job + cancel in-flight run |
| `POST` | `/api/jobs/{job_id}/pause` | Pause without deleting |
| `POST` | `/api/jobs/{job_id}/resume` | Resume paused job |
| `POST` | `/api/jobs/{job_id}/run` | Trigger immediately (out of schedule) |

---

### Skills & Toolsets Discovery

#### `GET /v1/skills`
Read-only, gated by `API_SERVER_KEY`:
```bash
curl http://localhost:8642/v1/skills -H "Authorization: Bearer $KEY"
# → [{"name": "github-pr-workflow", "description": "...", "category": "..."}, ...]
```

#### `GET /v1/toolsets`
Toolsets resolved for the `api_server` platform:
```bash
curl http://localhost:8642/v1/toolsets -H "Authorization: Bearer $KEY"
# → [{"name": "core", "label": "...", "tools": ["read_file", "write_file", ...], "enabled": true}, ...]
```

Both advertised in `/v1/capabilities` under `endpoints.*`.

---

## Key Headers

### Authentication
```
Authorization: Bearer <API_SERVER_KEY>
```
Required on every request. No exceptions, even on loopback.

### Session Identification
```
X-Hermes-Session-Id: <transcript-scoped id>
X-Hermes-Session-Key: <stable per-user/channel id>
```

- `X-Hermes-Session-Id` — transcript-scoped; rotates on session reset.
- `X-Hermes-Session-Key` — stable per-user identifier for long-term memory (Honcho).
  - Max 256 chars
  - Control characters (`\r`, `\n`, `\x00`) rejected
  - Echoed back on responses (JSON + SSE)
  - Advertised in `/v1/capabilities` as `"session_key_header": "X-Hermes-Session-Key"`

### Idempotency
```
Idempotency-Key: <unique-key>
```
Allowed request header. Responses cached by key for **5 minutes**. Safe to retry.

---

## Streaming Reference

### Chat Completions SSE
- Standard `chat.completion.chunk` events
- Hermes custom: `event: hermes.tool.progress` — tool-start visibility without polluting assistant text

### Responses SSE
- OpenAI Responses event types:
  - `response.created`
  - `response.output_text.delta`
  - `response.output_item.added`
  - `response.output_item.done`
  - `response.completed`
- `function_call` and `function_call_output` items streamed natively for structured tool UI

### Sessions chat/stream SSE
- `assistant.delta`
- `tool.started`
- `tool.completed`
- `run.completed`

### Runs events SSE
- Tool-call progress
- Token deltas
- Lifecycle events
- Reconnectable (attach/detach without losing state)

---

## System Prompt Handling

When a frontend sends a `system` message (Chat Completions) or `instructions` field (Responses API), Hermes **layers it on top of its core system prompt**. The agent retains all tools, memory, and skills — the frontend's system prompt adds extra context.

This means you can customize behavior per client without losing capabilities.

---

## Security

- **`API_SERVER_KEY` is mandatory** — even on `127.0.0.1` loopback
- **CORS is off by default** — set `API_SERVER_CORS_ORIGINS` only for browser clients
  - Preflight responses include `Access-Control-Max-Age: 600`
  - SSE streaming responses include CORS headers for `EventSource`
  - Most frontends (Open WebUI, etc.) connect server-to-server and need no CORS
- **Response headers:**
  - `X-Content-Type-Options: nosniff`
  - `Referrer-Policy: no-referrer`
- **Full tool access** — the API server gives access to terminal commands, file ops, etc. Keep `API_SERVER_CORS_ORIGINS` narrow.

---

## Limitations

- **Response storage:** Stored responses (for `previous_response_id`) persisted in SQLite. Max 100 stored responses (LRU eviction). Survive gateway restarts.
- **No file upload:** Inline images supported on both Chat Completions and Responses. Uploaded files (`file`, `input_file`, `file_id`) and non-image document inputs are **not** supported through the API.
- **Model field is cosmetic:** The `model` field in requests is accepted but the actual LLM model is configured server-side.
- **Tool location:** Tools execute on the API server host. No split-runtime mode ("remote brain, local hands") currently available.
- **Config:** Currently environment-variable only. No `config.yaml` support yet.
- **Profiles API server ports:** Pick ports outside the default-platform range (`8644` webhook, `8645` wecom-callback, `8646` msgraph-webhook). Use `8650+` for custom profiles.

---

## Multi-User Setup (Profiles)

Each Hermes profile gets its own API server on a different port, advertising the profile name as the model:

```bash
# Create profiles
hermes profile create alice
hermes profile create bob

# Configure API servers (env vars go in profile .env)
cat >> ~/.hermes/profiles/alice/.env << EOF
API_SERVER_ENABLED=true
API_SERVER_PORT=8650
API_SERVER_KEY=alice-secret
EOF

cat >> ~/.hermes/profiles/bob/.env << EOF
API_SERVER_ENABLED=true
API_SERVER_PORT=8651
API_SERVER_KEY=bob-secret
EOF

# Start each gateway
hermes -p alice gateway &
hermes -p bob gateway &
```

Each profile appears as a separate model with isolated config, memory, and skills.

---

## Proxy Mode

The API server can act as a backend for gateway proxy mode. When another Hermes gateway sets `GATEWAY_PROXY_URL` to this API server, it forwards all messages here instead of running its own agent. Enables split deployments (e.g., Docker container handling Matrix E2EE relaying to a host-side agent).

---

## Recommended Flow for Native Apps (like Talaria)

For a SwiftUI Hermes client, the recommended API path:

```
1. GET  /v1/capabilities          → discover what's available
2. GET  /v1/models                → confirm agent model name
3. GET  /api/sessions             → list/restore existing sessions
4. POST /api/sessions             → create new session
5. POST /api/sessions/{id}/chat/stream → SSE streaming turn with tool visibility
   or:
   POST /v1/runs                  → create run
   GET  /v1/runs/{id}/events      → SSE stream with reconnect support

Headers:
   Authorization: Bearer <key>
   X-Hermes-Session-Key: <stable-user-id>   (for long-term memory)
```

For **tool progress visibility**, prefer streaming endpoints (`chat/stream` or `/runs/{id}/events`) — they emit `tool.started`/`tool.completed` events so you can show real-time agent activity in your UI.
