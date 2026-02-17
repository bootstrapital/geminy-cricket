# Geminy Cricket Explainer

## What

Geminy Cricket is a supervisor service for coding agents.

It does not edit source code. It provides:
- durable session/plan/journal state in DuckDB
- test verification (`gc_verify`) with normalized failure chirps
- lexical + semantic recall (`gc_recall`)
- long-running run orchestration (`gc_begin_run` ... `gc_end_run`)
- context rehydration and compaction (`gc_context_packet`, `gc_compact`)
- read-only dashboard for operators

## Why

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
