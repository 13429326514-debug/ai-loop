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
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
fi

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

  log "Config: max_retries=$MAX_RETRIES, timeout=${TIMEOUT_SECONDS}s, budget=\$${MAX_BUDGET_USD}"
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
  local attempts
  attempts=$(get_attempt_count "$task_id")
  if [[ $attempts -ge $MAX_RETRIES ]]; then
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
# Execute a single task with retries
# ------------------------------------------------------------------------------
execute_task() {
  local task_id="$1"
  local task_title="$2"
  local task_prompt="$3"

  local existing_attempts
  existing_attempts=$(get_attempt_count "$task_id")

  log "--- Executing task: $task_id ($task_title) ---"
  log "Previous attempts: $existing_attempts"

  local attempt
  for (( attempt = existing_attempts + 1; attempt <= existing_attempts + MAX_RETRIES; attempt++ )); do
    log "Attempt $attempt / $((existing_attempts + MAX_RETRIES)) for $task_id"

    local started_at
    started_at=$(date -Iseconds)
    local start_epoch
    start_epoch=$(date +%s)

    local output_file="$LOGS_DIR/${task_id}_attempt${attempt}_${TIMESTAMP}.json"
    local exit_code=0

    if [[ "$DRY_RUN" == true ]]; then
      # Dry-run: simulate execution
      log "[DRY-RUN] Would execute claude with prompt for $task_id"
      log "[DRY-RUN] Prompt (first 100 chars): ${task_prompt:0:100}..."
      echo '{"dry_run": true}' > "$output_file"
      exit_code=0
    else
      # Write prompt to temp file to avoid shell escaping issues
      local prompt_tmp="$SCRIPT_DIR/.prompt.tmp"
      printf '%s' "$task_prompt" > "$prompt_tmp"

      # Execute claude in projects/ directory (tee to both terminal and log file)
      set +e
      timeout "$TIMEOUT_SECONDS" claude -p "$(cat "$prompt_tmp")" \
        --dangerously-skip-permissions \
        --max-budget-usd "$MAX_BUDGET_USD" \
        --no-session-persistence \
        2>&1 <<< "" | tee "$output_file"
      exit_code=${PIPESTATUS[0]}
      set -e

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
      error_message="Timed out after ${TIMEOUT_SECONDS}s"
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

    # If not the last attempt, wait before retry
    if [[ $attempt -lt $((existing_attempts + MAX_RETRIES)) ]]; then
      log "Waiting 5s before retry..."
      sleep 5
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

      # Check if this task is already completed
      if echo "$completed_ids" | grep -qx "$task_id" 2>/dev/null; then
        log "Skipping completed task: $task_id"
        continue
      fi

      # Check if retries exhausted for this task
      if is_task_exhausted "$task_id"; then
        log "Skipping exhausted task: $task_id (attempts >= $MAX_RETRIES)"
        continue
      fi

      local task_title
      task_title=$(jq -r ".tasks[$i].title" "$TASK_FILE")
      local task_prompt
      task_prompt=$(jq -r ".tasks[$i].prompt" "$TASK_FILE")

      found=true

      # Execute the task (failures don't stop the loop)
      if [[ "$DRY_RUN" == true ]]; then
        execute_task "$task_id" "$task_title" "$task_prompt" || true
      else
        cd "$PROJECTS_DIR"
        execute_task "$task_id" "$task_title" "$task_prompt" || true
        cd "$SCRIPT_DIR"
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
