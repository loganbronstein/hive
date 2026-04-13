#!/usr/bin/env bash
# Hive Worker Monitor
# Source this file, then call check_and_report to get a structured summary
# of every active worker's state. Designed for the Hive coordinator terminal.
#
# Usage:
#   source ~/.claude/dispatcher/monitor-workers.sh
#   check_and_report        # full report
#   check_and_report quiet  # counts only, no per-worker detail

DISPATCHER_DIR="$HOME/.claude/dispatcher"

check_and_report() {
  local mode="${1:-full}"

  # Get all active workers via tmux (same method as dispatcher.sh list_workers)
  local workers_raw=""
  workers_raw=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^worker-' | sed 's/^worker-//' || true)

  if [[ -z "$workers_raw" ]]; then
    echo "No active workers."
    return 0
  fi

  # Convert to array (works in both bash and zsh)
  local workers=()
  while IFS= read -r w; do
    [[ -n "$w" ]] && workers+=("$w")
  done <<< "$workers_raw"

  local total=0
  local count_working=0
  local count_done=0
  local count_blocked=0
  local count_permission=0
  local count_idle=0
  local count_error=0
  local alerts=""

  echo "=== Worker Monitor Report $(date '+%H:%M:%S') ==="
  echo ""

  # Pre-declare variables outside the loop to avoid zsh typeset printing
  local output=""
  local wstate=""
  local detail=""
  local last_line=""

  for name in "${workers[@]}"; do
    total=$((total + 1))

    # Capture last 5 lines of output from the worker's tmux pane
    output=$(tmux capture-pane -t "worker-${name}" -p -S -5 2>/dev/null || echo "")

    # Detect worker state by scanning for patterns (priority order matters)
    wstate="WORKING"
    detail=""

    if echo "$output" | grep -qi 'Do you want to\|permission\|allow\|approve\|deny\|Y/n\|y/N\|(Y)es\|(N)o'; then
      wstate="PERMISSION_PROMPT"
      detail=$(echo "$output" | grep -i 'Do you want to\|permission\|allow\|approve\|deny\|Y/n\|y/N' | tail -1 | sed 's/^[[:space:]]*//')
      count_permission=$((count_permission + 1))
      alerts="${alerts}  ALERT: worker-${name} waiting on permission prompt\n"
    elif echo "$output" | grep -q 'BLOCKED:'; then
      wstate="BLOCKED"
      detail=$(echo "$output" | grep 'BLOCKED:' | tail -1 | sed 's/^.*BLOCKED: *//')
      count_blocked=$((count_blocked + 1))
      alerts="${alerts}  ALERT: worker-${name} is blocked: ${detail}\n"
    elif echo "$output" | grep -q 'ERROR:'; then
      wstate="ERROR"
      detail=$(echo "$output" | grep 'ERROR:' | tail -1 | sed 's/^.*ERROR: *//')
      count_error=$((count_error + 1))
      alerts="${alerts}  ALERT: worker-${name} has error: ${detail}\n"
    elif echo "$output" | grep -q 'DONE:'; then
      wstate="DONE"
      detail=$(echo "$output" | grep 'DONE:' | tail -1 | sed 's/^.*DONE: *//')
      count_done=$((count_done + 1))
    elif echo "$output" | grep -q 'IDLE'; then
      wstate="IDLE"
      count_idle=$((count_idle + 1))
    else
      count_working=$((count_working + 1))
    fi

    # Get last non-empty line of output for context
    last_line=$(echo "$output" | grep -v '^[[:space:]]*$' | tail -1 | sed 's/^[[:space:]]*//' | cut -c 1-120)
    [[ -z "$last_line" ]] && last_line="(no output)"

    if [[ "$mode" == "full" ]]; then
      printf "  %-20s [%-18s] %s\n" "worker-${name}" "$wstate" "$last_line"
      if [[ -n "$detail" && "$detail" != "$last_line" ]]; then
        printf "  %-20s  -> %s\n" "" "$detail"
      fi
    fi
  done

  echo ""
  echo "Totals: $total workers | $count_working working | $count_done done | $count_blocked blocked | $count_permission permission | $count_idle idle | $count_error error"

  if [[ -n "$alerts" ]]; then
    echo ""
    echo "ALERTS:"
    echo -e "$alerts"
  fi
}
