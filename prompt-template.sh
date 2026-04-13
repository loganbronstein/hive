#!/usr/bin/env bash
# Hive Prompt Template System
# Wraps every worker prompt with standard context, quality bar, and output format.
# Source this from dispatcher.sh or call directly.

# ============================================================
# build_prompt <project_dir> <task_description>
#
# Returns a fully wrapped prompt with project context,
# quality expectations, and structured output format.
# ============================================================
build_prompt() {
    local project_dir="$1"
    local task="$2"

    cat <<PROMPT
You are a Hive worker terminal. You are a senior engineer.
Project directory: ${project_dir}
Read CLAUDE.md in the project root for project rules and conventions.
Quality bar: would a staff engineer approve this? Plan your approach before coding.

--- TASK ---
${task}
--- END TASK ---

When done output: DONE: [summary of what you did, files changed, how to verify]
If blocked output: BLOCKED: [specific reason]
Do NOT stop to ask for permission. Execute autonomously.
PROMPT
}

# ============================================================
# build_loop_prompt <project_dir> <task_description>
#
# Same as build_prompt but appends task-board auto-pickup
# so the worker grabs the next task when finished.
# ============================================================
build_loop_prompt() {
    local project_dir="$1"
    local task="$2"

    cat <<PROMPT
$(build_prompt "$project_dir" "$task")

AFTER completing this task, check ~/.claude/dispatcher/task-board.md for unclaimed tasks in the Queue section. If there is an unclaimed task, claim it by outputting CLAIMING: [task description], then start working on it immediately. If no tasks are available, output IDLE and wait for the next task.
PROMPT
}

# ============================================================
# Self-test when run directly
# ============================================================
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "=== build_prompt test ==="
    echo ""
    build_prompt "$HOME/Sale Advisor" "Fix the broken login redirect on /admin. Users get a 404 after magic link click."
    echo ""
    echo "=== build_loop_prompt test ==="
    echo ""
    build_loop_prompt "$HOME/Sale Advisor/Projects/ListFlow" "Set up the Next.js project scaffold with App Router, TypeScript, Tailwind, and Prisma."
fi
