# Changelog

All notable changes to this project will be documented in this file.

## [0.1.0-alpha] - 2026-02-17

### Added
- Initial release of Geminy Cricket as a local-first agent supervisor runtime.
- Supervisor session and run lifecycle primitives (`start`, `begin_run`, `heartbeat`, `checkpoint`, `pause`, `resume`, `end_run`).
- Verification pipeline support with compact failure "chirps" and verification metadata capture.
- Durable local state using DuckDB for sessions, runs, plans, checkpoints, logic notes, and recall.
- MCP server integration exposing supervisor tools for external coding agents.
- Local dashboard server for read-only observability into session and run state.
- Context packet and compaction flows to support resumable, long-running agent loops.

### Security
- Dashboard rendering moved to escaped templates to reduce stored XSS risk from user-controlled fields.

### Changed
- Supervisor internals hardened to reduce thread-safety risk from shared mutable session state.
- Exception handling in core client/store paths now logs operational errors for diagnosis.
