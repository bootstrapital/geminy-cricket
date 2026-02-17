# Geminy Cricket

**The Agent Supervisor Layer for Autonomous Development.**

Geminy Cricket is the reliability control plane for coding agents. It provides the **Agent Supervisor Layer** that sits between an autonomous agent and your production codebase.

Instead of just "running code," Geminy Cricket enforces a supervised loop:
- **Durable State:** Persists plans, steps, and reasoning across sessions (DuckDB).
- **Verification:** Normalizes test failures into compact "chirps" for efficient agent self-correction.
- **Resumability:** Supports checkpoints, pause/resume, and context compaction for long-running tasks.
- **Auditability:** Keeps a durable journal of every decision and outcome.

For agent behavior policy and prompt guidance, see `AGENTS.md`.

## Why Geminy Cricket?

As agents move from "chat" to "autonomy," generation speed matters less than **supervision quality**.

Geminy Cricket fills the gap between the Agent (which wants to go fast) and the Repository (which needs to stay safe). It acts as the "Flight Recorder" and "Mission Control" for the agent's inner loop, ensuring that even if the agent crashes or hallucinates, the *state of the work* is preserved and recoverable.

## Architecture

Default runtime model is single-owner: one supervisor server process owns DuckDB, and CLI/MCP clients call that process over HTTP.

## Install

1. Requirements:
- Ruby 3.3+
- Bundler

2. Install gems:

```bash
bundle install
```

3. Optional executable bits:

```bash
chmod +x bin/geminy-cricket bin/geminy-cricket-mcp bin/geminy-cricket-server
```

## Config

Environment variables:
- `GC_DB_PATH` (default `db/geminy_cricket.duckdb`)
- `GC_DASHBOARD_PORT` (default `48203`)
- `GC_SNIPPET_RADIUS` (default `3`)
- `GC_EMBEDDING_MODEL` (default `sentence-transformers/all-MiniLM-L6-v2`)
- `GC_EMBEDDING_DIMS` (default `384`)
- `GC_CONTEXT_TOKEN_BUDGET` (default `6000`)
- `GC_COMPACTION_LOOP_INTERVAL` (default `20`)
- `GC_COMPACTION_MAX_HISTORY_ENTRIES` (default `12`)
- `GC_SERVER_URL` (default `http://127.0.0.1:$GC_DASHBOARD_PORT`)
- `GC_SUPERVISOR_MODE` (`server` default, `direct`, or `auto`)
- `GC_SERVER_TIMEOUT_SECONDS` (default `15`)
- `GC_BIND_HOST` (default `127.0.0.1`)
- `GC_TOOL_API_KEY` (optional; required for `/tool` auth when set)
- `GC_STRICT_BIND_AUTH` (default `false`; if `true`, non-local bind without `GC_TOOL_API_KEY` aborts boot)
- `GC_DB_MUTEX_DISABLED` (default `false`; keeps DB connection mutex enabled)
- `PUMA_MIN_THREADS` (default `0`)
- `PUMA_MAX_THREADS` (default `1`)

## Dashboard

Start dashboard:

```bash
bundle exec ruby bin/geminy-cricket-server
```

Run tools from another terminal after this starts.

Health endpoint:

```bash
curl http://127.0.0.1:48203/health
```

Secure local tool endpoint example:

```bash
GC_TOOL_API_KEY=dev-secret bundle exec ruby bin/geminy-cricket-server
GC_TOOL_API_KEY=dev-secret bundle exec ruby -e "require_relative 'lib/geminy_cricket'; s=GeminyCricket::SupervisorFactory.build; p s.dispatch('gc_health', {})"
```

## Tool Surface

Core:
- `gc_start(goal)`
- `gc_plan_step(desc, session_id?)`
- `gc_verify(scope, framework:auto|rspec|minitest, session_id?, run_id?)`
- `gc_recall(query, mode:hybrid|lexical|semantic, limit?, session_id?)`
- `gc_record_logic(summary, session_id?, run_id?)`
- `gc_reindex_embeddings(session_id?, entity_type?)`

Run orchestration:
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

Note: `gc_verify` scope is restricted to `spec/` and `test/` roots for safety.

## How To Operate Geminy Cricket With an Agent

Roles:
- User: sets goal, reviews progress, intervenes on blockers.
- Agent (Codex/Gemini): edits code, runs tests, calls `gc_*` tools.
- Supervisor (Geminy Cricket): stores durable state, verifies, recalls, compacts context.

Day-to-day loop:
1. Start session: `gc_start`.
2. Create plan steps: `gc_plan_step`.
3. Start run: `gc_begin_run`.
4. Ask next action: `gc_next_step`.
5. Implement code in repo.
6. Verify with `gc_verify` (narrow scope first).
7. Heartbeat/checkpoint with `gc_heartbeat` and `gc_checkpoint`.
8. On context growth, call `gc_compact`.
9. On interruption, `gc_resume` + `gc_context_packet` in new agent thread.
10. Finish with `gc_end_run`.

Restart recovery example:
1. Agent process dies.
2. Start new process and call `gc_resume(run_id)`.
3. Use returned context packet (goal, active step, latest chirp, blockers, next action).
4. Continue loop without old chat history.

## MCP Setup (Codex and Gemini CLI)

Geminy Cricket exposes tools via MCP through `bin/geminy-cricket-mcp`.

### Codex quick add

```bash
codex mcp add geminy-cricket -- bundle exec ruby bin/geminy-cricket-mcp
codex mcp list
```

### Codex `~/.codex/config.toml`

```toml
[mcp_servers.geminy-cricket]
command = "bundle"
args = ["exec", "ruby", "/ABSOLUTE/PATH/geminy-cricket/bin/geminy-cricket-mcp"]
cwd = "/ABSOLUTE/PATH/geminy-cricket"
```

### Gemini CLI MCP setup

Configure Gemini CLI to launch this MCP server command:

```bash
bundle exec ruby /ABSOLUTE/PATH/geminy-cricket/bin/geminy-cricket-mcp
```

Use your Gemini CLI MCP config format to register that command with the project `cwd` set to this repo.

## Packaging

Build gem:

```bash
gem build geminy-cricket.gemspec
```

Release instructions: `RELEASING.md`.

## Quality Gates

Install dev/test dependencies, then run the full beta checks:

```bash
bundle install
make check
```

Useful individual commands:
- `make syntax`
- `make lint`
- `make test`
- `make security`
- `make security-strict`
- `make smoke`
- `make release-check`
- `make release-check-install`

Notes:
- `make security` runs Brakeman and `bundle-audit`.
- `make security-strict` enforces advisory DB update/check and fails on any bundle-audit issue.
- If you are offline, `bundle-audit` update may fail; non-strict `make security` warns and continues.
- `make smoke` supports `SMOKE_MODE=auto|server|direct` (default `auto`), where `auto` falls back to direct mode when localhost bind is unavailable.
- `make release-check` is offline-safe (build + package + executable sanity checks); `make release-check-install` additionally verifies local gem install paths.

## Troubleshooting DuckDB Locks

If you see lock errors, more than one process is opening the same DuckDB file for writes.

- Recommended: keep `GC_SUPERVISOR_MODE=server` (default) and run one `bundle exec ruby bin/geminy-cricket-server` process.
- Use `GC_SUPERVISOR_MODE=direct` only for one-off local commands when the server is not running.

## Troubleshooting Prepared Statement Errors

If you see `DuckDB::Error - Failed to execute prepared statement` during dashboard polling:

- Ensure you are on the latest code (store-level DB mutex enabled by default).
- Keep server threading conservative (`PUMA_MAX_THREADS=1` default).
- Confirm `/health` reports `"db_mutex_enabled":true`.
