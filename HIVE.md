# Hive Operating Manual

Read this file at the start of every session. This is the permanent reference for how to operate the Hive multi-terminal orchestrator.

## What Hive Is

Hive is a multi-terminal orchestrator for Claude Code. It manages worker terminals via tmux, dispatches tasks, monitors status, and runs autonomously overnight.

Architecture: Logan talks to Hive. Hive talks to workers. Workers execute.

Core files:
- `dispatcher.sh` — CLI for worker lifecycle, task dispatch, health checks, night mode
- `board-manager.sh` — task board operations (add, claim, complete, next, status)
- `overnight-prompt.md` — self-directing autonomous runner prompt
- `task-board.md` — shared queue workers pull tasks from
- `worker-prompts/` — saved copies of every prompt sent to workers (for debugging and replay)
- `tests/test-dispatcher.sh` — test suite with mock Claude binary

## Worker Launch Flags

Workers are launched with full permission bypass:

```
claude --dangerously-skip-permissions --permission-mode bypassPermissions \
  --add-dir ~/.claude/dispatcher \
  --add-dir ~/Sale\ Advisor \
  --add-dir ~/Sale\ Advisor/Website/sale-advisor-website \
  --add-dir ~/Sale\ Advisor/Projects/ListFlow
```

- `--dangerously-skip-permissions` — bypasses the tool permission system entirely
- `--permission-mode bypassPermissions` — additional bypass layer
- `--add-dir` — pre-trusts directories so workers can read and write without prompts

All three flags are required. Removing any one causes permission popups that block unattended operation.

## Known Issues

### --bare breaks OAuth
The `--bare` flag was removed because it disables MCP server connections, OAuth flows, and other features workers need. Never re-add it.

### Permission prompts for new file creation
Even with full bypass flags, workers sometimes get prompted when creating files in directories not covered by `--add-dir`. Workaround: add the target directory with `--add-dir` at launch. If a worker gets stuck on a permission prompt, it will appear IDLE or BLOCKED.

### Stop hooks show cosmetic BLOCKED errors
When workers are closed via `/exit` or session kill, Claude Code's shutdown hooks may print BLOCKED errors to the pane. These are cosmetic. The worker is still closing properly. Do not treat these as real failures.

### Paste timing
The dispatcher uses `tmux load-buffer` + `tmux paste-buffer` + `sleep 2` + `Enter` to deliver prompts. The sleep between paste and Enter is critical. Without it, tmux sends Enter before the paste buffer renders, causing truncated or empty prompts.

## Prompt Engineering Rules

Workers know NOTHING about the current session. Every prompt must be completely self-contained.

### Required elements in every worker prompt:
1. **What to do** — exact task description, not vague goals
2. **Where to work** — directory path, file names
3. **Project context** — tell the worker to read CLAUDE.md in the target project
4. **What "done" looks like** — specific deliverables
5. **Structured output markers** — workers must output:
   - `DONE: [summary]` when finished
   - `BLOCKED: [reason]` if stuck on something they cannot resolve
   - `PROGRESS: X/Y [description]` as they work
   - `ERROR: [detail]` if something breaks

### Quality bar:
- Never send a one-line prompt. Workers without context produce garbage.
- Include the specific files to create or modify when possible.
- If the task touches the CRM or website, tell the worker the stack (Next.js, Supabase, Tailwind, etc.).
- If the task requires reading existing code first, say so explicitly.
- If the task has constraints (no external API calls, no database writes), state them.

### Example prompt structure:
```
You are working on the Sale Advisor CRM at ~/Sale Advisor/Website/sale-advisor-website.

Read ~/Sale Advisor/CLAUDE.md first for project rules and conventions.

Task: [specific description]

Files to modify: [list]
What "done" looks like: [criteria]

Output DONE: [summary] when finished.
Output BLOCKED: [reason] if stuck.
Output PROGRESS: X/Y [description] as you work.
```

## Worker Management

### Never close workers after task completion
Workers are expensive to create (Terminal.app window + tmux session + Claude init = ~8 seconds). After a worker finishes a task, reuse it by sending the next task. Only close workers when:
- The session is ending
- The worker is stuck and restarting is faster than debugging
- You need to change the working directory (requires a new worker)

### Never let workers sit idle
After a worker reports DONE, immediately send the next task or close it. Idle workers waste terminal real estate and make status harder to read.

### Check status proactively
Use `dispatcher.sh status` regularly (every few minutes during active work). Do not wait for workers to report. The status command reads the last 20 lines of each worker's pane and detects DONE, BLOCKED, ERROR, WORKING, or IDLE states.

### Worker limits
Max 10 workers total. Overnight mode caps at 4. If you hit the limit, close finished or idle workers first.

## Task Board

The task board at `task-board.md` is a shared queue. Workers using `send-loop` automatically check for unclaimed tasks after completing their current work.

Board operations (source `board-manager.sh` first):
- `board_add P0|P1|P2|P3 "description"` — add task, auto-sorted by priority
- `board_claim worker-name` — assign next unclaimed task to a worker
- `board_complete worker-name "summary"` — move task to Done
- `board_next` — peek at next unclaimed task
- `board_status` — show counts (queue, in-progress, done)

Priority levels: P0 (urgent), P1 (high), P2 (medium), P3 (low).

Workers cannot claim two tasks simultaneously. Complete the current task before claiming the next.

## Overnight Runner

The overnight runner (`overnight-prompt.md`) is a self-directing autonomous agent that runs while Logan is asleep.

### How it works:
1. Reads the day's context (terminal files, COORDINATION.md, CLAUDE.md, git log, daily notes, tonight-brief.md)
2. Builds its own task list sorted by impact
3. Creates workers, sends tasks, monitors completion, repeats
4. Writes results to `morning-report.md` and `overnight-state.md`
5. Stops at the configured end time (default 8:30 AM CDT) or when no valuable work remains

### Priority framework (in order):
1. Explicit queued tasks (task-queue.md, overnight.md)
2. Unfinished work from today
3. Things Logan mentioned wanting
4. Code quality: hardening, tests, error handling, security
5. Research for upcoming projects
6. Stale vault notes, cleanup, documentation
7. If nothing above threshold: STOP. Do not burn tokens on busywork.

### Safety rails (absolute, no exceptions):
- **Nothing goes public** — no git push, no deploy, no social media, no emails/SMS, no GitHub issues/PRs, no external writes
- **No money, no damage** — no paid API calls, no prod database writes, no .env modifications, no destructive deletes
- **Operational limits** — max 4 workers, local branches only, read-only external access
- All work stays LOCAL until Logan reviews it in the morning

### Task sizing by time remaining:
- 4+ hours: big tasks (deep research, feature builds, multi-file refactors)
- 1-4 hours: medium tasks (single features, test suites, API work)
- 30-60 min: small tasks (bug fixes, vault updates, code cleanup)
- Under 30 min: micro tasks only
- Under 15 min: write final morning report and stop

## Testing

### Test suite
Run the full test suite:
```
bash tests/test-dispatcher.sh
```

The test suite uses a mock Claude binary (no API key or network needed). It covers:
- Worker lifecycle (create, duplicate rejection, max workers, --add-dir flags, no --bare)
- Task sending (delivery, file save, paste timing, nonexistent worker, send-loop suffix)
- Read output (capture, nonexistent worker)
- Status detection (DONE, BLOCKED, ERROR, WORKING, NOT_FOUND, summary table)
- Close and cleanup (/exit before kill, close-all, nonexistent worker)
- List workers
- Health check (BLOCKED and ERROR detection)
- Task board (add, priority sort, claim, double-claim prevention, complete, next, status counts)
- CLI interface (help text, unknown command, no Jarvis references)
- Conflict detection

### Self-test at startup
Before dispatching work, verify the system is functional:
1. Check `tmux` is available: `which tmux`
2. Check `claude` binary exists: `ls ~/.local/bin/claude`
3. Check dispatcher is executable: `ls -la ~/.claude/dispatcher/dispatcher.sh`
4. Run a quick `dispatcher.sh list` to confirm tmux communication works

## CLI Reference

```
dispatcher.sh create <name> [dir]       Create a new worker terminal
dispatcher.sh close <name>              Close a worker terminal
dispatcher.sh close-all                 Close all worker terminals
dispatcher.sh send <name> <prompt>      Send a task to a worker
dispatcher.sh send-loop <name> <prompt> Send task + auto-pick-up next from task-board
dispatcher.sh read <name> [lines]       Read worker output (default: 100 lines)
dispatcher.sh list                      List all active workers
dispatcher.sh status [name]             Show status (all workers or specific one)
dispatcher.sh health                    Health check all workers
dispatcher.sh stop                      Gracefully stop all workers
dispatcher.sh night [end_time]          Start night mode (default end: 08:45)
dispatcher.sh help                      Show help
```
