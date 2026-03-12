# ai-loop

Bash-based orchestrator that executes sequential AI tasks via Claude Code CLI — with automatic retry, resume, Git commit/push, and optional interactive mode.

## Features

- **Task Queue**: Define tasks in `task.json`, execute them sequentially
- **Auto Retry**: Configurable retry count, timeout, and budget per task
- **Checkpoint Resume**: Interrupted? Restart and it picks up where it left off
- **GitHub Integration**: Auto-create remote repo, commit & push after each task
- **Two Modes**:
  - `./run.sh` — Fully automatic, no human intervention
  - `./run.sh --interactive` — Native Claude Code UI, you can chat mid-task
- **Dry Run**: `./run.sh --dry-run` to test without calling Claude

## Quick Start

### Prerequisites

| Tool | Install |
|------|---------|
| bash 4.0+ | Git Bash (Windows) or native (Linux/Mac) |
| [jq](https://jqlang.github.io/jq/) | `winget install jqlang.jq` / `brew install jq` |
| [Claude Code CLI](https://claude.ai/code) | `npm install -g @anthropic-ai/claude-code` |
| [GitHub CLI](https://cli.github.com/) | `winget install GitHub.cli` then `gh auth login` |

### Define Tasks

Edit `task.json`:

```json
{
  "version": "1.0.0",
  "project_name": "my-project",
  "config": {
    "max_retries": 2,
    "timeout_seconds": 300,
    "max_budget_usd": 1.0
  },
  "tasks": [
    {
      "id": "task-001",
      "title": "Create hello world",
      "prompt": "Create hello.py that prints Hello World. Run it to verify."
    }
  ]
}
```

### Run

```bash
# Fully automatic
./run.sh

# Interactive — chat with Claude mid-task
./run.sh --interactive

# Test without calling Claude
./run.sh --dry-run
```

## How It Works

```
run.sh
 ├── Read task.json
 ├── Create GitHub repo (from project_name)
 ├── For each task:
 │   ├── Spawn Claude Code CLI in projects/<project_name>/
 │   ├── On success → git commit + push
 │   └── On failure → retry (up to max_retries)
 ├── Track state in report.json
 └── Print summary
```

## File Structure

```
ai-loop/
├── run.sh              # Main orchestrator
├── task.json           # Task definitions (input)
├── report.json         # Execution state (output)
├── CLAUDE.md           # Claude Code context
├── 开发指导说明书.md     # Developer guide (Chinese)
├── projects/           # Working directory for tasks (gitignored)
└── logs/               # Execution logs (gitignored)
```

## Configuration

| Field | Default | Description |
|-------|---------|-------------|
| `project_name` | (required) | GitHub repo name & project directory |
| `max_retries` | 2 | Max attempts per task |
| `timeout_seconds` | 300 | Per-task timeout (auto mode only) |
| `max_budget_usd` | 1.0 | API spend limit per task |

## License

MIT
