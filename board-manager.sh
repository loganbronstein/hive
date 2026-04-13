#!/usr/bin/env bash
# Hive Task Board Manager
# Usage: source board-manager.sh, then call board_add, board_claim, board_complete, board_next, board_status

BOARD="$HOME/.claude/dispatcher/task-board.md"

_is_task_line() {
  echo "$1" | grep -q '^- \[P[0-3]\]'
}

_get_priority_num() {
  echo "$1" | sed -n 's/^- \[P\([0-3]\)\].*/\1/p'
}

board_add() {
  local priority="$1"
  shift
  local description="$*"

  if [[ -z "$priority" || -z "$description" ]]; then
    echo "Usage: board_add <P0|P1|P2|P3> <description>"
    return 1
  fi

  if [[ ! "$priority" =~ ^P[0-3]$ ]]; then
    echo "Invalid priority. Use P0 (urgent), P1 (high), P2 (medium), P3 (low)"
    return 1
  fi

  local queue_line=$(grep -n "^## Queue" "$BOARD" | head -1 | cut -d: -f1)
  local inprog_line=$(grep -n "^## In Progress" "$BOARD" | head -1 | cut -d: -f1)

  if [[ -z "$queue_line" || -z "$inprog_line" ]]; then
    echo "ERROR: Board file is malformed."
    return 1
  fi

  local new_task="- [$priority] $description [assigned: none]"
  local task_priority_num="${priority:1:1}"
  local insert_before=""

  for line_num in $(seq $((queue_line + 1)) $((inprog_line - 1))); do
    local line=$(sed -n "${line_num}p" "$BOARD")
    local existing_num=$(_get_priority_num "$line")
    if [[ -n "$existing_num" ]] && (( task_priority_num < existing_num )); then
      insert_before=$line_num
      break
    fi
  done

  if [[ -n "$insert_before" ]]; then
    sed -i '' "${insert_before}i\\
${new_task}
" "$BOARD"
  else
    # Insert right before "## In Progress" line
    local current_inprog=$(grep -n "^## In Progress" "$BOARD" | head -1 | cut -d: -f1)
    sed -i '' "${current_inprog}i\\
${new_task}
" "$BOARD"
  fi

  echo "Added to queue: [$priority] $description"
}

board_claim() {
  local worker="$1"
  if [[ -z "$worker" ]]; then
    echo "Usage: board_claim <worker-name>"
    return 1
  fi

  # Check if worker already has a task in progress
  local inprog_line=$(grep -n "^## In Progress" "$BOARD" | head -1 | cut -d: -f1)
  local done_line=$(grep -n "^## Done" "$BOARD" | head -1 | cut -d: -f1)
  for line_num in $(seq $((inprog_line + 1)) $((done_line - 1))); do
    local line=$(sed -n "${line_num}p" "$BOARD")
    if echo "$line" | grep -q "\[assigned: $worker\]"; then
      echo "Worker $worker already has a task: $line"
      echo "Complete it first with: board_complete $worker \"summary\""
      return 1
    fi
  done

  # Find the first unclaimed task in Queue
  local queue_line=$(grep -n "^## Queue" "$BOARD" | head -1 | cut -d: -f1)
  inprog_line=$(grep -n "^## In Progress" "$BOARD" | head -1 | cut -d: -f1)

  local task_line=""
  local task_num=""
  for line_num in $(seq $((queue_line + 1)) $((inprog_line - 1))); do
    local line=$(sed -n "${line_num}p" "$BOARD")
    if echo "$line" | grep -q '^\- \[P[0-3]\].*\[assigned: none\]'; then
      task_line="$line"
      task_num=$line_num
      break
    fi
  done

  if [[ -z "$task_line" ]]; then
    echo "No unclaimed tasks in queue."
    return 0
  fi

  # Remove from Queue
  sed -i '' "${task_num}d" "$BOARD"

  # Update assigned field
  local claimed_task=$(echo "$task_line" | sed "s/\[assigned: none\]/\[assigned: $worker\]/")

  # Insert after In Progress header (recalc after deletion)
  inprog_line=$(grep -n "^## In Progress" "$BOARD" | head -1 | cut -d: -f1)
  sed -i '' "${inprog_line}a\\
${claimed_task}
" "$BOARD"

  echo "Claimed by $worker: $claimed_task"
}

board_complete() {
  local worker="$1"
  shift
  local summary="$*"

  if [[ -z "$worker" ]]; then
    echo "Usage: board_complete <worker-name> [summary]"
    return 1
  fi

  local inprog_line=$(grep -n "^## In Progress" "$BOARD" | head -1 | cut -d: -f1)
  local done_line=$(grep -n "^## Done" "$BOARD" | head -1 | cut -d: -f1)

  local task_line=""
  local task_num=""
  for line_num in $(seq $((inprog_line + 1)) $((done_line - 1))); do
    local line=$(sed -n "${line_num}p" "$BOARD")
    if echo "$line" | grep -q "\[assigned: $worker\]"; then
      task_line="$line"
      task_num=$line_num
      break
    fi
  done

  if [[ -z "$task_line" ]]; then
    echo "No in-progress task found for worker: $worker"
    return 1
  fi

  # Remove from In Progress
  sed -i '' "${task_num}d" "$BOARD"

  # Build completed line
  local timestamp=$(date +"%I:%M %p")
  local completed_task=$(echo "$task_line" | sed "s/\[assigned: $worker\]/\[completed: $worker, $timestamp\]/")
  if [[ -n "$summary" ]]; then
    completed_task="$completed_task ($summary)"
  fi

  # Insert after Done header (recalc)
  done_line=$(grep -n "^## Done" "$BOARD" | head -1 | cut -d: -f1)
  sed -i '' "${done_line}a\\
${completed_task}
" "$BOARD"

  echo "Completed by $worker: $completed_task"
}

board_next() {
  local queue_line=$(grep -n "^## Queue" "$BOARD" | head -1 | cut -d: -f1)
  local inprog_line=$(grep -n "^## In Progress" "$BOARD" | head -1 | cut -d: -f1)

  for line_num in $(seq $((queue_line + 1)) $((inprog_line - 1))); do
    local line=$(sed -n "${line_num}p" "$BOARD")
    if echo "$line" | grep -q '^\- \[P[0-3]\].*\[assigned: none\]'; then
      echo "Next task: $line"
      return 0
    fi
  done

  echo "No unclaimed tasks in queue."
}

board_status() {
  local queue_count=$(sed -n '/^## Queue/,/^## In Progress/p' "$BOARD" | grep -c '^- \[P[0-3]\]')
  local inprog_count=$(sed -n '/^## In Progress/,/^## Done/p' "$BOARD" | grep -c '^- \[P[0-3]\]')
  local done_count=$(sed -n '/^## Done/,$p' "$BOARD" | grep -c '^- \[P[0-3]\]')

  echo "Task Board Status:"
  echo "  Queue:       $queue_count"
  echo "  In Progress: $inprog_count"
  echo "  Done:        $done_count"
  echo "  Total:       $((queue_count + inprog_count + done_count))"
}
