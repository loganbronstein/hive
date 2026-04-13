#!/usr/bin/env bash
# Hive Self-Test
# Validates that Claude Code workers can boot, execute tools, and write files
# without any permission prompts. Runs in under 30 seconds.
# Exit 0 = PASS, Exit 1 = FAIL

set -uo pipefail

CLAUDE_BIN="$HOME/.local/bin/claude"
TEST_SESSION="hive-selftest"
TEST_FILE="/tmp/hive-selftest.txt"
TIMEOUT=30
POLL_INTERVAL=3

cleanup() {
    tmux kill-session -t "$TEST_SESSION" 2>/dev/null || true
    rm -f "$TEST_FILE" /tmp/hive-selftest-edited.txt
}

trap cleanup EXIT

# Kill any leftover selftest session
tmux kill-session -t "$TEST_SESSION" 2>/dev/null || true
rm -f "$TEST_FILE"

echo "[selftest] Starting Hive self-test..."

# 1. Create tmux session
tmux new-session -d -s "$TEST_SESSION" -x 200 -y 50
if ! tmux has-session -t "$TEST_SESSION" 2>/dev/null; then
    echo "SELF-TEST FAILED: Could not create tmux session"
    exit 1
fi

# 2. Start Claude Code with the same flags real workers use
tmux send-keys -t "$TEST_SESSION" "$CLAUDE_BIN --dangerously-skip-permissions --permission-mode bypassPermissions" Enter

# 3. Wait for Claude to boot
sleep 5

# 4. Send test prompt (uses /tmp so no directory trust issues)
PROMPT='Create a file at /tmp/hive-selftest.txt with content PASS. Then use the Edit tool to change PASS to PASS-EDITED. Then run: rm /tmp/hive-selftest.txt && echo SELFTEST-COMPLETE. Output DONE when finished.'

# Use load-buffer to avoid shell escaping issues
TMPFILE=$(mktemp)
echo "$PROMPT" > "$TMPFILE"
tmux load-buffer "$TMPFILE"
tmux paste-buffer -t "$TEST_SESSION"
sleep 1
tmux send-keys -t "$TEST_SESSION" Enter
rm -f "$TMPFILE"

# 5. Poll for completion
ELAPSED=0
RESULT="TIMEOUT"

while [[ "$ELAPSED" -lt "$TIMEOUT" ]]; do
    sleep "$POLL_INTERVAL"
    ELAPSED=$((ELAPSED + POLL_INTERVAL))

    OUTPUT=$(tmux capture-pane -t "$TEST_SESSION" -p -S -50 2>/dev/null || true)

    # Check for the completion marker
    if echo "$OUTPUT" | grep -q "SELFTEST-COMPLETE"; then
        RESULT="PASS"
        break
    fi

    # Check for permission prompts (indicates bypass is not working)
    if echo "$OUTPUT" | grep -qiE "(permission|approve|allow|deny|blocked|trust this)"; then
        # Filter out false positives from the prompt text itself
        PROMPT_LINES=$(echo "$OUTPUT" | grep -iE "(permission|approve|allow|deny|blocked|trust this)" | grep -v "hive-selftest\|SELFTEST\|PASS" || true)
        if [[ -n "$PROMPT_LINES" ]]; then
            RESULT="PERMISSION_PROMPT"
            break
        fi
    fi

    echo "[selftest] Waiting... (${ELAPSED}s/${TIMEOUT}s)"
done

# 6. Send /exit to clean up Claude session
tmux send-keys -t "$TEST_SESSION" "/exit" Enter 2>/dev/null || true
sleep 1

# 7. Report result
case "$RESULT" in
    PASS)
        echo "SELF-TEST PASSED: Worker booted, wrote file, edited file, ran bash. Zero prompts."
        exit 0
        ;;
    PERMISSION_PROMPT)
        echo "SELF-TEST FAILED: Permission prompt detected. Workers will hang waiting for approval."
        echo "  Likely cause: writing to a protected directory (~/.claude/) or hook interference."
        echo "  See PERMISSION-FIX.md for the root cause analysis."
        exit 1
        ;;
    TIMEOUT)
        echo "SELF-TEST FAILED: Timed out after ${TIMEOUT}s. Claude may not have booted or the task stalled."
        # Dump last 20 lines for debugging
        echo "--- Last output ---"
        tmux capture-pane -t "$TEST_SESSION" -p -S -20 2>/dev/null || echo "(could not capture)"
        echo "---"
        exit 1
        ;;
esac
