#!/bin/bash
# Claude Code Watchdog — kills hung/zombie processes that burn CPU
# Works on macOS and Linux
# Context: https://github.com/anthropics/claude-code/issues/22275
#
# Known causes (all still open as of March 2026):
#   - TUI renderer never idles (Ink/React runs at ~60Hz even when idle)
#   - Busy-wait event loop in Bun runtime (epoll_pwait timeout=0)
#   - Memory allocation thrashing (mmap/munmap cycles)
#   - caffeinate process leak on macOS (never cleaned up)
#   - Orphaned child processes after session close (Desktop/VS Code)

set -euo pipefail

# --- Config (override via environment) ---
CPU_THRESHOLD=${CPU_THRESHOLD:-80}          # Kill processes above this % CPU
MIN_AGE_SECONDS=${MIN_AGE_SECONDS:-120}     # Only kill if running longer than this
LOG_FILE=${LOG_FILE:-/tmp/claude-watchdog.log}
DRY_RUN=${DRY_RUN:-false}                  # Set to "true" to log without killing

OS="$(uname -s)"
NOW="$(date +%s)"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

get_process_age_seconds() {
    local pid=$1
    if [[ "$OS" == "Darwin" ]]; then
        local start_epoch
        start_epoch=$(ps -o lstart= -p "$pid" 2>/dev/null | xargs -I{} date -j -f "%c" "{}" "+%s" 2>/dev/null) || return 1
        echo $(( NOW - start_epoch ))
    else
        local etimes
        etimes=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ') || return 1
        echo "$etimes"
    fi
}

kill_process() {
    local pid=$1
    local reason=$2
    local cmd
    cmd=$(ps -o args= -p "$pid" 2>/dev/null || echo "unknown")

    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY RUN] Would kill PID $pid ($reason) — $cmd"
        return
    fi

    log "Killing PID $pid ($reason) — $cmd"
    kill -TERM "$pid" 2>/dev/null || true
    sleep 2
    if kill -0 "$pid" 2>/dev/null; then
        log "PID $pid did not exit, sending SIGKILL"
        kill -9 "$pid" 2>/dev/null || true
    fi
}

# --- 1. Kill orphaned caffeinate processes (macOS only) ---
kill_orphan_caffeinate() {
    [[ "$OS" != "Darwin" ]] && return

    local count=0
    while IFS= read -r pid; do
        [[ -z "$pid" ]] && continue
        local ppid
        ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ') || continue

        # Orphaned = parent is PID 1 (launchd) or parent no longer exists
        if [[ "$ppid" == "1" ]] || ! kill -0 "$ppid" 2>/dev/null; then
            kill_process "$pid" "orphaned caffeinate"
            ((count++)) || true
        fi
    done < <(pgrep -x caffeinate 2>/dev/null || true)

    [[ $count -gt 0 ]] && log "Cleaned $count orphaned caffeinate process(es)"
}

# --- 2. Kill claude/node processes burning CPU ---
kill_cpu_hogs() {
    local count=0

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local pid cpu cmd
        pid=$(echo "$line" | awk '{print $1}')
        cpu=$(echo "$line" | awk '{print $2}' | cut -d. -f1)
        cmd=$(echo "$line" | awk '{for(i=3;i<=NF;i++) printf "%s ", $i; print ""}')

        # Only target claude-related processes
        if ! echo "$cmd" | grep -qiE 'claude|@anthropic'; then
            continue
        fi

        # Check if CPU is above threshold
        if [[ "$cpu" -lt "$CPU_THRESHOLD" ]]; then
            continue
        fi

        # Check process age — don't kill recently started processes
        local age
        age=$(get_process_age_seconds "$pid") || continue
        if [[ "$age" -lt "$MIN_AGE_SECONDS" ]]; then
            continue
        fi

        # Check if process has a controlling terminal (active session)
        local tty
        tty=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ') || continue
        if [[ "$tty" != "??" && "$tty" != "?" && -n "$tty" ]]; then
            # Has a TTY — active session, skip
            continue
        fi

        kill_process "$pid" "CPU ${cpu}%, age ${age}s, no TTY"
        ((count++)) || true
    done < <(ps -eo pid,%cpu,args 2>/dev/null | tail -n +2)

    [[ $count -gt 0 ]] && log "Killed $count CPU-hogging process(es)"
}

# --- 3. Kill orphaned processes from dead sessions ---
kill_orphaned_children() {
    local count=0

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local pid ppid cpu cmd
        pid=$(echo "$line" | awk '{print $1}')
        ppid=$(echo "$line" | awk '{print $2}')
        cpu=$(echo "$line" | awk '{print $3}' | cut -d. -f1)
        cmd=$(echo "$line" | awk '{for(i=4;i<=NF;i++) printf "%s ", $i; print ""}')

        # Only claude-related
        if ! echo "$cmd" | grep -qiE 'claude|@anthropic'; then
            continue
        fi

        # Parent is init/launchd (orphaned)
        if [[ "$ppid" != "1" ]]; then
            continue
        fi

        # Must be consuming notable CPU
        if [[ "$cpu" -lt 10 ]]; then
            continue
        fi

        local age
        age=$(get_process_age_seconds "$pid") || continue
        if [[ "$age" -lt "$MIN_AGE_SECONDS" ]]; then
            continue
        fi

        kill_process "$pid" "orphaned (ppid=1), CPU ${cpu}%, age ${age}s"
        ((count++)) || true
    done < <(ps -eo pid,ppid,%cpu,args 2>/dev/null | tail -n +2)

    [[ $count -gt 0 ]] && log "Killed $count orphaned process(es)"
}

# --- Main ---
log "Watchdog run started (threshold=${CPU_THRESHOLD}%, min_age=${MIN_AGE_SECONDS}s, dry_run=${DRY_RUN})"

kill_orphan_caffeinate
kill_cpu_hogs
kill_orphaned_children

log "Watchdog run complete"
