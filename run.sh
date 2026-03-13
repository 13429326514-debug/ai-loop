#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# AI Auto-Loop System - run.sh
# Sequentially executes tasks defined in task.json using Claude Code CLI,
# records results to report.json, supports resume and retry.
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASK_FILE="$SCRIPT_DIR/task.json"
REPORT_FILE="$SCRIPT_DIR/report.json"
PROJECTS_DIR="$SCRIPT_DIR/projects"
LOGS_DIR="$SCRIPT_DIR/logs"

# Ensure Claude CLI can find git-bash on Windows
if [[ -z "${CLAUDE_CODE_GIT_BASH_PATH:-}" ]]; then
  # Try common locations (Unix path style for bash)
  for candidate in \
    "/c/Program Files/Git/bin/bash.exe" \
    "/c/Program Files (x86)/Git/bin/bash.exe" \
    "/e/Git/bin/bash.exe"; do
    if [[ -f "$candidate" ]]; then
      # Claude CLI needs Windows-style path
      export CLAUDE_CODE_GIT_BASH_PATH
      CLAUDE_CODE_GIT_BASH_PATH=$(cygpath -w "$candidate")
      break
    fi
  done
fi

DRY_RUN=false
INTERACTIVE=false
SKIP_PUSH=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)      DRY_RUN=true ;;
    --interactive)  INTERACTIVE=true ;;
    --skip-push)    SKIP_PUSH=true ;;
  esac
  shift
done

# ------------------------------------------------------------------------------
# Logging helpers
# ------------------------------------------------------------------------------
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
mkdir -p "$LOGS_DIR"
RUN_LOG="$LOGS_DIR/run_${TIMESTAMP}.log"

log() {
  local msg
  msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "$msg" | tee -a "$RUN_LOG"
}

log_error() {
  local msg
  msg="[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*"
  echo "$msg" >&2 | tee -a "$RUN_LOG"
}

# ------------------------------------------------------------------------------
# Initialization checks
# ------------------------------------------------------------------------------
init() {
  log "=== AI Auto-Loop System Starting ==="
  log "Script dir: $SCRIPT_DIR"
  log "Dry-run mode: $DRY_RUN"
  log "Interactive mode: $INTERACTIVE"
  log "Skip push: $SKIP_PUSH"

  # Check jq
  if ! command -v jq &>/dev/null; then
    log_error "jq is not installed. Please install jq first."
    exit 1
  fi
  log "jq found: $(command -v jq)"

  # Check claude (skip in dry-run)
  if [[ "$DRY_RUN" == false ]]; then
    if ! command -v claude &>/dev/null; then
      log_error "claude CLI is not installed or not in PATH."
      exit 1
    fi
    log "claude found: $(command -v claude)"
  else
    log "Dry-run: skipping claude CLI check"
  fi

  # Check task.json
  if [[ ! -f "$TASK_FILE" ]]; then
    log_error "task.json not found at: $TASK_FILE"
    exit 1
  fi

  # Validate task.json is valid JSON
  if ! jq empty "$TASK_FILE" 2>/dev/null; then
    log_error "task.json is not valid JSON"
    exit 1
  fi

  # Validate required fields
  local task_count
  task_count=$(jq '.tasks | length' "$TASK_FILE")
  if [[ "$task_count" -eq 0 ]]; then
    log_error "task.json has no tasks defined"
    exit 1
  fi
  log "task.json loaded: $task_count task(s)"

  # Initialize report.json if missing
  if [[ ! -f "$REPORT_FILE" ]]; then
    echo "[]" > "$REPORT_FILE"
    log "report.json created (empty)"
  fi

  # Validate report.json
  if ! jq empty "$REPORT_FILE" 2>/dev/null; then
    log_error "report.json is not valid JSON, resetting to []"
    echo "[]" > "$REPORT_FILE"
  fi

  # Create projects directory
  mkdir -p "$PROJECTS_DIR"
  log "projects/ directory ready"

  log "Initialization complete"
}

# ------------------------------------------------------------------------------
# Read config from task.json
# ------------------------------------------------------------------------------
read_config() {
  MAX_RETRIES=$(jq -r '.config.max_retries // 2' "$TASK_FILE")
  TIMEOUT_SECONDS=$(jq -r '.config.timeout_seconds // 300' "$TASK_FILE")
  MAX_BUDGET_USD=$(jq -r '.config.max_budget_usd // 1.0' "$TASK_FILE")
  PROJECT_NAME=$(jq -r '.project_name // ""' "$TASK_FILE")
  SYSTEM_PROMPT=$(jq -r '.system_prompt // ""' "$TASK_FILE")

  if [[ -z "$PROJECT_NAME" ]]; then
    log_error "project_name is required in task.json"
    exit 1
  fi

  PROJECT_DIR="$PROJECTS_DIR/$PROJECT_NAME"
  log "Config: max_retries=$MAX_RETRIES, timeout=${TIMEOUT_SECONDS}s, budget=\$${MAX_BUDGET_USD}"
  log "Project: $PROJECT_NAME"
  if [[ -n "$SYSTEM_PROMPT" ]]; then
    log "System prompt: $(echo "$SYSTEM_PROMPT" | head -c 80)..."
  fi
}

# ------------------------------------------------------------------------------
# Initialize GitHub remote repository and local git for the project
# ------------------------------------------------------------------------------
init_git_repo() {
  if [[ "$DRY_RUN" == true ]]; then
    log "[DRY-RUN] Would create GitHub repo: $PROJECT_NAME"
    return 0
  fi

  mkdir -p "$PROJECT_DIR"

  # Check if already a git repo with remote
  if [[ -d "$PROJECT_DIR/.git" ]]; then
    local has_remote
    has_remote=$(cd "$PROJECT_DIR" && git remote -v 2>/dev/null | grep -c origin || true)
    if [[ "$has_remote" -gt 0 ]]; then
      log "Git repo already initialized with remote for $PROJECT_NAME"
      return 0
    fi
  fi

  # Check gh CLI
  if ! command -v gh &>/dev/null; then
    log "WARNING: ⚠ gh (GitHub CLI) not found. Running in local-git-only mode (no push)."
    SKIP_PUSH=true
    # Still init local git
    mkdir -p "$PROJECT_DIR"
    cd "$PROJECT_DIR"
    if [[ ! -d ".git" ]]; then
      git init
      log "Local git repo initialized in $PROJECT_DIR (no remote)"
    fi
    cd "$SCRIPT_DIR"
    return 0
  fi

  # Get GitHub username
  local gh_user
  gh_user=$(gh api user --jq '.login' 2>/dev/null)
  if [[ -z "$gh_user" ]]; then
    log_error "Failed to get GitHub username. Run 'gh auth login' first."
    exit 1
  fi
  log "GitHub user: $gh_user"

  # Create remote repo if not exists
  if ! gh repo view "$gh_user/$PROJECT_NAME" &>/dev/null; then
    log "Creating private GitHub repo: $gh_user/$PROJECT_NAME"
    gh repo create "$PROJECT_NAME" --private --confirm 2>/dev/null || \
    gh repo create "$PROJECT_NAME" --private 2>/dev/null
    log "GitHub repo created: $gh_user/$PROJECT_NAME"
  else
    log "GitHub repo already exists: $gh_user/$PROJECT_NAME"
  fi

  # Init local git repo
  cd "$PROJECT_DIR"
  if [[ ! -d ".git" ]]; then
    git init
    log "Local git repo initialized in $PROJECT_DIR"
  fi

  # Set remote
  local remote_url="https://github.com/$gh_user/$PROJECT_NAME.git"
  if ! git remote get-url origin &>/dev/null; then
    git remote add origin "$remote_url"
    log "Remote origin set to: $remote_url"
  fi

  cd "$SCRIPT_DIR"
}

# ------------------------------------------------------------------------------
# Commit and push after a successful task
# ------------------------------------------------------------------------------
git_commit_and_push() {
  local task_id="$1"
  local task_title="$2"

  if [[ "$DRY_RUN" == true ]]; then
    log "[DRY-RUN] Would commit and push for $task_id"
    return 0
  fi

  cd "$PROJECT_DIR"

  # Check if there are changes to commit
  if [[ -z "$(git status --porcelain 2>/dev/null)" ]]; then
    log "No changes to commit for $task_id"
    cd "$SCRIPT_DIR"
    return 0
  fi

  git add -A
  git commit -m "feat($task_id): $task_title"
  log "Committed: feat($task_id): $task_title"

  # Push (create main branch on first push if needed)
  if [[ "$SKIP_PUSH" == true ]]; then
    log "Push skipped (--skip-push or no remote configured)"
    cd "$SCRIPT_DIR"
    return 0
  fi

  local current_branch
  current_branch=$(git branch --show-current 2>/dev/null || echo "main")
  if [[ -z "$current_branch" ]]; then
    current_branch="main"
    git checkout -b main
  fi

  git push -u origin "$current_branch" 2>&1 || {
    log "WARNING: ⚠ Push failed for $task_id. Changes are committed locally but NOT pushed to remote."
    log "WARNING: ⚠ You may need to push manually: cd $PROJECT_DIR && git push"
    cd "$SCRIPT_DIR"
    return 0
  }
  log "Pushed to origin/$current_branch"

  cd "$SCRIPT_DIR"
}

# ------------------------------------------------------------------------------
# Get list of successfully completed task IDs from report.json
# ------------------------------------------------------------------------------
get_completed_ids() {
  jq -r '[.[] | select(.status == "success") | .task_id] | unique | .[]' "$REPORT_FILE" 2>/dev/null || true
}

# ------------------------------------------------------------------------------
# Check if a task has exhausted all retries (no success, attempts >= max_retries)
# ------------------------------------------------------------------------------
is_task_exhausted() {
  local task_id="$1"
  local task_max_retries="${2:-$MAX_RETRIES}"
  local attempts
  attempts=$(get_attempt_count "$task_id")
  if [[ $attempts -ge $task_max_retries ]]; then
    return 0
  fi
  return 1
}

# ------------------------------------------------------------------------------
# Get the current attempt count for a given task_id from report.json
# ------------------------------------------------------------------------------
get_attempt_count() {
  local task_id="$1"
  jq --arg id "$task_id" '[.[] | select(.task_id == $id)] | length' "$REPORT_FILE" 2>/dev/null || echo "0"
}

# ------------------------------------------------------------------------------
# Append a record to report.json (atomic: write tmp then mv)
# ------------------------------------------------------------------------------
append_report() {
  local task_id="$1"
  local task_title="$2"
  local status="$3"
  local attempt="$4"
  local started_at="$5"
  local finished_at="$6"
  local duration="$7"
  local exit_code="$8"
  local error_message="${9:-null}"

  local tmp_file="${REPORT_FILE}.tmp"

  # Build the new record
  local record
  if [[ "$error_message" == "null" ]]; then
    record=$(jq -n \
      --arg tid "$task_id" \
      --arg ttl "$task_title" \
      --arg st "$status" \
      --argjson att "$attempt" \
      --arg sa "$started_at" \
      --arg fa "$finished_at" \
      --argjson dur "$duration" \
      --argjson ec "$exit_code" \
      '{
        task_id: $tid,
        task_title: $ttl,
        status: $st,
        attempt: $att,
        started_at: $sa,
        finished_at: $fa,
        duration_seconds: $dur,
        exit_code: $ec,
        error_message: null
      }')
  else
    record=$(jq -n \
      --arg tid "$task_id" \
      --arg ttl "$task_title" \
      --arg st "$status" \
      --argjson att "$attempt" \
      --arg sa "$started_at" \
      --arg fa "$finished_at" \
      --argjson dur "$duration" \
      --argjson ec "$exit_code" \
      --arg em "$error_message" \
      '{
        task_id: $tid,
        task_title: $ttl,
        status: $st,
        attempt: $att,
        started_at: $sa,
        finished_at: $fa,
        duration_seconds: $dur,
        exit_code: $ec,
        error_message: $em
      }')
  fi

  # Atomic append: read existing + new record -> tmp -> mv
  jq --argjson rec "$record" '. + [$rec]' "$REPORT_FILE" > "$tmp_file"
  mv "$tmp_file" "$REPORT_FILE"

  log "Report appended: task=$task_id status=$status attempt=$attempt"
}

# ------------------------------------------------------------------------------
# Generate CLAUDE.md in the project directory for context
# ------------------------------------------------------------------------------
generate_project_claude_md() {
  local task_id="$1"
  local task_title="$2"
  local claude_md="$PROJECT_DIR/CLAUDE.md"

  mkdir -p "$PROJECT_DIR"

  {
    echo "# CLAUDE.md"
    echo ""
    echo "Project: $PROJECT_NAME"
    echo "Current task: $task_id - $task_title"
    echo ""
    if [[ -n "$SYSTEM_PROMPT" ]]; then
      echo "## Development Guidelines"
      echo ""
      echo "$SYSTEM_PROMPT"
      echo ""
    fi
    echo "## Completed Tasks"
    echo ""
    if [[ -f "$REPORT_FILE" ]]; then
      local completed
      completed=$(jq -r '.[] | select(.status == "success") | "- \(.task_id): \(.task_title)"' "$REPORT_FILE" 2>/dev/null || true)
      if [[ -n "$completed" ]]; then
        echo "$completed"
      else
        echo "(none yet)"
      fi
    else
      echo "(none yet)"
    fi
  } > "$claude_md"

  log "Generated CLAUDE.md for $task_id in $PROJECT_DIR"
}

# ------------------------------------------------------------------------------
# Execute a single task with retries
# ------------------------------------------------------------------------------
execute_task() {
  local task_id="$1"
  local task_title="$2"
  local task_prompt="$3"
  local task_timeout="${4:-$TIMEOUT_SECONDS}"
  local task_budget="${5:-$MAX_BUDGET_USD}"
  local task_retries="${6:-$MAX_RETRIES}"

  local existing_attempts
  existing_attempts=$(get_attempt_count "$task_id")

  log "--- Executing task: $task_id ($task_title) ---"
  log "Previous attempts: $existing_attempts"
  log "Task config: timeout=${task_timeout}s, budget=\$${task_budget}, retries=$task_retries"

  # Append system_prompt to task prompt if configured
  local full_prompt="$task_prompt"
  if [[ -n "$SYSTEM_PROMPT" ]]; then
    full_prompt="${task_prompt}\n\n--- System Instructions ---\n${SYSTEM_PROMPT}"
  fi

  local attempt
  for (( attempt = existing_attempts + 1; attempt <= existing_attempts + task_retries; attempt++ )); do
    log "Attempt $attempt / $((existing_attempts + task_retries)) for $task_id"

    local started_at
    started_at=$(date -Iseconds)
    local start_epoch
    start_epoch=$(date +%s)

    local output_file="$LOGS_DIR/${task_id}_attempt${attempt}_${TIMESTAMP}.json"
    local exit_code=0

    if [[ "$DRY_RUN" == true ]]; then
      # Dry-run: simulate execution
      log "[DRY-RUN] Would execute claude with prompt for $task_id"
      log "[DRY-RUN] Prompt (first 100 chars): ${full_prompt:0:100}..."
      log "[DRY-RUN] Timeout: ${task_timeout}s, Budget: \$${task_budget}"
      echo '{"dry_run": true}' > "$output_file"
      exit_code=0
    else
      # Write prompt to temp file to avoid shell escaping issues
      local prompt_tmp="$SCRIPT_DIR/.prompt.tmp"
      printf '%b' "$full_prompt" > "$prompt_tmp"

      if [[ "$INTERACTIVE" == true ]]; then
        # Interactive mode: open native Claude Code session
        log "[INTERACTIVE] Starting Claude Code for $task_id — exit with /exit when done"
        echo ""
        echo "========================================"
        echo "  Task: $task_id ($task_title)"
        echo "  Mode: Interactive — you can chat, modify, give feedback"
        echo "  Exit: type /exit when you are done"
        echo "========================================"
        echo ""

        set +e
        claude --init-prompt "$(cat "$prompt_tmp")" \
          --dangerously-skip-permissions \
          --max-budget-usd "$task_budget"
        exit_code=$?
        set -e
      else
        # Auto mode: non-interactive execution (tee to both terminal and log file)
        set +e
        timeout "$task_timeout" claude -p "$(cat "$prompt_tmp")" \
          --dangerously-skip-permissions \
          --max-budget-usd "$task_budget" \
          --no-session-persistence \
          2>&1 <<< "" | tee "$output_file"
        exit_code=${PIPESTATUS[0]}
        set -e
      fi

      # Clean up temp file
      rm -f "$prompt_tmp"
    fi

    local end_epoch
    end_epoch=$(date +%s)
    local finished_at
    finished_at=$(date -Iseconds)
    local duration=$(( end_epoch - start_epoch ))

    # Determine status
    local status
    local error_message="null"

    if [[ $exit_code -eq 0 ]]; then
      status="success"
      log "Task $task_id succeeded (attempt $attempt, ${duration}s)"
    elif [[ $exit_code -eq 124 ]]; then
      status="timeout"
      error_message="Timed out after ${task_timeout}s"
      log "Task $task_id timed out (attempt $attempt, ${duration}s)"
    else
      status="failure"
      error_message="Exit code: $exit_code"
      log "Task $task_id failed with exit code $exit_code (attempt $attempt, ${duration}s)"
    fi

    # Append to report
    append_report "$task_id" "$task_title" "$status" "$attempt" \
      "$started_at" "$finished_at" "$duration" "$exit_code" "$error_message"

    # If success, break out of retry loop
    if [[ "$status" == "success" ]]; then
      return 0
    fi

    # If not the last attempt, wait with exponential backoff
    if [[ $attempt -lt $((existing_attempts + task_retries)) ]]; then
      local retry_num=$(( attempt - existing_attempts ))
      local wait_time=$(( 5 * (1 << (retry_num - 1)) ))
      if [[ $wait_time -gt 60 ]]; then wait_time=60; fi
      log "Waiting ${wait_time}s before retry (exponential backoff)..."
      sleep "$wait_time"
    fi
  done

  log "All retries exhausted for $task_id"
  return 1
}

# ------------------------------------------------------------------------------
# Print final summary
# ------------------------------------------------------------------------------
print_summary() {
  log "=== Execution Summary ==="

  local total success failure timeout_count
  total=$(jq 'length' "$REPORT_FILE")
  success=$(jq '[.[] | select(.status == "success")] | length' "$REPORT_FILE")
  failure=$(jq '[.[] | select(.status == "failure")] | length' "$REPORT_FILE")
  timeout_count=$(jq '[.[] | select(.status == "timeout")] | length' "$REPORT_FILE")

  local task_total
  task_total=$(jq '.tasks | length' "$TASK_FILE")
  local completed_tasks
  completed_tasks=$(jq -r '[.[] | select(.status == "success") | .task_id] | unique | length' "$REPORT_FILE")

  log "Tasks: $completed_tasks / $task_total completed"
  log "Records: $total total ($success success, $failure failure, $timeout_count timeout)"

  # Per-task status table
  log ""
  log "Task Details:"
  log "  ID          | Status   | Attempts | Duration"
  log "  ------------|----------|----------|--------"

  local summary_md="$SCRIPT_DIR/summary.md"
  {
    echo "# Execution Summary"
    echo ""
    echo "- Project: $PROJECT_NAME"
    echo "- Date: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "- Tasks: $completed_tasks / $task_total completed"
    echo "- Records: $total total ($success success, $failure failure, $timeout_count timeout)"
    echo ""
    echo "## Task Details"
    echo ""
    echo "| ID | Title | Status | Attempts | Duration |"
    echo "|---|---|---|---|---|"
  } > "$summary_md"

  for (( i = 0; i < task_total; i++ )); do
    local tid ttl tst att dur
    tid=$(jq -r ".tasks[$i].id" "$TASK_FILE")
    ttl=$(jq -r ".tasks[$i].title" "$TASK_FILE")
    tst=$(jq -r --arg id "$tid" '[.[] | select(.task_id == $id)] | last | .status // "pending"' "$REPORT_FILE")
    att=$(jq -r --arg id "$tid" '[.[] | select(.task_id == $id)] | length' "$REPORT_FILE")
    dur=$(jq -r --arg id "$tid" '[.[] | select(.task_id == $id)] | last | .duration_seconds // 0' "$REPORT_FILE")

    log "  $tid | $tst | $att | ${dur}s"
    echo "| $tid | $ttl | $tst | $att | ${dur}s |" >> "$summary_md"
  done

  log ""
  log "Summary saved to: $summary_md"
  log "Report: $REPORT_FILE"
  log "Logs: $LOGS_DIR"
  log "=== Done ==="
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
main() {
  init
  read_config
  init_git_repo

  local task_count
  task_count=$(jq '.tasks | length' "$TASK_FILE")

  while true; do
    # Get completed task IDs
    local completed_ids
    completed_ids=$(get_completed_ids)

    # Find first uncompleted task
    local found=false
    local i

    for (( i = 0; i < task_count; i++ )); do
      local task_id
      task_id=$(jq -r ".tasks[$i].id" "$TASK_FILE")

      # Read task-level config overrides (fallback to global)
      local task_timeout task_budget task_retries
      task_timeout=$(jq -r ".tasks[$i].timeout_seconds // $TIMEOUT_SECONDS" "$TASK_FILE")
      task_budget=$(jq -r ".tasks[$i].max_budget_usd // $MAX_BUDGET_USD" "$TASK_FILE")
      task_retries=$(jq -r ".tasks[$i].max_retries // $MAX_RETRIES" "$TASK_FILE")

      # Check if this task is already completed
      if echo "$completed_ids" | grep -qx "$task_id" 2>/dev/null; then
        log "Skipping completed task: $task_id"
        continue
      fi

      # Check if retries exhausted for this task
      if is_task_exhausted "$task_id" "$task_retries"; then
        log "Skipping exhausted task: $task_id (attempts >= $task_retries)"
        continue
      fi

      local task_title
      task_title=$(jq -r ".tasks[$i].title" "$TASK_FILE")
      local task_prompt
      task_prompt=$(jq -r ".tasks[$i].prompt" "$TASK_FILE")

      found=true

      # Generate project CLAUDE.md for context
      generate_project_claude_md "$task_id" "$task_title"

      # Execute the task (failures don't stop the loop)
      local task_result=0
      if [[ "$DRY_RUN" == true ]]; then
        execute_task "$task_id" "$task_title" "$task_prompt" "$task_timeout" "$task_budget" "$task_retries" || task_result=$?
      else
        cd "$PROJECT_DIR"
        execute_task "$task_id" "$task_title" "$task_prompt" "$task_timeout" "$task_budget" "$task_retries" || task_result=$?
        cd "$SCRIPT_DIR"
      fi

      # Commit and push on success
      if [[ $task_result -eq 0 ]]; then
        git_commit_and_push "$task_id" "$task_title"
      fi

      # In interactive mode, prompt user before next task
      if [[ "$INTERACTIVE" == true && "$DRY_RUN" == false ]]; then
        echo ""
        echo "========================================"
        echo "  Task $task_id finished."
        echo "  Press Enter to continue next task, or q to quit."
        echo "========================================"
        read -r user_input
        if [[ "$user_input" == "q" || "$user_input" == "Q" ]]; then
          log "User chose to quit after $task_id"
          break 2  # break both for and while loops
        fi
      fi

      # Break inner for-loop to re-check completed list from the top
      break
    done

    # If no uncompleted task found, we're done
    if [[ "$found" == false ]]; then
      log "All tasks completed or exhausted retries."
      break
    fi
  done

  print_summary
}

main "$@"
