#!/usr/bin/env bash
# Hive Dispatcher Test Suite
# Covers: create, send, send-loop, read, status, close, board operations
# Run: bash tests/test-dispatcher.sh
#
# These tests use a MOCK claude binary (just a shell that echos) so they
# run without an Anthropic account or network access.

set -uo pipefail

DISPATCHER="$HOME/.claude/dispatcher/dispatcher.sh"
BOARD_MANAGER="$HOME/.claude/dispatcher/board-manager.sh"
TEST_PREFIX="hivetest"
PASS=0
FAIL=0
ERRORS=""

# ============================================================
# HELPERS
# ============================================================

pass() {
    PASS=$((PASS + 1))
    echo "  PASS: $1"
}

fail() {
    FAIL=$((FAIL + 1))
    ERRORS="${ERRORS}\n  FAIL: $1"
    echo "  FAIL: $1"
}

cleanup_workers() {
    for session in $(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep "^worker-${TEST_PREFIX}"); do
        tmux kill-session -t "$session" 2>/dev/null || true
    done
}

cleanup_board() {
    rm -f "$HOME/.claude/dispatcher/task-board.md.bak" 2>/dev/null
    if [[ -f "$HOME/.claude/dispatcher/task-board.md.orig" ]]; then
        mv "$HOME/.claude/dispatcher/task-board.md.orig" "$HOME/.claude/dispatcher/task-board.md"
    fi
}

# Create a mock claude binary that just starts a shell prompt
# This avoids needing a real API key or network
MOCK_CLAUDE=""
setup_mock_claude() {
    MOCK_CLAUDE=$(mktemp)
    cat > "$MOCK_CLAUDE" << 'MOCKEOF'
#!/usr/bin/env bash
# Mock Claude: simulates a Claude Code session
# Accepts all flags silently, then sits at a prompt reading stdin
echo "Mock Claude initialized (flags: $*)"
echo ""
# Sit in a read loop so tmux session stays alive
while IFS= read -r line; do
    if [[ "$line" == "/exit" ]]; then
        echo "Goodbye."
        exit 0
    fi
    # Echo back what we receive, prefixed with a marker
    echo "RECEIVED> $line"
    # Simulate structured output based on keywords
    if echo "$line" | grep -qi "done"; then
        echo "DONE: mock task completed"
    elif echo "$line" | grep -qi "block"; then
        echo "BLOCKED: mock blocker"
    elif echo "$line" | grep -qi "error"; then
        echo "ERROR: mock error"
    elif echo "$line" | grep -qi "progress"; then
        echo "PROGRESS: working on it"
    fi
done
MOCKEOF
    chmod +x "$MOCK_CLAUDE"
}

teardown_mock_claude() {
    rm -f "$MOCK_CLAUDE" 2>/dev/null
}

# Patch the dispatcher to use our mock claude for test workers
# We do this by temporarily overriding CLAUDE_BIN via env
export_mock_env() {
    export CLAUDE_BIN="$MOCK_CLAUDE"
}

restore_env() {
    export CLAUDE_BIN="$HOME/.local/bin/claude"
}

# ============================================================
# TEST SUITE
# ============================================================

echo "========================================"
echo " Hive Dispatcher Test Suite"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================"
echo ""

# Pre-flight: clean up any leftover test sessions
cleanup_workers

# Set up mock
setup_mock_claude
export_mock_env

# ----------------------------------------------------------
# TEST GROUP 1: Worker Lifecycle
# ----------------------------------------------------------
echo "[Group 1] Worker Lifecycle"

# Test 1.1: create_worker creates a tmux session
test_create() {
    local name="${TEST_PREFIX}-create"
    bash "$DISPATCHER" create "$name" "$(pwd)" > /dev/null 2>&1

    if tmux has-session -t "worker-${name}" 2>/dev/null; then
        pass "create: tmux session 'worker-${name}' exists"
    else
        fail "create: tmux session 'worker-${name}' was not created"
        return
    fi

    # Verify Claude (mock) started by checking for initialization output
    sleep 2
    local output
    output=$(tmux capture-pane -t "worker-${name}" -p -S -20 2>/dev/null)

    if echo "$output" | grep -q "Mock Claude initialized"; then
        pass "create: Claude binary was launched inside session"
    else
        fail "create: Claude binary did not start (no init output found)"
    fi

    # Verify tmux status bar was configured
    local status_left
    status_left=$(tmux show-options -t "worker-${name}" status-left 2>/dev/null | head -1)
    if [[ -n "$status_left" ]]; then
        pass "create: tmux status bar was configured"
    else
        fail "create: tmux status bar was not configured"
    fi

    # Cleanup
    tmux kill-session -t "worker-${name}" 2>/dev/null
}
test_create

# Test 1.2: create rejects duplicate names
test_create_duplicate() {
    local name="${TEST_PREFIX}-dup"
    bash "$DISPATCHER" create "$name" "$(pwd)" > /dev/null 2>&1
    sleep 2

    local output
    output=$(bash "$DISPATCHER" create "$name" "$(pwd)" 2>&1)

    if echo "$output" | grep -qi "already exists"; then
        pass "create duplicate: rejected with 'already exists'"
    else
        fail "create duplicate: did not reject duplicate name"
    fi

    tmux kill-session -t "worker-${name}" 2>/dev/null
}
test_create_duplicate

# Test 1.3: create respects MAX_WORKERS limit
test_max_workers() {
    # We won't actually create 10 workers. Instead, verify the check exists
    # by reading the function. This is a static check.
    if grep -q 'MAX_WORKERS' "$DISPATCHER" && grep -q 'Max workers' "$DISPATCHER"; then
        pass "max workers: limit check exists in create_worker"
    else
        fail "max workers: no MAX_WORKERS limit check found"
    fi
}
test_max_workers

# Test 1.4: create passes --add-dir flags to Claude
test_create_add_dir() {
    if grep -q '\-\-add-dir' "$DISPATCHER"; then
        pass "create add-dir: --add-dir flags present in create_worker"
    else
        fail "create add-dir: --add-dir flags missing from create_worker"
    fi
}
test_create_add_dir

# Test 1.5: create does NOT use --bare flag (broke OAuth)
test_no_bare_flag() {
    if grep -q '\-\-bare' "$DISPATCHER"; then
        fail "no --bare: dispatcher still contains --bare flag"
    else
        pass "no --bare: --bare flag correctly removed"
    fi
}
test_no_bare_flag

echo ""

# ----------------------------------------------------------
# TEST GROUP 2: Task Sending
# ----------------------------------------------------------
echo "[Group 2] Task Sending"

# Test 2.1: send_task delivers prompt to worker
test_send() {
    local name="${TEST_PREFIX}-send"
    bash "$DISPATCHER" create "$name" "$(pwd)" > /dev/null 2>&1
    sleep 3

    bash "$DISPATCHER" send "$name" "Hello from test suite" > /dev/null 2>&1
    sleep 3

    local output
    output=$(tmux capture-pane -t "worker-${name}" -p -S -30 2>/dev/null)

    if echo "$output" | grep -q "Hello from test suite"; then
        pass "send: prompt text arrived in worker pane"
    else
        fail "send: prompt text not found in worker pane output"
    fi

    tmux kill-session -t "worker-${name}" 2>/dev/null
}
test_send

# Test 2.2: send saves prompt to file for replay
test_send_saves_file() {
    local name="${TEST_PREFIX}-savefile"
    bash "$DISPATCHER" create "$name" "$(pwd)" > /dev/null 2>&1
    sleep 3

    bash "$DISPATCHER" send "$name" "Prompt for save test" > /dev/null 2>&1
    sleep 1

    local found
    found=$(ls -t "$HOME/.claude/dispatcher/worker-prompts/${name}-"*.md 2>/dev/null | head -1)

    if [[ -n "$found" ]] && grep -q "Prompt for save test" "$found"; then
        pass "send save: prompt file created and contains text"
        rm -f "$found"
    else
        fail "send save: prompt file not found or missing text"
    fi

    tmux kill-session -t "worker-${name}" 2>/dev/null
}
test_send_saves_file

# Test 2.3: send uses paste-buffer + sleep + Enter (paste timing fix)
test_send_paste_timing() {
    # Verify the dispatcher uses load-buffer/paste-buffer pattern with a sleep before Enter
    if grep -q 'load-buffer' "$DISPATCHER" && grep -q 'paste-buffer' "$DISPATCHER"; then
        pass "paste timing: uses load-buffer + paste-buffer (not send-keys for content)"
    else
        fail "paste timing: does not use paste-buffer pattern"
    fi

    # Verify there's a sleep between paste and Enter
    local paste_to_enter
    paste_to_enter=$(awk '/paste-buffer/,/send-keys.*Enter/' "$DISPATCHER")
    if echo "$paste_to_enter" | grep -q 'sleep'; then
        pass "paste timing: sleep exists between paste-buffer and Enter"
    else
        fail "paste timing: no sleep between paste-buffer and Enter"
    fi
}
test_send_paste_timing

# Test 2.4: send to nonexistent worker fails gracefully
test_send_nonexistent() {
    local output
    output=$(bash "$DISPATCHER" send "nonexistent-worker-xyz" "test" 2>&1)
    local rc=$?

    if [[ $rc -ne 0 ]] || echo "$output" | grep -qi "does not exist"; then
        pass "send nonexistent: fails gracefully with error message"
    else
        fail "send nonexistent: did not report error for missing worker"
    fi
}
test_send_nonexistent

# Test 2.5: send_loop_task appends self-directing suffix
test_send_loop() {
    local name="${TEST_PREFIX}-loop"
    bash "$DISPATCHER" create "$name" "$(pwd)" > /dev/null 2>&1
    sleep 3

    bash "$DISPATCHER" send-loop "$name" "Do the first task" > /dev/null 2>&1
    sleep 3

    local output
    output=$(tmux capture-pane -t "worker-${name}" -p -S -50 2>/dev/null)

    if echo "$output" | grep -q "task-board.md"; then
        pass "send-loop: task-board.md reference found in delivered prompt"
    else
        fail "send-loop: self-directing suffix not found in delivered prompt"
    fi

    if echo "$output" | grep -q "CLAIMING:"; then
        pass "send-loop: CLAIMING instruction present"
    elif echo "$output" | grep -q "CLAIMING"; then
        pass "send-loop: CLAIMING instruction present"
    else
        fail "send-loop: CLAIMING instruction not found in suffix"
    fi

    if echo "$output" | grep -q "IDLE"; then
        pass "send-loop: IDLE fallback instruction present"
    else
        fail "send-loop: IDLE fallback instruction not found in suffix"
    fi

    tmux kill-session -t "worker-${name}" 2>/dev/null
}
test_send_loop

echo ""

# ----------------------------------------------------------
# TEST GROUP 3: Read Output
# ----------------------------------------------------------
echo "[Group 3] Read Output"

# Test 3.1: read captures pane content
test_read() {
    local name="${TEST_PREFIX}-read"
    bash "$DISPATCHER" create "$name" "$(pwd)" > /dev/null 2>&1
    sleep 3

    # Send something we can look for
    bash "$DISPATCHER" send "$name" "MARKER_READ_TEST_12345" > /dev/null 2>&1
    sleep 3

    local output
    output=$(bash "$DISPATCHER" read "$name" 50 2>/dev/null)

    if echo "$output" | grep -q "MARKER_READ_TEST_12345"; then
        pass "read: captured expected content from pane"
    else
        fail "read: did not find expected marker in read output"
    fi

    tmux kill-session -t "worker-${name}" 2>/dev/null
}
test_read

# Test 3.2: read nonexistent worker fails gracefully
test_read_nonexistent() {
    local output
    output=$(bash "$DISPATCHER" read "nonexistent-xyz" 2>&1)
    local rc=$?

    if [[ $rc -ne 0 ]] || echo "$output" | grep -qi "does not exist"; then
        pass "read nonexistent: fails gracefully"
    else
        fail "read nonexistent: no error for missing worker"
    fi
}
test_read_nonexistent

echo ""

# ----------------------------------------------------------
# TEST GROUP 4: Worker Status Detection
# ----------------------------------------------------------
echo "[Group 4] Status Detection"

# Test 4.1: status shows DONE when worker outputs DONE:
test_status_done() {
    local name="${TEST_PREFIX}-stdone"
    bash "$DISPATCHER" create "$name" "$(pwd)" > /dev/null 2>&1
    sleep 3

    # Send a prompt containing "done" so mock echoes DONE:
    bash "$DISPATCHER" send "$name" "Please mark as done" > /dev/null 2>&1
    sleep 3

    local status
    status=$(bash "$DISPATCHER" status "$name" 2>/dev/null)

    if [[ "$status" == "DONE" ]]; then
        pass "status DONE: correctly detected DONE state"
    else
        fail "status DONE: expected DONE, got '$status'"
    fi

    tmux kill-session -t "worker-${name}" 2>/dev/null
}
test_status_done

# Test 4.2: status shows BLOCKED
test_status_blocked() {
    local name="${TEST_PREFIX}-stblk"
    bash "$DISPATCHER" create "$name" "$(pwd)" > /dev/null 2>&1
    sleep 3

    bash "$DISPATCHER" send "$name" "I am blocked on permissions" > /dev/null 2>&1
    sleep 3

    local status
    status=$(bash "$DISPATCHER" status "$name" 2>/dev/null)

    if [[ "$status" == "BLOCKED" ]]; then
        pass "status BLOCKED: correctly detected BLOCKED state"
    else
        fail "status BLOCKED: expected BLOCKED, got '$status'"
    fi

    tmux kill-session -t "worker-${name}" 2>/dev/null
}
test_status_blocked

# Test 4.3: status shows ERROR
test_status_error() {
    local name="${TEST_PREFIX}-sterr"
    bash "$DISPATCHER" create "$name" "$(pwd)" > /dev/null 2>&1
    sleep 3

    bash "$DISPATCHER" send "$name" "This will error out" > /dev/null 2>&1
    sleep 3

    local status
    status=$(bash "$DISPATCHER" status "$name" 2>/dev/null)

    if [[ "$status" == "ERROR" ]]; then
        pass "status ERROR: correctly detected ERROR state"
    else
        fail "status ERROR: expected ERROR, got '$status'"
    fi

    tmux kill-session -t "worker-${name}" 2>/dev/null
}
test_status_error

# Test 4.4: status shows WORKING for in-progress output
test_status_working() {
    local name="${TEST_PREFIX}-stwrk"
    bash "$DISPATCHER" create "$name" "$(pwd)" > /dev/null 2>&1
    sleep 3

    bash "$DISPATCHER" send "$name" "Show progress please" > /dev/null 2>&1
    sleep 3

    local status
    status=$(bash "$DISPATCHER" status "$name" 2>/dev/null)

    if [[ "$status" == "WORKING" ]]; then
        pass "status WORKING: correctly detected WORKING state"
    else
        fail "status WORKING: expected WORKING, got '$status'"
    fi

    tmux kill-session -t "worker-${name}" 2>/dev/null
}
test_status_working

# Test 4.5: status NOT_FOUND for nonexistent worker
test_status_not_found() {
    local status
    status=$(bash "$DISPATCHER" status "nonexistent-xyz" 2>/dev/null)

    if [[ "$status" == "NOT_FOUND" ]]; then
        pass "status NOT_FOUND: correct for missing worker"
    else
        fail "status NOT_FOUND: expected NOT_FOUND, got '$status'"
    fi
}
test_status_not_found

# Test 4.6: dispatch_status (no args) shows summary table
test_dispatch_status_summary() {
    local name="${TEST_PREFIX}-summary"
    bash "$DISPATCHER" create "$name" "$(pwd)" > /dev/null 2>&1
    sleep 3

    local output
    output=$(bash "$DISPATCHER" status 2>/dev/null)

    if echo "$output" | grep -q "Hive Status"; then
        pass "dispatch status: shows 'Hive Status' header"
    else
        fail "dispatch status: missing 'Hive Status' header"
    fi

    if echo "$output" | grep -q "Total:"; then
        pass "dispatch status: shows Total count line"
    else
        fail "dispatch status: missing Total count line"
    fi

    tmux kill-session -t "worker-${name}" 2>/dev/null
}
test_dispatch_status_summary

echo ""

# ----------------------------------------------------------
# TEST GROUP 5: Close / Cleanup
# ----------------------------------------------------------
echo "[Group 5] Close and Cleanup"

# Test 5.1: close kills the tmux session
test_close() {
    local name="${TEST_PREFIX}-close"
    bash "$DISPATCHER" create "$name" "$(pwd)" > /dev/null 2>&1
    sleep 2

    # Verify it exists first
    if ! tmux has-session -t "worker-${name}" 2>/dev/null; then
        fail "close: worker was not created to begin with"
        return
    fi

    bash "$DISPATCHER" close "$name" > /dev/null 2>&1
    sleep 2

    if tmux has-session -t "worker-${name}" 2>/dev/null; then
        fail "close: tmux session still exists after close"
        tmux kill-session -t "worker-${name}" 2>/dev/null
    else
        pass "close: tmux session removed after close"
    fi
}
test_close

# Test 5.2: close-all kills all workers
test_close_all() {
    local name1="${TEST_PREFIX}-all1"
    local name2="${TEST_PREFIX}-all2"
    bash "$DISPATCHER" create "$name1" "$(pwd)" > /dev/null 2>&1
    bash "$DISPATCHER" create "$name2" "$(pwd)" > /dev/null 2>&1
    sleep 2

    bash "$DISPATCHER" close-all > /dev/null 2>&1
    sleep 2

    local remaining
    remaining=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep "^worker-${TEST_PREFIX}" | wc -l | tr -d ' ')

    if [[ "$remaining" -eq 0 ]]; then
        pass "close-all: all test workers removed"
    else
        fail "close-all: $remaining test sessions still running"
        cleanup_workers
    fi
}
test_close_all

# Test 5.3: close sends /exit to Claude before killing
test_close_sends_exit() {
    if grep -A2 'close_worker' "$DISPATCHER" | head -20 | grep -q '/exit'; then
        pass "close exit: sends /exit to claude before kill"
    else
        # Check the full function
        if awk '/^close_worker/,/^}/' "$DISPATCHER" | grep -q '/exit'; then
            pass "close exit: sends /exit to claude before kill"
        else
            fail "close exit: does not send /exit before killing session"
        fi
    fi
}
test_close_sends_exit

# Test 5.4: close on nonexistent worker warns but does not crash
test_close_nonexistent() {
    local output
    output=$(bash "$DISPATCHER" close "nonexistent-xyz" 2>&1)
    local rc=$?

    if echo "$output" | grep -qi "does not exist"; then
        pass "close nonexistent: warns gracefully"
    else
        fail "close nonexistent: no warning for missing worker (rc=$rc)"
    fi
}
test_close_nonexistent

echo ""

# ----------------------------------------------------------
# TEST GROUP 6: List Workers
# ----------------------------------------------------------
echo "[Group 6] List Workers"

test_list() {
    local name="${TEST_PREFIX}-list1"
    bash "$DISPATCHER" create "$name" "$(pwd)" > /dev/null 2>&1
    sleep 2

    local output
    output=$(bash "$DISPATCHER" list 2>/dev/null)

    if echo "$output" | grep -q "${name}"; then
        pass "list: shows created worker in output"
    else
        fail "list: created worker not in list output"
    fi

    tmux kill-session -t "worker-${name}" 2>/dev/null
}
test_list

echo ""

# ----------------------------------------------------------
# TEST GROUP 7: Health Check
# ----------------------------------------------------------
echo "[Group 7] Health Check"

test_health_blocked_alert() {
    # Health check should detect blocked workers
    if awk '/^check_health/,/^}/' "$DISPATCHER" | grep -q "BLOCKED"; then
        pass "health: detects BLOCKED workers"
    else
        fail "health: does not check for BLOCKED state"
    fi
}
test_health_blocked_alert

test_health_error_alert() {
    if awk '/^check_health/,/^}/' "$DISPATCHER" | grep -q "ERROR"; then
        pass "health: detects ERROR workers"
    else
        fail "health: does not check for ERROR state"
    fi
}
test_health_error_alert

echo ""

# ----------------------------------------------------------
# TEST GROUP 8: Board Manager
# ----------------------------------------------------------
echo "[Group 8] Task Board (board-manager.sh)"

if [[ -f "$BOARD_MANAGER" ]]; then
    # Back up real board
    if [[ -f "$HOME/.claude/dispatcher/task-board.md" ]]; then
        cp "$HOME/.claude/dispatcher/task-board.md" "$HOME/.claude/dispatcher/task-board.md.orig"
    fi

    # Create a clean test board
    cat > "$HOME/.claude/dispatcher/task-board.md" << 'BOARD'
# Task Board

## Queue

## In Progress

## Done
BOARD

    source "$BOARD_MANAGER"

    # Test 8.1: board_add inserts a task
    test_board_add() {
        local output
        output=$(board_add P1 "Test task alpha")

        if grep -q "Test task alpha" "$HOME/.claude/dispatcher/task-board.md"; then
            pass "board add: task inserted into board file"
        else
            fail "board add: task not found in board file"
        fi

        if grep -q '\[assigned: none\]' "$HOME/.claude/dispatcher/task-board.md"; then
            pass "board add: task marked as unassigned"
        else
            fail "board add: missing [assigned: none] marker"
        fi
    }
    test_board_add

    # Test 8.2: board_add rejects invalid priority
    test_board_add_invalid() {
        local output
        output=$(board_add P9 "Bad priority task" 2>&1)

        if echo "$output" | grep -qi "Invalid priority"; then
            pass "board add invalid: rejects P9"
        else
            fail "board add invalid: did not reject P9"
        fi
    }
    test_board_add_invalid

    # Test 8.3: board_add sorts by priority
    test_board_priority_sort() {
        # Reset board
        cat > "$HOME/.claude/dispatcher/task-board.md" << 'BOARD'
# Task Board

## Queue

## In Progress

## Done
BOARD
        board_add P2 "Medium task" > /dev/null
        board_add P0 "Urgent task" > /dev/null
        board_add P3 "Low task" > /dev/null

        # P0 should appear before P2 which should appear before P3
        local p0_line p2_line p3_line
        p0_line=$(grep -n "Urgent task" "$HOME/.claude/dispatcher/task-board.md" | head -1 | cut -d: -f1)
        p2_line=$(grep -n "Medium task" "$HOME/.claude/dispatcher/task-board.md" | head -1 | cut -d: -f1)
        p3_line=$(grep -n "Low task" "$HOME/.claude/dispatcher/task-board.md" | head -1 | cut -d: -f1)

        if [[ -n "$p0_line" && -n "$p2_line" && -n "$p3_line" ]] && \
           (( p0_line < p2_line )) && (( p2_line < p3_line )); then
            pass "board priority: P0 < P2 < P3 ordering correct"
        else
            fail "board priority: incorrect order (P0:$p0_line P2:$p2_line P3:$p3_line)"
        fi
    }
    test_board_priority_sort

    # Test 8.4: board_claim assigns to worker
    test_board_claim() {
        # Reset with one task
        cat > "$HOME/.claude/dispatcher/task-board.md" << 'BOARD'
# Task Board

## Queue
- [P1] Claim test task [assigned: none]

## In Progress

## Done
BOARD

        local output
        output=$(board_claim "test-worker")

        if grep -q '\[assigned: test-worker\]' "$HOME/.claude/dispatcher/task-board.md"; then
            pass "board claim: task assigned to worker"
        else
            fail "board claim: assignment not found in board"
        fi

        # Task should have moved to In Progress
        local inprog_section
        inprog_section=$(sed -n '/^## In Progress/,/^## Done/p' "$HOME/.claude/dispatcher/task-board.md")
        if echo "$inprog_section" | grep -q "Claim test task"; then
            pass "board claim: task moved to In Progress section"
        else
            fail "board claim: task not in In Progress section"
        fi

        # Queue should be empty
        local queue_section
        queue_section=$(sed -n '/^## Queue/,/^## In Progress/p' "$HOME/.claude/dispatcher/task-board.md")
        if echo "$queue_section" | grep -q "Claim test task"; then
            fail "board claim: task still in Queue after claim"
        else
            pass "board claim: task removed from Queue"
        fi
    }
    test_board_claim

    # Test 8.5: board_claim prevents double-claim by same worker
    test_board_double_claim() {
        # Board already has test-worker with a task from previous test
        # Add another task and try to claim it with same worker
        board_add P1 "Second task" > /dev/null

        local output
        output=$(board_claim "test-worker" 2>&1)

        if echo "$output" | grep -q "already has a task"; then
            pass "board double claim: prevents worker from claiming two tasks"
        else
            fail "board double claim: did not prevent double claim"
        fi
    }
    test_board_double_claim

    # Test 8.6: board_claim with empty queue returns gracefully
    test_board_claim_empty() {
        cat > "$HOME/.claude/dispatcher/task-board.md" << 'BOARD'
# Task Board

## Queue

## In Progress

## Done
BOARD

        local output
        output=$(board_claim "empty-worker" 2>&1)

        if echo "$output" | grep -q "No unclaimed tasks"; then
            pass "board claim empty: handles empty queue gracefully"
        else
            fail "board claim empty: unexpected output on empty queue: $output"
        fi
    }
    test_board_claim_empty

    # Test 8.7: board_complete moves task to Done
    test_board_complete() {
        cat > "$HOME/.claude/dispatcher/task-board.md" << 'BOARD'
# Task Board

## Queue

## In Progress
- [P1] Complete test task [assigned: done-worker]

## Done
BOARD

        local output
        output=$(board_complete "done-worker" "finished successfully")

        local done_section
        done_section=$(sed -n '/^## Done/,$p' "$HOME/.claude/dispatcher/task-board.md")
        if echo "$done_section" | grep -q "Complete test task"; then
            pass "board complete: task moved to Done section"
        else
            fail "board complete: task not found in Done section"
        fi

        if echo "$done_section" | grep -q "completed: done-worker"; then
            pass "board complete: completion marker includes worker name"
        else
            fail "board complete: missing completion marker"
        fi

        if echo "$done_section" | grep -q "finished successfully"; then
            pass "board complete: summary text included"
        else
            fail "board complete: summary text missing"
        fi

        # In Progress should be empty
        local inprog_section
        inprog_section=$(sed -n '/^## In Progress/,/^## Done/p' "$HOME/.claude/dispatcher/task-board.md")
        if echo "$inprog_section" | grep -q "Complete test task"; then
            fail "board complete: task still in In Progress"
        else
            pass "board complete: task removed from In Progress"
        fi
    }
    test_board_complete

    # Test 8.8: board_complete for worker with no task
    test_board_complete_none() {
        cat > "$HOME/.claude/dispatcher/task-board.md" << 'BOARD'
# Task Board

## Queue

## In Progress

## Done
BOARD

        local output
        output=$(board_complete "ghost-worker" "nothing" 2>&1)
        local rc=$?

        if [[ $rc -ne 0 ]] || echo "$output" | grep -q "No in-progress task"; then
            pass "board complete none: handles missing task gracefully"
        else
            fail "board complete none: unexpected behavior for worker with no task"
        fi
    }
    test_board_complete_none

    # Test 8.9: board_next shows highest priority unclaimed task
    test_board_next() {
        cat > "$HOME/.claude/dispatcher/task-board.md" << 'BOARD'
# Task Board

## Queue
- [P0] Urgent thing [assigned: none]
- [P2] Chill thing [assigned: none]

## In Progress

## Done
BOARD

        local output
        output=$(board_next 2>&1)

        if echo "$output" | grep -q "Urgent thing"; then
            pass "board next: returns highest priority task"
        else
            fail "board next: did not return P0 task first"
        fi
    }
    test_board_next

    # Test 8.10: board_status shows correct counts
    test_board_status_counts() {
        cat > "$HOME/.claude/dispatcher/task-board.md" << 'BOARD'
# Task Board

## Queue
- [P1] Queued one [assigned: none]
- [P2] Queued two [assigned: none]

## In Progress
- [P0] Active one [assigned: worker-a]

## Done
- [P1] Finished one [completed: worker-b, 10:00 AM]
- [P2] Finished two [completed: worker-c, 11:00 AM]
- [P3] Finished three [completed: worker-d, 12:00 PM]
BOARD

        local output
        output=$(board_status 2>&1)

        if echo "$output" | grep -q "Queue:.*2"; then
            pass "board status: queue count correct (2)"
        else
            fail "board status: wrong queue count"
        fi

        if echo "$output" | grep -q "In Progress:.*1"; then
            pass "board status: in-progress count correct (1)"
        else
            fail "board status: wrong in-progress count"
        fi

        if echo "$output" | grep -q "Done:.*3"; then
            pass "board status: done count correct (3)"
        else
            fail "board status: wrong done count"
        fi

        if echo "$output" | grep -q "Total:.*6"; then
            pass "board status: total count correct (6)"
        else
            fail "board status: wrong total count"
        fi
    }
    test_board_status_counts

    # Restore original board
    cleanup_board

else
    echo "  SKIP: board-manager.sh not found, skipping board tests"
fi

echo ""

# ----------------------------------------------------------
# TEST GROUP 9: CLI Interface
# ----------------------------------------------------------
echo "[Group 9] CLI Interface"

# Test 9.1: help command works
test_help() {
    local output
    output=$(bash "$DISPATCHER" help 2>&1)

    if echo "$output" | grep -q "Hive Dispatcher"; then
        pass "help: shows 'Hive Dispatcher' (not Jarvis)"
    else
        fail "help: missing 'Hive Dispatcher' in help output"
    fi

    if echo "$output" | grep -q "send-loop"; then
        pass "help: send-loop command documented"
    else
        fail "help: send-loop command missing from help"
    fi
}
test_help

# Test 9.2: unknown command shows error
test_unknown_cmd() {
    local output
    output=$(bash "$DISPATCHER" foobar 2>&1)

    if echo "$output" | grep -q "Unknown command"; then
        pass "unknown cmd: shows error for invalid command"
    else
        fail "unknown cmd: no error for invalid command"
    fi
}
test_unknown_cmd

# Test 9.3: no Jarvis references remain
test_no_jarvis() {
    if grep -qi "jarvis" "$DISPATCHER"; then
        fail "no jarvis: dispatcher still contains 'Jarvis' references"
    else
        pass "no jarvis: all Jarvis references removed"
    fi
}
test_no_jarvis

echo ""

# ----------------------------------------------------------
# TEST GROUP 10: Conflict Detection
# ----------------------------------------------------------
echo "[Group 10] Conflict Detection"

test_conflict_check_exists() {
    if grep -q 'check_conflicts' "$DISPATCHER"; then
        pass "conflict detection: check_conflicts function exists"
    else
        fail "conflict detection: check_conflicts function missing"
    fi
}
test_conflict_check_exists

echo ""

# ============================================================
# FINAL CLEANUP
# ============================================================

cleanup_workers
teardown_mock_claude
restore_env
cleanup_board

# ============================================================
# RESULTS
# ============================================================

echo "========================================"
echo " RESULTS"
echo "========================================"
echo " PASS: $PASS"
echo " FAIL: $FAIL"
echo " TOTAL: $((PASS + FAIL))"
echo ""

if [[ $FAIL -gt 0 ]]; then
    echo "FAILURES:"
    echo -e "$ERRORS"
    echo ""
    echo "STATUS: SOME TESTS FAILED"
    exit 1
else
    echo "STATUS: ALL TESTS PASSED"
    exit 0
fi
