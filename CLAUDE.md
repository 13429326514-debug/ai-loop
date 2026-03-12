# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

AI Auto-Loop System — a bash-based orchestrator that executes sequential AI tasks via the Claude Code CLI. It reads task definitions from `task.json`, executes each task with retry/timeout/budget controls, tracks state in `report.json`, and supports checkpoint-based resume.

## Architecture

```
run.sh (Orchestrator)
  ├── Reads task.json (immutable config)
  ├── Spawns `claude` CLI per task in projects/ directory
  ├── Appends results atomically to report.json
  └── Logs to logs/
```

**Key design patterns:**
- **Checkpoint resume**: `report.json` tracks completed tasks; restarting `run.sh` skips successes
- **Atomic writes**: temp file + `mv` for report updates
- **Working directory isolation**: tasks execute inside `projects/`
- **No session persistence**: each Claude invocation is independent (`--no-session-persistence`)

## Running

```bash
# Dry-run (no Claude CLI needed)
./run.sh --dry-run

# Real execution (requires claude CLI + jq)
./run.sh
```

**Dependencies**: bash 4.0+, jq, claude CLI, GNU timeout

## File Roles

| File | Purpose |
|------|---------|
| `run.sh` | Main orchestrator script (~380 lines) |
| `task.json` | Task definitions with config (max_retries, timeout_seconds, max_budget_usd) |
| `report.json` | Execution state array (append-only during runs) |
| `开发指导说明书.md` | Developer guide with task/report JSON schemas |
| `logs/` | Run logs (`run_*.log`) and task outputs (`task-*_attempt*.json`) |
| `projects/` | Isolated working directory for Claude task execution |

## Task/Report Schemas

**task.json** tasks have: `id` (format `task-NNN`), `title`, `prompt`

**report.json** records have: `task_id`, `status` ("success"/"failure"/"timeout"), `attempt`, `started_at`, `finished_at`, `duration_seconds`, `exit_code`, `error_message`

## Exit Codes

- `0` → success
- `124` → timeout (GNU timeout)
- Other → failure (triggers retry up to `max_retries`)

## Conventions

- Shell scripts use LF line endings (enforced via `.gitattributes`)
- `logs/`, `*.tmp`, `.prompt.tmp` are gitignored
- Task IDs follow `task-NNN` pattern
- Only `status: "success"` marks a task complete; failures are retryable
