# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

AI Auto-Loop System — a bash-based orchestrator that executes sequential AI tasks via the Claude Code CLI. It reads task definitions from `task.json`, executes each task with retry/timeout/budget controls, tracks state in `report.json`, and supports checkpoint-based resume.

## Architecture

```
run.sh (Orchestrator)
  ├── Reads task.json (immutable config + system_prompt)
  ├── Generates projects/<name>/CLAUDE.md per task (context injection)
  ├── Spawns `claude` CLI per task in projects/ directory
  ├── Appends results atomically to report.json
  ├── Generates summary.md on completion
  └── Logs to logs/
```

**Key design patterns:**
- **Checkpoint resume**: `report.json` tracks completed tasks; restarting `run.sh` skips successes
- **Atomic writes**: temp file + `mv` for report updates
- **Working directory isolation**: tasks execute inside `projects/`
- **No session persistence**: each Claude invocation is independent (`--no-session-persistence`)
- **Task-level config override**: each task can override timeout/budget/retries
- **System prompt injection**: `system_prompt` auto-appended to every task prompt
- **Exponential backoff**: retry wait = 5 * 2^(n-1) seconds, capped at 60s
- **Graceful push degradation**: missing `gh` CLI degrades to local-git-only mode

## Running

```bash
# Dry-run (no Claude CLI needed)
./run.sh --dry-run

# Real execution (requires claude CLI + jq)
./run.sh

# Interactive mode (manual control per task)
./run.sh --interactive

# Skip git push (local commits only)
./run.sh --skip-push
```

**Dependencies**: bash 4.0+, jq, claude CLI, GNU timeout
**Optional**: gh CLI (for GitHub remote repo creation + push)

## File Roles

| File | Purpose |
|------|---------|
| `run.sh` | Main orchestrator script |
| `task.json` | Task definitions with config, system_prompt, per-task overrides |
| `report.json` | Execution state array (append-only during runs) |
| `summary.md` | Generated execution summary with per-task status table |
| `开发指导说明书.md` | Developer guide with task/report JSON schemas |
| `logs/` | Run logs (`run_*.log`) and task outputs (`task-*_attempt*.json`) |
| `projects/` | Isolated working directory for Claude task execution |

## Task/Report Schemas

**task.json** top-level: `version`, `project_name`, `system_prompt` (optional), `config`, `tasks[]`

**task.json** tasks have: `id` (format `task-NNN`), `title`, `prompt`, and optional overrides: `timeout_seconds`, `max_budget_usd`, `max_retries`

**report.json** records have: `task_id`, `task_title`, `status` ("success"/"failure"/"timeout"), `attempt`, `started_at`, `finished_at`, `duration_seconds`, `exit_code`, `error_message`

## Exit Codes

- `0` → success
- `124` → timeout (GNU timeout)
- Other → failure (triggers retry with exponential backoff up to `max_retries`)

## Conventions

- Shell scripts use LF line endings (enforced via `.gitattributes`)
- `logs/`, `*.tmp`, `.prompt.tmp`, `summary.md` are gitignored
- Task IDs follow `task-NNN` pattern
- Only `status: "success"` marks a task complete; failures are retryable
