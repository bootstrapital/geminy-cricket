# AGENTS.md

This file is the canonical operating policy for executors (Codex, Gemini CLI, or similar) using Geminy Cricket.

## Scope

- You are the executor.
- Geminy Cricket provides the Agent Supervisor Layer.
- You write/edit code and run local commands.
- Supervisor tools handle durable memory, verification context, and orchestration state.
- Default transport is supervisor server mode (`GC_SUPERVISOR_MODE=server`) via HTTP to the running `bundle exec ruby bin/geminy-cricket-server` process.
- If `GC_TOOL_API_KEY` is configured, client-mode tool calls require `X-GC-API-Key` (built-in client sets this automatically).

## Non-Negotiable Rules

1. Start or resume supervisor state before coding.
2. Use supervisor tools for planning, verification, checkpoints, and context rehydration.
3. Keep thread context minimal; durable state is source of truth.
4. Dashboard is read-only observability.

## Tool Quick Reference

- `gc_start(goal)`
- `gc_plan_step(desc, session_id?)`
- `gc_verify(scope, framework?, session_id?, run_id?)`
- `gc_recall(query, mode?, limit?, session_id?)`
- `gc_record_logic(summary, session_id?, run_id?)`
- `gc_reindex_embeddings(session_id?, entity_type?)`
- `gc_begin_run(agent_id, session_id?)`
- `gc_checkpoint(run_id, summary, metadata?)`
- `gc_heartbeat(run_id, status, metadata?)`
- `gc_pause(run_id, reason)`
- `gc_resume(run_id)`
- `gc_end_run(run_id, outcome, summary)`
- `gc_next_step(session_id?, run_id?)`
- `gc_context_packet(run_id, budget_tokens?)`
- `gc_compact(run_id, reason, budget_tokens?)`
- `gc_health()`

## Recommended System Prompt Injection

Best place: the host agent config (`AGENTS.md` + host-specific system instruction), not inside project source code.

Minimum instruction set for any executor:
- Always begin by restoring supervisor context (`gc_resume`/`gc_next_step`).
- Before each loop, update heartbeat (`gc_heartbeat`).
- After each test run, checkpoint (`gc_checkpoint`) and record logic when strategy changes.
- Use `gc_context_packet` instead of replaying old chat history.
- Trigger `gc_compact` when context budget is high or handoff occurs.
- End run explicitly with `gc_end_run`.

## Standard Loop

1. `gc_start` (or `gc_resume`).
2. `gc_begin_run`.
3. `gc_next_step`.
4. Implement smallest needed change.
5. `gc_verify` on narrow scope.
6. `gc_checkpoint` (+ `gc_record_logic` for strategy changes).
7. `gc_heartbeat`.
8. `gc_compact` if triggered.
9. Repeat until done, then `gc_end_run`.

## Restart/Handoff

1. New process calls `gc_resume(run_id)`.
2. Use returned context packet only.
3. Continue loop; do not rely on old transcript.

## Failure Handling

- Correct invalid tool args and retry.
- If semantic backend is unavailable, continue with lexical/hybrid recall.
- If run/session cannot be resolved, create or resume explicitly before coding.
