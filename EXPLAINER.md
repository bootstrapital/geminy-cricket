# Geminy Cricket Explainer

## What

Geminy Cricket provides the **Agent Supervisor Layer** for autonomous development.

It does not edit source code. It provides the reliability control plane:
- durable session/plan/journal state in DuckDB
- test verification (`gc_verify`) with normalized failure chirps
- lexical + semantic recall (`gc_recall`)
- long-running run orchestration (`gc_begin_run` ... `gc_end_run`)
- context rehydration and compaction (`gc_context_packet`, `gc_compact`)
- read-only dashboard for operators

## Why

As agents move from "chat" to "autonomy," generation speed matters less than **supervision quality**.

Long-running agent work fails when context is only in chat history.
Common failure modes:
- restart loses why a decision was made
- repeated failures because prior attempts are not discoverable
- token growth from replaying full history
- ambiguous status when multiple agents/handoffs occur

Geminy Cricket makes durable state the source of truth, so agent threads can be disposable.

## How

### Architecture

- Executor (Codex/Gemini CLI): writes code and calls supervisor tools.
- Supervisor (Geminy Cricket): coordinates, verifies, stores memory, returns context packets.
- Storage (DuckDB): sessions, plan items, journal entries, runs, checkpoints, embeddings.
- Runtime model: one long-lived server process owns DuckDB; external clients call `POST /tool` so writes are serialized without lock contention.
- Concurrency guard: store-level DB mutex serializes DuckDB calls to avoid prepared-statement race failures under multi-threaded request traffic.
- Security guard: `/tool` supports API key auth (`GC_TOOL_API_KEY`) and uses structured unauthorized responses.
- Rendering guard: dashboard uses Slim templates with escaping enabled by default to prevent stored XSS when rendering session/journal/run fields.
- Supervisor state model: supervisor request handling is stateless with respect to "active session" memory; fallback session resolution is always store-backed (`latest_active_session`) to avoid cross-thread clobbering.

### Tool Groups

Planning and memory:
- `gc_start`, `gc_plan_step`, `gc_record_logic`, `gc_recall`, `gc_reindex_embeddings`

Verification:
- `gc_verify(scope, framework:auto|rspec|minitest)`
- chirp fields are normalized: file, line, snippet, exception, compact backtrace

Run lifecycle:
- `gc_begin_run`, `gc_heartbeat`, `gc_checkpoint`, `gc_pause`, `gc_resume`, `gc_end_run`, `gc_next_step`

Context management:
- `gc_context_packet(run_id, budget_tokens?)`
- `gc_compact(run_id, reason, budget_tokens?)`

Operations:
- `gc_health` and dashboard `/health`

### Semantic Recall

- Embeddings generated with Informers
- Stored in DuckDB `embeddings`
- Uses VSS when available; lexical fallback remains available
- `gc_reindex_embeddings` backfills existing records after upgrades/model changes

## Key Features: How They Work

### 1) Durable Session/Plan/Journal Memory

How it works:
- `gc_start(goal)` creates a `sessions` row (`status=active`).
- `gc_plan_step(desc)` writes a `plan_items` row linked to the session.
- `gc_record_logic(summary)` writes a `journal_entries` row with `entry_type=reasoning`.
- Tool calls resolve session explicitly (`session_id`/`run_id`) or via store fallback to latest active session.

Why this matters:
- State survives restarts, model swaps, and agent handoff.
- The source of truth is DB state, not chat transcript memory.

### 2) Verification + Chirp Extraction (`gc_verify`)

Goal:
- Convert noisy test output into a compact, actionable, model-friendly payload ("chirp").

How framework detection works:
- `framework=auto` chooses RSpec if `spec/**/*_spec.rb` exists, else Minitest if `test/**/*_test.rb` exists.

RSpec chirp extraction:
1. Run: `bundle exec rspec <scope> --format json --out <tempfile>`.
2. Parse JSON and select failed examples.
3. For first failure, parse failure location from backtrace (`file:line`).
4. Extract snippet around failure line with configurable radius (`GC_SNIPPET_RADIUS`, default 3).
5. Return normalized chirp fields:
   - `failing_example`
   - `file`, `line`
   - `snippet`
   - `exception`
   - compact `backtrace`

Minitest chirp extraction:
1. Run Minitest runner and capture output.
2. Parse failure/error blocks line-by-line.
3. Infer location from backtrace lines (`file:line`).
4. Extract nearby snippet using same snippet helper.
5. Return same normalized chirp shape as RSpec.

Post-processing:
- Verification result is journaled (`test_success`/`test_failure`).
- On failure, supervisor runs recall over exception text and attaches `related_failures` to chirp.
- Optional checkpoint is created when `run_id` is supplied.

### 3) Recall (`gc_recall`): Lexical, Semantic, Hybrid

Lexical mode:
- SQL `ILIKE` over journal content.
- Ranked by recency and lexical order.

Semantic mode:
- Embed query text with Informers.
- Compare against `embeddings.vector` using DuckDB cosine distance.
- Return ranked semantic similarity matches.

Hybrid mode:
- Run lexical + semantic independently.
- Merge by entry ID.
- Compute combined score (semantic score with lexical bonus).
- Emit retrieval rationale in each match:
  - lexical-only
  - semantic-only
  - combined hybrid

Resilience:
- If embedder/VSS path fails, system falls back without crashing and logs structured warnings.

### 4) Run Lifecycle Orchestration

Core tools:
- `gc_begin_run`, `gc_heartbeat`, `gc_checkpoint`, `gc_pause`, `gc_resume`, `gc_end_run`, `gc_next_step`

How it works:
- `gc_begin_run` creates `agent_runs` row with `resume_token`.
- `gc_heartbeat` updates status/loop count/metadata and returns context-management signals.
- `gc_checkpoint` stores summarized progress snapshots in `run_checkpoints`.
- `gc_pause` marks run paused and records blocker journal entry.
- `gc_resume` transitions back to running and returns a rehydration context packet.
- `gc_end_run` finalizes status and writes terminal checkpoint.
- `gc_next_step` resolves next incomplete plan item and returns it with optional context packet.

Why this matters:
- Agents can be disposable; runs are durable.
- Humans can inspect progress independent of current chat/process.

### 5) Context Packet + Compaction

`gc_context_packet(run_id)` builds a bounded rehydration payload:
- goal summary
- active plan item(s)
- latest checkpoint
- latest failing chirp
- unresolved blockers
- next intended action
- hot context entries within token budget

Token budgeting:
- estimated token usage uses deterministic char-based heuristic.
- hot context is trimmed to fit budget.

Compaction triggers:
- token budget exceeded
- periodic loop threshold (`GC_COMPACTION_LOOP_INTERVAL`)
- forced handoff/restart trigger (`gc_resume`)

`gc_compact`:
- Writes a compact checkpoint summary and returns updated packet.
- Allows new agent thread/process to continue without replaying old chat.

### 6) Dashboard + Security Model

Dashboard:
- Read-only HTMX polling endpoints (`/run`, `/plan`, `/journal`) plus landing page.
- Designed for observability, not mutation.

Mutation path:
- `POST /tool` dispatches supervisor tools.
- Optional API key guard: `GC_TOOL_API_KEY` + `X-GC-API-Key`.
- Unauthorized requests receive structured 401 payload.

XSS hardening:
- Slim templates render escaped output by default.
- Regression test asserts script payload is escaped in dashboard HTML.

### 7) Concurrency and Thread Safety

Store safety:
- DB access is serialized via mutex when enabled (`GC_DB_MUTEX_DISABLED=false` default).
- Prevents DuckDB prepared statement race behavior under concurrent requests.

Supervisor safety:
- No mutable per-request session cache in Supervisor instance.
- Session fallback resolution is store-based per call.
- Eliminates shared mutable state race around active session routing.

### 8) Failure-Tolerant Behavior + Structured Logging

Design intent:
- Many non-critical subsystems degrade gracefully (embedding/VSS/health parsing) instead of crashing request flow.

Current behavior:
- Fallback paths now emit structured warning logs (JSON) with event type, exception class/message, and request context where available.
- Critical database errors still raise, after structured logging.

## How To Operate Geminy Cricket With an Agent

### 8-step operating loop

1. User sets goal with `gc_start`.
2. Agent records plan via `gc_plan_step`.
3. Agent starts run with `gc_begin_run(agent_id)`.
4. Agent asks `gc_next_step` and executes code changes.
5. Agent verifies with `gc_verify`.
6. Agent sends `gc_heartbeat` and `gc_checkpoint`.
7. If prompt context grows, agent runs `gc_compact`.
8. On completion/failure, agent calls `gc_end_run`.

### Failure and restart flow

1. Agent process dies mid-task.
2. New agent process calls `gc_resume(run_id)`.
3. It uses returned `context_packet` (goal, active step, latest checkpoint, latest failing chirp, blockers, next action).
4. It continues work without old chat transcript.

### Who does what

- User: prioritization, approval, blocker decisions.
- Agent: code/test loop, tool calls, checkpoint discipline.
- Supervisor: state durability, recall quality, context-budget safety.

### Codex example (MCP)

- Connect `bin/geminy-cricket-mcp` through Codex MCP config.
- Agent loop in Codex uses tool calls: `gc_begin_run` -> `gc_next_step` -> `gc_verify` -> `gc_checkpoint`.

### Gemini CLI example (MCP)

- Register `bin/geminy-cricket-mcp` in Gemini CLI MCP configuration.
- Use the same tool loop as Codex through MCP: `gc_begin_run` -> `gc_next_step` -> `gc_verify` -> `gc_checkpoint`.

## Context Compaction in Plain Terms

- Keep only hot context in the current thread.
- Store warm/cold context as checkpoints and journal entries.
- Rehydrate using packets instead of replaying old chats.

Compaction triggers implemented:
- estimated tokens exceed budget
- periodic loop count threshold
- restart/handoff (`gc_resume`)

## Planned Next

- Add auth controls for dashboard/MCP in shared environments.
- Add richer telemetry counters and export format.
- Improve semantic ranking weighting and configurable rerank.
- Add explicit contradiction detection in compaction metadata.
- Add optional plan-item completion tool semantics in MCP surface.
