#!/usr/bin/env bash
# Hive Dispatcher v2
# One system for day and night. Opens/closes worker terminals via tmux.
# Logan talks to Hive. Hive talks to workers. Workers execute.

set -uo pipefail

DISPATCHER_DIR="$HOME/.claude/dispatcher"
PROMPTS_DIR="$DISPATCHER_DIR/worker-prompts"
LOG_FILE="$DISPATCHER_DIR/dispatcher.log"
QUEUE_FILE="$DISPATCHER_DIR/task-queue.md"
REPORT_FILE="$DISPATCHER_DIR/morning-report.md"
CLAUDE_BIN="$HOME/.local/bin/claude"
TEMPLATE_FILE="$DISPATCHER_DIR/prompt-template.sh"
MAX_WORKERS=10

# Load prompt template functions
if [[ -f "$TEMPLATE_FILE" ]]; then
    source "$TEMPLATE_FILE"
fi
HEALTH_CHECK_INTERVAL=600  # 10 minutes
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""

# Load Telegram config if available
if [[ -f "$HOME/.claude/channels/telegram/.env" ]]; then
    source "$HOME/.claude/channels/telegram/.env" 2>/dev/null || true
fi

# ============================================================
# LOGGING
# ============================================================

log() {
    local level="$1"
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" | tee -a "$LOG_FILE"
}

# ============================================================
# TELEGRAM
# ============================================================

telegram_send() {
    local message="$1"
    if [[ -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]]; then
        curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d "chat_id=${TELEGRAM_CHAT_ID}" \
            -d "text=${message}" \
            -d "parse_mode=Markdown" > /dev/null 2>&1 || true
    fi
    log "TELEGRAM" "$message"
}

# ============================================================
# WORKER MANAGEMENT
# ============================================================

create_worker() {
    local name="$1"
    local project_dir="${2:-$(pwd)}"

    # Check max workers
    local count
    count=$(list_workers | wc -l | tr -d ' ')
    if [[ "$count" -ge "$MAX_WORKERS" ]]; then
        log "ERROR" "Max workers ($MAX_WORKERS) reached. Close a worker first."
        return 1
    fi

    # Check if already exists
    if tmux has-session -t "worker-${name}" 2>/dev/null; then
        log "WARN" "Worker $name already exists"
        return 1
    fi

    # Build a readable display name from the worker name
    # e.g., "listflow-auth" becomes "ListFlow Auth"
    local display_name
    display_name=$(echo "$name" | sed 's/-/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))}1')

    # Open a visible Terminal.app window with a tmux session inside it
    # This way Logan can see the window on screen AND we can control it via tmux
    osascript -e "
        tell application \"Terminal\"
            activate
            set newTab to do script \"cd '$project_dir' && tmux new-session -s 'worker-${name}' -n '${display_name}'\"
            set custom title of front window to \"${display_name}\"
        end tell
    " 2>/dev/null

    # Wait for tmux session to be ready
    sleep 2

    # Set tmux status bar to show the display name prominently
    tmux set-option -t "worker-${name}" status-left " ${display_name} " 2>/dev/null || true
    tmux set-option -t "worker-${name}" status-left-length 40 2>/dev/null || true
    tmux set-option -t "worker-${name}" status-style "bg=colour235,fg=colour214" 2>/dev/null || true
    tmux set-option -t "worker-${name}" status-left-style "bg=colour214,fg=colour0,bold" 2>/dev/null || true

    # Start claude with full permission bypass and pre-trusted directories
    # --dangerously-skip-permissions: bypass tool permission system
    # --permission-mode bypassPermissions: additional bypass
    # --add-dir: pre-trust directories workers commonly write to
    tmux send-keys -t "worker-${name}" "$CLAUDE_BIN --dangerously-skip-permissions --permission-mode bypassPermissions --add-dir $HOME/.claude/dispatcher --add-dir $HOME/Sale\ Advisor --add-dir $HOME/Sale\ Advisor/Website/sale-advisor-website --add-dir $HOME/Sale\ Advisor/Projects/ListFlow" Enter

    # Wait for claude to initialize
    sleep 3

    log "INFO" "Created worker: $name (dir: $project_dir)"
    telegram_send "Worker *${name}* created"
}

close_worker() {
    local name="$1"

    if tmux has-session -t "worker-${name}" 2>/dev/null; then
        # Send /exit to claude first for clean shutdown
        tmux send-keys -t "worker-${name}" "/exit" Enter
        sleep 2
        # Kill the tmux session
        tmux kill-session -t "worker-${name}" 2>/dev/null || true

        # Close the Terminal.app window that was hosting this worker
        # After killing tmux, the shell exits, so close any window showing a dead shell
        osascript -e "
            tell application \"Terminal\"
                try
                    close (every window whose name contains \"${name}\")
                end try
            end tell
        " 2>/dev/null || true
        # Fallback: close windows with finished processes
        osascript -e "
            tell application \"Terminal\"
                repeat with w in windows
                    try
                        if busy of w is false then close w
                    end try
                end repeat
            end tell
        " 2>/dev/null || true

        log "INFO" "Closed worker: $name"
        telegram_send "Worker *${name}* closed"
    else
        log "WARN" "Worker $name does not exist"
    fi
}

close_all_workers() {
    for session in $(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^worker-'); do
        local name="${session#worker-}"
        close_worker "$name"
    done
    log "INFO" "All workers closed"
}

send_task() {
    local name="$1"
    local prompt="$2"
    local project_dir="${3:-$HOME/Sale Advisor}"

    if ! tmux has-session -t "worker-${name}" 2>/dev/null; then
        log "ERROR" "Worker $name does not exist"
        return 1
    fi

    # Wrap with standard template if available
    local wrapped_prompt
    if type build_prompt &>/dev/null; then
        wrapped_prompt=$(build_prompt "$project_dir" "$prompt")
    else
        wrapped_prompt="$prompt"
    fi

    # Save prompt to file for debugging/replay
    local timestamp
    timestamp=$(date '+%Y%m%d-%H%M%S')
    local prompt_file="${PROMPTS_DIR}/${name}-${timestamp}.md"
    echo "$wrapped_prompt" > "$prompt_file"

    # Send to worker via tmux
    # Use a temp file to avoid shell escaping issues with send-keys
    local tmp_file
    tmp_file=$(mktemp)
    echo "$wrapped_prompt" > "$tmp_file"

    # Paste the prompt content, then wait for it to render before hitting Enter
    tmux load-buffer "$tmp_file"
    tmux paste-buffer -t "worker-${name}"
    sleep 2
    tmux send-keys -t "worker-${name}" Enter

    rm -f "$tmp_file"

    log "INFO" "Sent task to worker $name (saved: $prompt_file)"
    telegram_send "Task sent to *${name}*"
}

send_loop_task() {
    local name="$1"
    local prompt="$2"
    local project_dir="${3:-$HOME/Sale Advisor}"

    if ! tmux has-session -t "worker-${name}" 2>/dev/null; then
        log "ERROR" "Worker $name does not exist"
        return 1
    fi

    # Wrap with loop template if available, else fall back to raw + suffix
    local wrapped_prompt
    if type build_loop_prompt &>/dev/null; then
        wrapped_prompt=$(build_loop_prompt "$project_dir" "$prompt")
    else
        local loop_suffix='

AFTER completing this task, check ~/.claude/dispatcher/task-board.md for unclaimed tasks in the Queue section. If there is an unclaimed task, claim it by outputting CLAIMING: [task description], then start working on it immediately. If no tasks are available, output IDLE and wait for the next task.'
        wrapped_prompt="${prompt}${loop_suffix}"
    fi

    # Save prompt to file for debugging/replay
    local timestamp
    timestamp=$(date '+%Y%m%d-%H%M%S')
    local prompt_file="${PROMPTS_DIR}/${name}-${timestamp}.md"
    echo "$wrapped_prompt" > "$prompt_file"

    # Send to worker via tmux
    local tmp_file
    tmp_file=$(mktemp)
    echo "$wrapped_prompt" > "$tmp_file"

    tmux load-buffer "$tmp_file"
    tmux paste-buffer -t "worker-${name}"
    sleep 2
    tmux send-keys -t "worker-${name}" Enter

    rm -f "$tmp_file"

    log "INFO" "Sent loop task to worker $name (saved: $prompt_file)"
    telegram_send "Loop task sent to *${name}*"
}

read_output() {
    local name="$1"
    local lines="${2:-100}"

    if ! tmux has-session -t "worker-${name}" 2>/dev/null; then
        log "ERROR" "Worker $name does not exist"
        return 1
    fi

    tmux capture-pane -t "worker-${name}" -p -S "-${lines}"
}

list_workers() {
    tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^worker-' | sed 's/^worker-//' || true
}

worker_status() {
    local name="$1"

    if ! tmux has-session -t "worker-${name}" 2>/dev/null; then
        echo "NOT_FOUND"
        return
    fi

    local output
    output=$(read_output "$name" 20)

    # Check for structured markers (flexible: markers may have leading whitespace or unicode)
    if echo "$output" | grep -q "DONE:" 2>/dev/null; then
        echo "DONE"
    elif echo "$output" | grep -q "BLOCKED:" 2>/dev/null; then
        echo "BLOCKED"
    elif echo "$output" | grep -q "ERROR:" 2>/dev/null; then
        echo "ERROR"
    elif echo "$output" | grep -q "PROGRESS:" 2>/dev/null; then
        echo "WORKING"
    else
        # Check if there's been recent output
        local last_line
        last_line=$(echo "$output" | tail -1 || true)
        if [[ -z "$last_line" || "$last_line" == *"$"* ]]; then
            echo "IDLE"
        else
            echo "WORKING"
        fi
    fi
}

# ============================================================
# HEALTH MONITORING
# ============================================================

check_permissions() {
    local name="$1"

    if ! tmux has-session -t "worker-${name}" 2>/dev/null; then
        return 0
    fi

    local output
    output=$(read_output "$name" 20)

    if echo "$output" | grep -qiE '(Do you want to|Esc to cancel|Yes, and allow|Allow once|permission)' 2>/dev/null; then
        # Auto-accept: option 1 (Yes) is pre-selected, just press Enter
        tmux send-keys -t "worker-${name}" Enter
        log "INFO" "Auto-accepted permission prompt on worker $name"
        telegram_send "Auto-accepted permission on *${name}*"
        sleep 2
        return 1
    fi

    return 0
}

check_health() {
    local workers
    workers=$(list_workers)

    if [[ -z "$workers" ]]; then
        echo "No active workers"
        return
    fi

    for name in $workers; do
        local status
        status=$(worker_status "$name")
        local output_sample
        output_sample=$(read_output "$name" 5 | tail -3)

        echo "Worker: $name | Status: $status"

        # Check for stuck permission prompts and auto-accept them
        if ! check_permissions "$name" 2>/dev/null; then
            echo "  AUTO-ACCEPTED: Permission prompt was detected and accepted."
        fi

        if [[ "$status" == "BLOCKED" ]]; then
            local block_reason
            block_reason=$(read_output "$name" 50 | grep "^BLOCKED:" | tail -1)
            echo "  BLOCKED: $block_reason"
            telegram_send "Worker *${name}* is BLOCKED: ${block_reason}"
        elif [[ "$status" == "ERROR" ]]; then
            local error_detail
            error_detail=$(read_output "$name" 50 | grep "^ERROR:" | tail -1)
            echo "  ERROR: $error_detail"
            telegram_send "Worker *${name}* has ERROR: ${error_detail}"
        fi
    done
}

check_conflicts() {
    local files="$1"
    local exclude_worker="${2:-}"

    # Check each active worker's recent output for file edits
    for name in $(list_workers); do
        [[ "$name" == "$exclude_worker" ]] && continue

        local output
        output=$(read_output "$name" 50)

        for file in $files; do
            if echo "$output" | grep -q "$file"; then
                echo "CONFLICT: Worker $name is also working on $file"
                return 1
            fi
        done
    done

    return 0
}

# ============================================================
# DISPATCH
# ============================================================

dispatch_status() {
    echo "=== Hive Status ==="
    echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""

    local workers
    workers=$(list_workers)

    if [[ -z "$workers" ]]; then
        echo "No active workers."
        return
    fi

    local total=0
    local working=0
    local done=0
    local blocked=0
    local errored=0

    for name in $workers; do
        local status
        status=$(worker_status "$name")
        total=$((total + 1))

        case "$status" in
            WORKING) working=$((working + 1)) ;;
            DONE) done=$((done + 1)) ;;
            BLOCKED) blocked=$((blocked + 1)) ;;
            ERROR) errored=$((errored + 1)) ;;
        esac

        # Get last meaningful output line
        local last_line
        last_line=$(read_output "$name" 30 | grep -E "(PROGRESS|DONE|BLOCKED|ERROR):" | tail -1 | sed 's/^[^A-Z]*//')
        [[ -z "$last_line" ]] && last_line="(no structured output yet)"

        echo "[$status] worker-${name}: $last_line"
    done

    echo ""
    echo "Total: $total | Working: $working | Done: $done | Blocked: $blocked | Errors: $errored"
}

dispatch_stop() {
    log "INFO" "Stopping all workers..."
    telegram_send "Hive shutting down all workers"
    close_all_workers
    log "INFO" "All workers stopped"
}

# ============================================================
# NIGHT MODE
# ============================================================

night_mode() {
    local end_time="${1:-08:45}"
    local start_time
    start_time=$(date '+%H:%M')

    log "INFO" "Night mode started. Will run until $end_time"
    telegram_send "Hive night mode started. Running until ${end_time}."

    # Initialize report
    local completed=0
    local failed=0
    local skipped=0
    local tasks_attempted=0
    local peak_workers=0
    local report_entries=""
    local failed_entries=""

    while true; do
        local current_time
        current_time=$(date '+%H:%M')

        # Check if we should stop (handle midnight rollover)
        local current_minutes
        current_minutes=$(date -j -f '%H:%M' "$current_time" '+%s' 2>/dev/null || date -d "$current_time" '+%s')
        local end_minutes
        end_minutes=$(date -j -f '%H:%M' "$end_time" '+%s' 2>/dev/null || date -d "$end_time" '+%s')

        # If end_time is in the morning and current is past it
        if [[ "$current_time" > "$end_time" && "$end_time" < "12:00" && "$current_time" > "06:00" ]]; then
            log "INFO" "Time window closed ($current_time > $end_time). Stopping."
            break
        fi

        # Check for tasks in queue
        if [[ -f "$QUEUE_FILE" ]]; then
            local next_task
            next_task=$(grep '^\- \[ \]' "$QUEUE_FILE" | head -1 | sed 's/^- \[ \] //')

            if [[ -n "$next_task" ]]; then
                tasks_attempted=$((tasks_attempted + 1))
                log "INFO" "Night mode: executing task: $next_task"
                telegram_send "Night mode: starting *${next_task}*"

                # Create a worker for this task
                local worker_name
                worker_name="night-$(echo "$next_task" | tr ' ' '-' | tr '[:upper:]' '[:lower:]' | head -c 20)"

                create_worker "$worker_name" "$(pwd)"
                sleep 5  # Wait for claude to fully initialize

                # Track peak workers
                local current_workers
                current_workers=$(list_workers | wc -l | tr -d ' ')
                [[ "$current_workers" -gt "$peak_workers" ]] && peak_workers=$current_workers

                # Send the task
                send_task "$worker_name" "$next_task"

                # Mark as in progress in queue
                sed -i '' "s/^- \[ \] $(echo "$next_task" | sed 's/[\/&]/\\&/g')/- [~] $next_task [IN PROGRESS]/" "$QUEUE_FILE" 2>/dev/null || true

                # Wait for completion (check every 30 seconds)
                local attempts=0
                local max_attempts=120  # 60 minutes max per task
                local task_done=false

                while [[ "$attempts" -lt "$max_attempts" ]]; do
                    sleep 30
                    attempts=$((attempts + 1))

                    local status
                    status=$(worker_status "$worker_name")

                    if [[ "$status" == "DONE" ]]; then
                        local done_summary
                        done_summary=$(read_output "$worker_name" 50 | grep "^DONE:" | tail -1)
                        completed=$((completed + 1))
                        report_entries="${report_entries}\n- ${done_summary#DONE: }"
                        sed -i '' "s/^- \[~\] $(echo "$next_task" | sed 's/[\/&]/\\&/g').*/- [x] $next_task [DONE $(date '+%H:%M')]/" "$QUEUE_FILE" 2>/dev/null || true
                        telegram_send "Night mode: *${next_task}* completed"
                        task_done=true
                        break
                    elif [[ "$status" == "ERROR" || "$status" == "BLOCKED" ]]; then
                        local error_detail
                        error_detail=$(read_output "$worker_name" 50 | grep -E "^(ERROR|BLOCKED):" | tail -1)
                        failed=$((failed + 1))
                        failed_entries="${failed_entries}\n- ${next_task}: ${error_detail}"
                        sed -i '' "s/^- \[~\] $(echo "$next_task" | sed 's/[\/&]/\\&/g').*/- [-] $next_task [FAILED]/" "$QUEUE_FILE" 2>/dev/null || true
                        telegram_send "Night mode: *${next_task}* FAILED: ${error_detail}"
                        task_done=true
                        break
                    fi
                done

                if [[ "$task_done" == "false" ]]; then
                    # Timed out
                    failed=$((failed + 1))
                    failed_entries="${failed_entries}\n- ${next_task}: Timed out after 60 minutes"
                    sed -i '' "s/^- \[~\] $(echo "$next_task" | sed 's/[\/&]/\\&/g').*/- [-] $next_task [TIMEOUT]/" "$QUEUE_FILE" 2>/dev/null || true
                    telegram_send "Night mode: *${next_task}* timed out"
                fi

                # Close the worker
                close_worker "$worker_name"
            else
                # No more tasks
                log "INFO" "No more tasks in queue. Night mode idle."
                sleep 300  # Check again in 5 minutes
            fi
        else
            log "WARN" "No task queue file found at $QUEUE_FILE"
            break
        fi
    done

    # Generate morning report
    local end_timestamp
    end_timestamp=$(date '+%Y-%m-%d %H:%M')

    cat > "$REPORT_FILE" << REPORT
# Overnight Report — $(date '+%B %d, %Y')

## Summary
Started: ${start_time} | Ended: ${end_timestamp}
Peak Workers: ${peak_workers}

## Completed (${completed})
$(echo -e "$report_entries")

## Failed (${failed})
$(echo -e "$failed_entries")

## Stats
Tasks Attempted: ${tasks_attempted}
Completed: ${completed}
Failed: ${failed}
Skipped: ${skipped}
REPORT

    log "INFO" "Night mode ended. Report: $REPORT_FILE"
    telegram_send "Night mode complete. ${completed} done, ${failed} failed. Report ready."
}

# ============================================================
# CLI INTERFACE
# ============================================================

case "${1:-help}" in
    create)
        create_worker "${2:?Worker name required}" "${3:-$(pwd)}"
        ;;
    close)
        close_worker "${2:?Worker name required}"
        ;;
    close-all)
        close_all_workers
        ;;
    send)
        send_task "${2:?Worker name required}" "${3:?Prompt required}" "${4:-$HOME/Sale Advisor}"
        ;;
    send-loop)
        send_loop_task "${2:?Worker name required}" "${3:?Prompt required}" "${4:-$HOME/Sale Advisor}"
        ;;
    read)
        read_output "${2:?Worker name required}" "${3:-100}"
        ;;
    list)
        list_workers
        ;;
    status)
        if [[ -n "${2:-}" ]]; then
            worker_status "$2"
        else
            dispatch_status
        fi
        ;;
    health)
        check_health
        ;;
    check-permissions)
        check_permissions "${2:?Worker name required}"
        ;;
    stop)
        dispatch_stop
        ;;
    selftest)
        log "INFO" "Running self-test..."
        bash "$DISPATCHER_DIR/self-test.sh"
        ;;
    night)
        # Run self-test before starting overnight workers
        log "INFO" "Pre-flight self-test..."
        if ! bash "$DISPATCHER_DIR/self-test.sh"; then
            log "ERROR" "Self-test failed. Aborting night mode."
            telegram_send "Night mode ABORTED: self-test failed. Workers cannot run without prompts."
            exit 1
        fi
        night_mode "${2:-08:45}"
        ;;
    help)
        cat << 'HELP'
Hive Dispatcher v2

Usage: dispatcher.sh <command> [args]

Worker Management:
  create <name> [dir]     Create a new worker terminal
  close <name>            Close a worker terminal
  close-all               Close all worker terminals
  send <name> <prompt> [dir]  Send a task to a worker (dir defaults to ~/Sale Advisor)
  send-loop <name> <prompt> [dir]  Send task + auto-pick-up next from task-board
  read <name> [lines]     Read worker output (default: 100 lines)

Monitoring:
  list                    List all active workers
  status [name]           Show status (all workers or specific one)
  health                  Health check all workers
  check-permissions <name> Check if worker has a permission prompt

Control:
  selftest                Run permission self-test (30s max)
  stop                    Gracefully stop all workers
  night [end_time]        Start night mode (default end: 08:45)
  help                    Show this help
HELP
        ;;
    *)
        echo "Unknown command: $1. Run 'dispatcher.sh help' for usage."
        exit 1
        ;;
esac
