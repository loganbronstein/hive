#!/usr/bin/env bash
# migrate-to-hive.sh
#
# Moves the entire Hive dispatcher from ~/.claude/dispatcher/ to ~/.hive/
#
# Root cause: ~/.claude/ is a hardcoded protected path in Claude Code.
# --dangerously-skip-permissions does NOT override it. Workers hit permission
# prompts when writing to any path under ~/.claude/, making unattended
# operation impossible.
#
# Solution: move everything to ~/.hive/ (outside the protected zone) and
# create a backwards-compat symlink.
#
# Usage:
#   bash migrate-to-hive.sh          # dry run (shows what would happen)
#   bash migrate-to-hive.sh --run    # execute the migration
#
# Rollback:
#   bash migrate-to-hive.sh --rollback

set -euo pipefail

OLD_DIR="$HOME/.claude/dispatcher"
NEW_DIR="$HOME/.hive"
NIGHTLY_GUARD="$HOME/.claude/helpers/nightly-guard.sh"
DRY_RUN=true
ROLLBACK=false

if [[ "${1:-}" == "--run" ]]; then
    DRY_RUN=false
elif [[ "${1:-}" == "--rollback" ]]; then
    ROLLBACK=true
    DRY_RUN=false
fi

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[MIGRATE]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; }
info() { echo -e "${CYAN}[INFO]${NC} $1"; }
dry()  { echo -e "${YELLOW}[DRY RUN]${NC} would: $1"; }

act() {
    if [[ "$DRY_RUN" == true ]]; then
        dry "$1"
    else
        log "$1"
        eval "$2"
    fi
}

FILES_MOVED=0
PATHS_UPDATED=0
PLISTS_UPDATED=0

# ============================================================
# ROLLBACK
# ============================================================

if [[ "$ROLLBACK" == true ]]; then
    echo ""
    echo "========================================="
    echo " Hive Migration ROLLBACK"
    echo "========================================="
    echo ""

    if [[ ! -d "$NEW_DIR" ]]; then
        err "Nothing to rollback. $NEW_DIR does not exist."
        exit 1
    fi

    # Remove symlink if it exists
    if [[ -L "$OLD_DIR" ]]; then
        log "Removing symlink $OLD_DIR"
        rm "$OLD_DIR"
    fi

    # Move files back
    if [[ -d "${OLD_DIR}.pre-migration" ]]; then
        log "Restoring original $OLD_DIR from backup"
        mv "${OLD_DIR}.pre-migration" "$OLD_DIR"
    else
        log "Moving $NEW_DIR back to $OLD_DIR"
        cp -a "$NEW_DIR/" "$OLD_DIR"
    fi

    # Restore path references in dispatcher.sh
    if [[ -f "$OLD_DIR/dispatcher.sh" ]]; then
        sed -i '' 's|DISPATCHER_DIR="\$HOME/\.hive"|DISPATCHER_DIR="$HOME/.claude/dispatcher"|g' "$OLD_DIR/dispatcher.sh"
        sed -i '' 's|\~/\.hive|~/.claude/dispatcher|g' "$OLD_DIR/dispatcher.sh"
        sed -i '' 's|\$HOME/\.hive|$HOME/.claude/dispatcher|g' "$OLD_DIR/dispatcher.sh"
        log "Restored paths in dispatcher.sh"
    fi

    # Restore nightly-guard.sh
    if [[ -f "${NIGHTLY_GUARD}.pre-migration" ]]; then
        mv "${NIGHTLY_GUARD}.pre-migration" "$NIGHTLY_GUARD"
        log "Restored nightly-guard.sh from backup"
    elif [[ -f "$NIGHTLY_GUARD" ]]; then
        sed -i '' 's|/\.hive/|/.claude/dispatcher/|g' "$NIGHTLY_GUARD"
        sed -i '' 's|\.hive|.claude/dispatcher|g' "$NIGHTLY_GUARD"
        log "Restored paths in nightly-guard.sh"
    fi

    # Restore LaunchAgent plists
    for plist in "$HOME/Library/LaunchAgents"/*.plist; do
        [[ -f "$plist" ]] || continue
        if grep -q '\.hive' "$plist" 2>/dev/null; then
            sed -i '' 's|/\.hive/|/.claude/dispatcher/|g' "$plist"
            sed -i '' 's|/\.hive<|/.claude/dispatcher<|g' "$plist"
            log "Restored paths in $(basename "$plist")"
        fi
    done

    echo ""
    log "Rollback complete. Hive is back at $OLD_DIR"
    warn "You may need to reload LaunchAgents: launchctl bootout gui/\$(id -u) <plist> && launchctl bootstrap gui/\$(id -u) <plist>"
    exit 0
fi

# ============================================================
# PRE-FLIGHT CHECKS
# ============================================================

echo ""
echo "========================================="
if [[ "$DRY_RUN" == true ]]; then
    echo " Hive Migration Plan (DRY RUN)"
else
    echo " Hive Migration (LIVE)"
fi
echo " ~/.claude/dispatcher/ -> ~/.hive/"
echo "========================================="
echo ""

# Check source exists
if [[ ! -d "$OLD_DIR" ]]; then
    err "Source directory $OLD_DIR does not exist. Nothing to migrate."
    exit 1
fi

# Check target doesn't already exist
if [[ -d "$NEW_DIR" && ! -L "$NEW_DIR" ]]; then
    err "$NEW_DIR already exists. Remove it first or run --rollback."
    exit 1
fi

# Check no workers are running
ACTIVE_WORKERS=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^worker-' | wc -l | tr -d ' ')
if [[ "$ACTIVE_WORKERS" -gt 0 ]]; then
    err "$ACTIVE_WORKERS worker(s) are running. Close all workers first: bash $OLD_DIR/dispatcher.sh stop"
    exit 1
fi

# Check the symlink destination is not already occupied
if [[ -L "$OLD_DIR" ]]; then
    warn "$OLD_DIR is already a symlink. Migration may have already run."
    if [[ "$DRY_RUN" == true ]]; then
        exit 0
    fi
fi

info "Pre-flight checks passed."
echo ""

# ============================================================
# STEP 1: Create ~/.hive/ and copy files
# ============================================================

echo "--- Step 1: Copy files to ~/.hive/ ---"

act "create $NEW_DIR" "mkdir -p '$NEW_DIR'"

# Use rsync to preserve structure and permissions, exclude .git
act "copy all files from $OLD_DIR to $NEW_DIR (excluding .git)" \
    "rsync -a --exclude='.git' --exclude='node_modules' --exclude='migrate-to-hive.sh' '$OLD_DIR/' '$NEW_DIR/'"

if [[ "$DRY_RUN" == false ]]; then
    FILES_MOVED=$(find "$NEW_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')
    log "Copied $FILES_MOVED files"
else
    FILES_MOVED=$(find "$OLD_DIR" -type f -not -path '*/.git/*' -not -path '*/node_modules/*' 2>/dev/null | wc -l | tr -d ' ')
    dry "copy ~$FILES_MOVED files"
fi

# Also copy the migration script itself for reference
act "copy migrate-to-hive.sh to $NEW_DIR" "cp '$OLD_DIR/migrate-to-hive.sh' '$NEW_DIR/migrate-to-hive.sh'"

echo ""

# ============================================================
# STEP 2: Update paths in dispatcher.sh
# ============================================================

echo "--- Step 2: Update dispatcher.sh paths ---"

DISPATCHER="$NEW_DIR/dispatcher.sh"

if [[ "$DRY_RUN" == true ]]; then
    info "Paths to update in dispatcher.sh:"
    grep -n '\.claude/dispatcher' "$OLD_DIR/dispatcher.sh" | head -20
    PATHS_UPDATED=$(grep -c '\.claude/dispatcher' "$OLD_DIR/dispatcher.sh" || echo 0)
    dry "update $PATHS_UPDATED path references"
else
    # The main DISPATCHER_DIR variable controls most paths
    sed -i '' 's|DISPATCHER_DIR="\$HOME/\.claude/dispatcher"|DISPATCHER_DIR="$HOME/.hive"|' "$DISPATCHER"

    # Update any remaining hardcoded references
    sed -i '' 's|\$HOME/\.claude/dispatcher|\$HOME/.hive|g' "$DISPATCHER"
    sed -i '' 's|~/\.claude/dispatcher|~/.hive|g' "$DISPATCHER"

    # Also remove ~/.claude/dispatcher from --add-dir since we no longer need it
    # (the whole point is to escape the ~/.claude protected zone)
    sed -i '' 's| --add-dir \$HOME/\.claude/dispatcher||g' "$DISPATCHER"

    PATHS_UPDATED=$(echo "dispatcher.sh" | wc -w | tr -d ' ')
    log "Updated paths in dispatcher.sh"
fi

echo ""

# ============================================================
# STEP 3: Update paths in overnight-prompt.md
# ============================================================

echo "--- Step 3: Update overnight-prompt.md paths ---"

OVERNIGHT="$NEW_DIR/overnight-prompt.md"

if [[ "$DRY_RUN" == true ]]; then
    info "Paths to update in overnight-prompt.md:"
    grep -n '\.claude/dispatcher' "$OLD_DIR/overnight-prompt.md" | head -20
    local_count=$(grep -c '\.claude/dispatcher' "$OLD_DIR/overnight-prompt.md" || echo 0)
    dry "update $local_count path references"
else
    sed -i '' 's|~/\.claude/dispatcher|~/.hive|g' "$OVERNIGHT"
    sed -i '' 's|\$HOME/\.claude/dispatcher|\$HOME/.hive|g' "$OVERNIGHT"
    log "Updated paths in overnight-prompt.md"
fi

echo ""

# ============================================================
# STEP 4: Update paths in prompt-template.sh
# ============================================================

echo "--- Step 4: Update prompt-template.sh paths ---"

TEMPLATE="$NEW_DIR/prompt-template.sh"

if [[ "$DRY_RUN" == true ]]; then
    info "Paths to update in prompt-template.sh:"
    grep -n '\.claude/dispatcher' "$OLD_DIR/prompt-template.sh" | head -20
    local_count=$(grep -c '\.claude/dispatcher' "$OLD_DIR/prompt-template.sh" || echo 0)
    dry "update $local_count path references"
else
    sed -i '' 's|~/\.claude/dispatcher|~/.hive|g' "$TEMPLATE"
    sed -i '' 's|\$HOME/\.claude/dispatcher|\$HOME/.hive|g' "$TEMPLATE"
    log "Updated paths in prompt-template.sh"
fi

echo ""

# ============================================================
# STEP 5: Update paths in board-manager.sh
# ============================================================

echo "--- Step 5: Update board-manager.sh paths ---"

BOARD="$NEW_DIR/board-manager.sh"

if [[ "$DRY_RUN" == true ]]; then
    info "Paths to update in board-manager.sh:"
    grep -n '\.claude/dispatcher' "$OLD_DIR/board-manager.sh" | head -20
    local_count=$(grep -c '\.claude/dispatcher' "$OLD_DIR/board-manager.sh" || echo 0)
    dry "update $local_count path references"
else
    sed -i '' 's|\$HOME/\.claude/dispatcher|\$HOME/.hive|g' "$BOARD"
    sed -i '' 's|~/\.claude/dispatcher|~/.hive|g' "$BOARD"
    log "Updated paths in board-manager.sh"
fi

echo ""

# ============================================================
# STEP 6: Update paths in tests/test-dispatcher.sh
# ============================================================

echo "--- Step 6: Update test suite paths ---"

TESTS="$NEW_DIR/tests/test-dispatcher.sh"

if [[ "$DRY_RUN" == true ]]; then
    info "Paths to update in tests/test-dispatcher.sh:"
    grep -n '\.claude/dispatcher' "$OLD_DIR/tests/test-dispatcher.sh" | head -20
    local_count=$(grep -c '\.claude/dispatcher' "$OLD_DIR/tests/test-dispatcher.sh" || echo 0)
    dry "update $local_count path references"
else
    sed -i '' 's|\$HOME/\.claude/dispatcher|\$HOME/.hive|g' "$TESTS"
    sed -i '' 's|~/\.claude/dispatcher|~/.hive|g' "$TESTS"
    log "Updated paths in tests/test-dispatcher.sh"
fi

echo ""

# ============================================================
# STEP 7: Update paths in HIVE.md
# ============================================================

echo "--- Step 7: Update HIVE.md paths ---"

HIVEMD="$NEW_DIR/HIVE.md"

if [[ "$DRY_RUN" == true ]]; then
    info "Paths to update in HIVE.md:"
    grep -n '\.claude/dispatcher' "$OLD_DIR/HIVE.md" 2>/dev/null | head -20
    local_count=$(grep -c '\.claude/dispatcher' "$OLD_DIR/HIVE.md" 2>/dev/null || echo 0)
    dry "update $local_count path references"
else
    if [[ -f "$HIVEMD" ]]; then
        sed -i '' 's|~/\.claude/dispatcher|~/.hive|g' "$HIVEMD"
        sed -i '' 's|\$HOME/\.claude/dispatcher|\$HOME/.hive|g' "$HIVEMD"
        log "Updated paths in HIVE.md"
    fi
fi

echo ""

# ============================================================
# STEP 8: Update nightly-guard.sh
# ============================================================

echo "--- Step 8: Update nightly-guard.sh ---"

if [[ -f "$NIGHTLY_GUARD" ]]; then
    if [[ "$DRY_RUN" == true ]]; then
        info "Paths to update in nightly-guard.sh:"
        grep -n '\.claude/dispatcher' "$NIGHTLY_GUARD" | head -20
        local_count=$(grep -c '\.claude/dispatcher' "$NIGHTLY_GUARD" || echo 0)
        dry "update $local_count path references"
    else
        # Back up the original
        cp "$NIGHTLY_GUARD" "${NIGHTLY_GUARD}.pre-migration"

        sed -i '' 's|\$HOME/\.claude/dispatcher|$HOME/.hive|g' "$NIGHTLY_GUARD"
        sed -i '' 's|~/\.claude/dispatcher|~/.hive|g' "$NIGHTLY_GUARD"
        log "Updated paths in nightly-guard.sh (backup: nightly-guard.sh.pre-migration)"
    fi
else
    warn "nightly-guard.sh not found at $NIGHTLY_GUARD, skipping"
fi

echo ""

# ============================================================
# STEP 9: Update LaunchAgent plists
# ============================================================

echo "--- Step 9: Update LaunchAgent plists ---"

for plist in "$HOME/Library/LaunchAgents"/*.plist; do
    [[ -f "$plist" ]] || continue
    plist_name=$(basename "$plist")

    if grep -q '\.claude/dispatcher' "$plist" 2>/dev/null; then
        if [[ "$DRY_RUN" == true ]]; then
            info "Plist with old paths: $plist_name"
            grep -n '\.claude/dispatcher' "$plist"
            dry "update paths in $plist_name"
        else
            # Back up
            cp "$plist" "${plist}.pre-migration"

            sed -i '' 's|/\.claude/dispatcher/|/.hive/|g' "$plist"
            sed -i '' 's|/\.claude/dispatcher<|/.hive<|g' "$plist"

            PLISTS_UPDATED=$((PLISTS_UPDATED + 1))
            log "Updated paths in $plist_name (backup: ${plist_name}.pre-migration)"
        fi
    fi
done

if [[ "$PLISTS_UPDATED" -eq 0 && "$DRY_RUN" == false ]]; then
    info "No LaunchAgent plists referenced the old path"
fi

echo ""

# ============================================================
# STEP 10: Create backwards-compatibility symlink
# ============================================================

echo "--- Step 10: Create backwards-compat symlink ---"

if [[ "$DRY_RUN" == true ]]; then
    dry "move $OLD_DIR to ${OLD_DIR}.pre-migration"
    dry "create symlink $OLD_DIR -> $NEW_DIR"
else
    # Rename the old directory as backup
    mv "$OLD_DIR" "${OLD_DIR}.pre-migration"

    # Create symlink: ~/.claude/dispatcher -> ~/.hive
    ln -s "$NEW_DIR" "$OLD_DIR"
    log "Created symlink: $OLD_DIR -> $NEW_DIR"
    log "Original backed up to: ${OLD_DIR}.pre-migration"
fi

echo ""

# ============================================================
# STEP 11: Verify
# ============================================================

echo "--- Step 11: Verification ---"

if [[ "$DRY_RUN" == false ]]; then
    VERIFY_PASS=0
    VERIFY_FAIL=0

    # Check new dir exists
    if [[ -d "$NEW_DIR" ]]; then
        log "PASS: $NEW_DIR exists"
        VERIFY_PASS=$((VERIFY_PASS + 1))
    else
        err "FAIL: $NEW_DIR does not exist"
        VERIFY_FAIL=$((VERIFY_FAIL + 1))
    fi

    # Check dispatcher.sh is executable
    if [[ -x "$NEW_DIR/dispatcher.sh" ]]; then
        log "PASS: dispatcher.sh is executable"
        VERIFY_PASS=$((VERIFY_PASS + 1))
    else
        err "FAIL: dispatcher.sh not executable"
        VERIFY_FAIL=$((VERIFY_FAIL + 1))
    fi

    # Check no old paths remain in key files
    OLD_REFS=0
    for file in dispatcher.sh overnight-prompt.md prompt-template.sh board-manager.sh; do
        if [[ -f "$NEW_DIR/$file" ]] && grep -q '\.claude/dispatcher' "$NEW_DIR/$file" 2>/dev/null; then
            remaining=$(grep -c '\.claude/dispatcher' "$NEW_DIR/$file")
            err "FAIL: $file still has $remaining old path references"
            VERIFY_FAIL=$((VERIFY_FAIL + 1))
            OLD_REFS=$((OLD_REFS + remaining))
        fi
    done
    if [[ "$OLD_REFS" -eq 0 ]]; then
        log "PASS: no old path references in key files"
        VERIFY_PASS=$((VERIFY_PASS + 1))
    fi

    # Check symlink
    if [[ -L "$OLD_DIR" ]]; then
        LINK_TARGET=$(readlink "$OLD_DIR")
        if [[ "$LINK_TARGET" == "$NEW_DIR" ]]; then
            log "PASS: symlink $OLD_DIR -> $NEW_DIR"
            VERIFY_PASS=$((VERIFY_PASS + 1))
        else
            err "FAIL: symlink points to $LINK_TARGET instead of $NEW_DIR"
            VERIFY_FAIL=$((VERIFY_FAIL + 1))
        fi
    else
        err "FAIL: no symlink at $OLD_DIR"
        VERIFY_FAIL=$((VERIFY_FAIL + 1))
    fi

    # Check nightly-guard.sh if it exists
    if [[ -f "$NIGHTLY_GUARD" ]]; then
        if grep -q '\.claude/dispatcher' "$NIGHTLY_GUARD" 2>/dev/null; then
            remaining=$(grep -c '\.claude/dispatcher' "$NIGHTLY_GUARD")
            err "FAIL: nightly-guard.sh still has $remaining old path references"
            VERIFY_FAIL=$((VERIFY_FAIL + 1))
        else
            log "PASS: nightly-guard.sh paths updated"
            VERIFY_PASS=$((VERIFY_PASS + 1))
        fi
    fi

    echo ""
    log "Verification: $VERIFY_PASS passed, $VERIFY_FAIL failed"

    if [[ "$VERIFY_FAIL" -gt 0 ]]; then
        warn "Some verifications failed. Review the output above."
        warn "To rollback: bash $NEW_DIR/migrate-to-hive.sh --rollback"
    fi
else
    info "Skipping verification (dry run)"
fi

echo ""

# ============================================================
# SUMMARY
# ============================================================

echo "========================================="
if [[ "$DRY_RUN" == true ]]; then
    echo " DRY RUN SUMMARY"
else
    echo " MIGRATION COMPLETE"
fi
echo "========================================="
echo ""

echo "Files:"
echo "  Source:    $OLD_DIR"
echo "  Target:    $NEW_DIR"
echo "  Files:     ~$FILES_MOVED"
echo ""

echo "Path updates:"
echo "  dispatcher.sh         ~/.claude/dispatcher -> ~/.hive"
echo "  overnight-prompt.md   ~/.claude/dispatcher -> ~/.hive"
echo "  prompt-template.sh    ~/.claude/dispatcher -> ~/.hive"
echo "  board-manager.sh      ~/.claude/dispatcher -> ~/.hive"
echo "  tests/test-dispatcher.sh  ~/.claude/dispatcher -> ~/.hive"
echo "  HIVE.md               ~/.claude/dispatcher -> ~/.hive"
if [[ -f "$NIGHTLY_GUARD" ]]; then
    echo "  nightly-guard.sh      ~/.claude/dispatcher -> ~/.hive"
fi
echo "  LaunchAgent plists    $PLISTS_UPDATED updated"
echo ""

echo "Backwards compat:"
echo "  Symlink: ~/.claude/dispatcher -> ~/.hive"
echo "  Backup:  ~/.claude/dispatcher.pre-migration/"
echo ""

if [[ "$DRY_RUN" == true ]]; then
    echo "This was a DRY RUN. No files were changed."
    echo ""
    echo "To execute: bash $OLD_DIR/migrate-to-hive.sh --run"
    echo "To rollback after running: bash ~/.hive/migrate-to-hive.sh --rollback"
else
    echo "Post-migration steps:"
    echo "  1. Reload LaunchAgents that were updated:"
    echo "     launchctl bootout gui/\$(id -u) ~/Library/LaunchAgents/com.dispatcher.monitor.plist"
    echo "     launchctl bootstrap gui/\$(id -u) ~/Library/LaunchAgents/com.dispatcher.monitor.plist"
    echo ""
    echo "  2. Test the dispatcher:"
    echo "     bash ~/.hive/dispatcher.sh list"
    echo "     bash ~/.hive/dispatcher.sh help"
    echo ""
    echo "  3. Run the test suite:"
    echo "     bash ~/.hive/tests/test-dispatcher.sh"
    echo ""
    echo "  4. If everything works, you can delete the backup:"
    echo "     rm -rf ~/.claude/dispatcher.pre-migration"
    echo ""
    echo "  5. If something breaks, rollback:"
    echo "     bash ~/.hive/migrate-to-hive.sh --rollback"
fi
echo ""
