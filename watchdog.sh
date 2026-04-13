#!/usr/bin/env bash
# Hive Watchdog — idle worker reassignment + blocked worker alerts
# Run: bash watchdog.sh &
# Stop: kill $(cat ~/.claude/dispatcher/watchdog.pid)

set -uo pipefail

DISPATCHER_DIR="$HOME/.claude/dispatcher"
DISPATCHER="$DISPATCHER_DIR/dispatcher.sh"
LOG_FILE="$DISPATCHER_DIR/dispatcher.log"
PID_FILE="$DISPATCHER_DIR/watchdog.pid"
TASK_BOARD="$DISPATCHER_DIR/task-board.md"
POLL_INTERVAL=60        # seconds between checks
IDLE_THRESHOLD=120      # 2 minutes before reassigning idle/done workers
BLOCKED_THRESHOLD=300   # 5 minutes before alerting on blocked workers
HEARTBEAT_INTERVAL=300  # 5 minutes between heartbeat logs

# Track how long each worker has been in a given state
declare -A WORKER_STATE_SINCE  # worker -> epoch when state was first seen
declare -A WORKER_LAST_STATE   # worker -> last known state
declare -A BLOCKED_ALERTED     # worker -> 1 if we already sent an alert this cycle

LAST_HEARTBEAT=0

# ============================================================
# LOGGING (mirrors dispatcher format)
# ============================================================

log() {
    local level="$1"
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WATCHDOG] [$level] $*" | tee -a "$LOG_FILE"
}

# ============================================================
# TELEGRAM (load config from dispatcher's env)
# ============================================================

TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""

if [[ -f "$HOME/.claude/channels/telegram/.env" ]]; then
    source "$HOME/.claude/channels/telegram/.env" 2>/dev/null || true
fi

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
# TASK BOARD PARSING
# ============================================================

get_next_task() {
    # Returns the first unclaimed task from the Queue section, or empty string
    if [[ ! -f "$TASK_BOARD" ]]; then
        echo ""
        return
    fi
    # Match lines like: - [P1] Fix sell page mobile layout [assigned: none]
    local task_line
    task_line=$(grep -m1 '\[assigned: none\]' "$TASK_BOARD" 2>/dev/null || true)
    if [[ -z "$task_line" ]]; then
        echo ""
        return
    fi
    # Extract just the task description (between ] and [assigned)
    local task_desc
    task_desc=$(echo "$task_line" | sed 's/^- \[P[0-9]\] //' | sed 's/ \[assigned:.*$//')
    echo "$task_desc"
}

get_task_priority() {
    # Returns the priority tag of the first unclaimed task
    if [[ ! -f "$TASK_BOARD" ]]; then
        echo ""
        return
    fi
    local task_line
    task_line=$(grep -m1 '\[assigned: none\]' "$TASK_BOARD" 2>/dev/null || true)
    echo "$task_line" | grep -o '\[P[0-9]\]' || true
}

claim_task_on_board() {
    local task_desc="$1"
    local worker_name="$2"
    # Replace [assigned: none] with [assigned: worker-X] for this task
    local escaped_desc
    escaped_desc=$(echo "$task_desc" | sed 's/[\/&]/\\&/g')
    sed -i '' "s/\(.*${escaped_desc}.*\)\[assigned: none\]/\1[assigned: worker-${worker_name}]/" "$TASK_BOARD" 2>/dev/null || true
}

# ============================================================
# WATCHDOG CORE
# ============================================================

check_workers() {
    local now
    now=$(date +%s)

    # Get list of active workers from dispatcher
    local workers
    workers=$(bash "$DISPATCHER" list 2>/dev/null)

    if [[ -z "$workers" ]]; then
        return
    fi

    local active_count=0
    local idle_count=0

    for name in $workers; do
        local status
        status=$(bash "$DISPATCHER" status "$name" 2>/dev/null)
        active_count=$((active_count + 1))

        # Track state transitions
        local prev_state="${WORKER_LAST_STATE[$name]:-UNKNOWN}"
        if [[ "$status" != "$prev_state" ]]; then
            # State changed, reset the timer
            WORKER_STATE_SINCE[$name]=$now
            WORKER_LAST_STATE[$name]="$status"
            # Clear blocked alert flag on state change
            unset "BLOCKED_ALERTED[$name]" 2>/dev/null || true
        fi

        local state_start="${WORKER_STATE_SINCE[$name]:-$now}"
        local duration=$(( now - state_start ))

        case "$status" in
            DONE|IDLE)
                idle_count=$((idle_count + 1))
                if [[ "$duration" -ge "$IDLE_THRESHOLD" ]]; then
                    handle_idle_worker "$name" "$status" "$duration"
                fi
                ;;
            BLOCKED)
                if [[ "$duration" -ge "$BLOCKED_THRESHOLD" && -z "${BLOCKED_ALERTED[$name]:-}" ]]; then
                    handle_blocked_worker "$name" "$duration"
                fi
                ;;
            WORKING)
                # Worker is busy, nothing to do
                ;;
        esac
    done

    # Heartbeat
    if [[ $(( now - LAST_HEARTBEAT )) -ge "$HEARTBEAT_INTERVAL" ]]; then
        local working_count=$(( active_count - idle_count ))
        log "INFO" "Watchdog alive, $working_count workers active, $idle_count idle"
        LAST_HEARTBEAT=$now
    fi
}

handle_idle_worker() {
    local name="$1"
    local status="$2"
    local duration="$3"

    local next_task
    next_task=$(get_next_task)

    if [[ -n "$next_task" ]]; then
        local priority
        priority=$(get_task_priority)
        log "INFO" "Worker $name $status for ${duration}s. Assigning: $priority $next_task"

        # Claim on the board first
        claim_task_on_board "$next_task" "$name"

        # Send the task via dispatcher (use send-loop so worker auto-picks up next task when done)
        bash "$DISPATCHER" send-loop "$name" "$next_task" 2>/dev/null
        telegram_send "Watchdog auto-assigned *${next_task}* to worker *${name}*"

        # Reset state tracking (worker should now be WORKING)
        WORKER_STATE_SINCE[$name]=$(date +%s)
        WORKER_LAST_STATE[$name]="WORKING"
    else
        log "INFO" "Worker $name idle, no tasks in queue"
    fi
}

handle_blocked_worker() {
    local name="$1"
    local duration="$2"
    local minutes=$(( duration / 60 ))

    # Get the block reason from worker output
    local block_reason
    block_reason=$(bash "$DISPATCHER" read "$name" 50 2>/dev/null | grep "BLOCKED:" | tail -1 || echo "unknown reason")

    log "WARN" "Worker $name BLOCKED for ${minutes}m. $block_reason"
    telegram_send "ALERT: Worker *${name}* BLOCKED for ${minutes}m. ${block_reason}"

    BLOCKED_ALERTED[$name]=1
}

# ============================================================
# LIFECYCLE
# ============================================================

cleanup() {
    log "INFO" "Watchdog shutting down (PID $$)"
    rm -f "$PID_FILE"
    exit 0
}

trap cleanup SIGTERM SIGINT SIGHUP

# Write PID file
echo $$ > "$PID_FILE"
log "INFO" "Watchdog started (PID $$, poll every ${POLL_INTERVAL}s)"
telegram_send "Watchdog started (PID $$)"
LAST_HEARTBEAT=$(date +%s)

# Main loop
while true; do
    check_workers
    sleep "$POLL_INTERVAL"
done
