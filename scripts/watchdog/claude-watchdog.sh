#!/bin/bash
# ==============================================================================
# Claude Code Watchdog v2
# Kills hung, runaway, and memory-leaking Claude Code processes.
# Works on macOS and Linux.
#
# Changes from v1:
#   - MIN_AGE reduced from 120s to 60s
#   - Memory absolute threshold check (MEM_THRESHOLD_MB)
#   - Memory growth rate tracking (kills on >500MB growth between checks)
#   - Runs every 60s instead of 300s
#
# Related: https://github.com/anthropics/claude-code/issues/22275
# ==============================================================================

set -uo pipefail

# ---------- Config (all overridable via env vars) ----------
CPU_THRESHOLD="${CPU_THRESHOLD:-80}"
MEM_THRESHOLD_MB="${MEM_THRESHOLD_MB:-3072}"
MIN_AGE_SECONDS="${MIN_AGE_SECONDS:-60}"
LOG_FILE="${LOG_FILE:-/tmp/claude-watchdog.log}"
DRY_RUN="${DRY_RUN:-false}"
MEM_SNAPSHOT_DIR="${MEM_SNAPSHOT_DIR:-/tmp/claude-watchdog-snapshots}"
MEM_GROWTH_LIMIT_MB="${MEM_GROWTH_LIMIT_MB:-500}"

# Detect OS once
OS="$(uname -s)"

# Ensure snapshot dir exists
mkdir -p "$MEM_SNAPSHOT_DIR"

# ---------- Functions ----------

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# Returns process age in seconds. Prints nothing and returns 1 if pid is gone.
get_process_age_seconds() {
    local pid="$1"

    if [[ "$OS" == "Darwin" ]]; then
        # macOS: ps -o lstart= gives something like "Thu Mar 27 14:22:01 2026"
        local lstart
        lstart="$(ps -o lstart= -p "$pid" 2>/dev/null)" || return 1
        lstart="$(echo "$lstart" | xargs)"  # trim whitespace
        [[ -z "$lstart" ]] && return 1

        local start_epoch
        start_epoch="$(date -j -f "%c" "$lstart" "+%s" 2>/dev/null)" || {
            # Fallback: try a more relaxed parse via ruby/python if date -j fails
            start_epoch="$(python3 -c "
import time, email.utils, subprocess, sys
from datetime import datetime
s = '''$lstart'''
try:
    t = datetime.strptime(s.strip(), '%c')
    print(int(t.timestamp()))
except Exception:
    # Try another common format from ps
    try:
        t = datetime.strptime(s.strip(), '%a %b %d %H:%M:%S %Y')
        print(int(t.timestamp()))
    except Exception:
        sys.exit(1)
" 2>/dev/null)" || return 1
        }
        local now_epoch
        now_epoch="$(date "+%s")"
        echo $(( now_epoch - start_epoch ))
    else
        # Linux: etimes = elapsed time in seconds
        local etimes
        etimes="$(ps -o etimes= -p "$pid" 2>/dev/null)" || return 1
        etimes="$(echo "$etimes" | xargs)"
        [[ -z "$etimes" ]] && return 1
        echo "$etimes"
    fi
}

# Returns RSS in MB (integer). Returns 1 if pid is gone.
get_rss_mb() {
    local pid="$1"
    local rss_kb
    rss_kb="$(ps -o rss= -p "$pid" 2>/dev/null)" || return 1
    rss_kb="$(echo "$rss_kb" | xargs)"
    [[ -z "$rss_kb" ]] && return 1
    echo $(( rss_kb / 1024 ))
}

# Kill a process: SIGTERM, wait 2s, SIGKILL if still alive.
kill_process() {
    local pid="$1"
    local reason="$2"

    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY RUN] Would kill PID $pid: $reason"
        return 0
    fi

    log "Killing PID $pid: $reason"

    kill -TERM "$pid" 2>/dev/null || {
        log "  PID $pid already gone before SIGTERM"
        return 0
    }

    sleep 2

    if kill -0 "$pid" 2>/dev/null; then
        log "  PID $pid still alive after SIGTERM, sending SIGKILL"
        kill -9 "$pid" 2>/dev/null || true
    else
        log "  PID $pid terminated with SIGTERM"
    fi
}

# macOS only: kill orphaned caffeinate processes (parent PID 1 or dead parent).
kill_orphan_caffeinate() {
    [[ "$OS" != "Darwin" ]] && return 0

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local pid ppid
        pid="$(echo "$line" | awk '{print $1}')"
        ppid="$(echo "$line" | awk '{print $2}')"

        if [[ "$ppid" == "1" ]] || ! kill -0 "$ppid" 2>/dev/null; then
            kill_process "$pid" "Orphaned caffeinate process (ppid=$ppid)"
        fi
    done < <(ps -eo pid,ppid,comm 2>/dev/null | grep '[c]affeinate' | awk '{print $1, $2}')
}

# Kill Claude processes burning CPU above threshold for longer than MIN_AGE_SECONDS.
kill_cpu_hogs() {
    # Get all processes, filter for claude|@anthropic
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        local pid cpu comm
        pid="$(echo "$line" | awk '{print $1}')"
        cpu="$(echo "$line" | awk '{print $2}')"
        comm="$(echo "$line" | awk '{$1=$2=""; print}' | xargs)"

        # Compare CPU (strip decimal for integer comparison)
        local cpu_int
        cpu_int="$(echo "$cpu" | cut -d. -f1)"
        [[ -z "$cpu_int" ]] && continue

        if (( cpu_int > CPU_THRESHOLD )); then
            local age
            age="$(get_process_age_seconds "$pid")" || continue

            if (( age > MIN_AGE_SECONDS )); then
                kill_process "$pid" "CPU hog: ${cpu}% CPU for ${age}s (threshold: ${CPU_THRESHOLD}%, min_age: ${MIN_AGE_SECONDS}s) [$comm]"
            fi
        fi
    done < <(ps -eo pid,%cpu,comm 2>/dev/null | grep -E 'claude|@anthropic' | grep -v grep)
}

# Kill Claude processes exceeding absolute memory threshold.
# No age check -- memory leaks can kill the machine fast.
kill_memory_hogs() {
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        local pid rss_kb comm
        pid="$(echo "$line" | awk '{print $1}')"
        rss_kb="$(echo "$line" | awk '{print $2}')"
        comm="$(echo "$line" | awk '{$1=$2=""; print}' | xargs)"

        [[ -z "$rss_kb" ]] && continue
        local rss_mb=$(( rss_kb / 1024 ))

        if (( rss_mb > MEM_THRESHOLD_MB )); then
            kill_process "$pid" "Memory hog: ${rss_mb}MB RSS (threshold: ${MEM_THRESHOLD_MB}MB) [$comm]"
        fi
    done < <(ps -eo pid,rss,comm 2>/dev/null | grep -E 'claude|@anthropic' | grep -v grep)
}

# Track RSS snapshots and kill processes with excessive memory growth.
kill_memory_growth() {
    local current_snapshot="$MEM_SNAPSHOT_DIR/current"
    local previous_snapshot="$MEM_SNAPSHOT_DIR/previous"

    # Build current snapshot: pid:rss_mb for all matching processes
    local tmp_snapshot
    tmp_snapshot="$(mktemp)"

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        local pid rss_kb
        pid="$(echo "$line" | awk '{print $1}')"
        rss_kb="$(echo "$line" | awk '{print $2}')"

        [[ -z "$rss_kb" ]] && continue
        local rss_mb=$(( rss_kb / 1024 ))
        echo "${pid}:${rss_mb}" >> "$tmp_snapshot"
    done < <(ps -eo pid,rss,comm 2>/dev/null | grep -E 'claude|@anthropic' | grep -v grep)

    # Compare with previous snapshot if it exists
    if [[ -f "$current_snapshot" ]]; then
        # Move current to previous
        mv "$current_snapshot" "$previous_snapshot"

        # Compare each pid in current tmp with previous
        while IFS=: read -r pid current_rss; do
            [[ -z "$pid" || -z "$current_rss" ]] && continue

            local prev_rss
            prev_rss="$(grep "^${pid}:" "$previous_snapshot" 2>/dev/null | cut -d: -f2)"
            [[ -z "$prev_rss" ]] && continue

            local growth=$(( current_rss - prev_rss ))
            if (( growth > MEM_GROWTH_LIMIT_MB )); then
                local comm
                comm="$(ps -o comm= -p "$pid" 2>/dev/null)" || comm="unknown"
                kill_process "$pid" "Memory growth: grew ${growth}MB since last check (${prev_rss}MB -> ${current_rss}MB, limit: ${MEM_GROWTH_LIMIT_MB}MB) [$comm]"
            fi
        done < "$tmp_snapshot"
    fi

    # Save current snapshot
    mv "$tmp_snapshot" "$current_snapshot"
}

# Kill orphaned/runaway bun workers spawned by Claude plugins.
# Bun workers don't have "claude" in the process name, so they slip past the
# main filter. Detect them via cwd containing /.claude/plugins/.
kill_plugin_bun_workers() {
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        local pid ppid cpu rss_kb
        pid="$(echo "$line" | awk '{print $1}')"
        ppid="$(echo "$line" | awk '{print $2}')"
        cpu="$(echo "$line" | awk '{print $3}')"
        rss_kb="$(echo "$line" | awk '{print $4}')"

        # Only consider bun processes whose cwd is under .claude/plugins
        local cwd=""
        if [[ "$OS" == "Darwin" ]]; then
            cwd="$(lsof -a -d cwd -p "$pid" -Fn 2>/dev/null | awk '/^n/ {print substr($0,2); exit}')"
        else
            cwd="$(readlink -f "/proc/$pid/cwd" 2>/dev/null)"
        fi
        [[ "$cwd" != *"/.claude/plugins/"* ]] && continue

        local rss_mb=$(( ${rss_kb:-0} / 1024 ))
        local cpu_int
        cpu_int="$(echo "${cpu:-0}" | cut -d. -f1)"
        [[ -z "$cpu_int" ]] && cpu_int=0

        # Memory leak: kill immediately, no age check
        if (( rss_mb > MEM_THRESHOLD_MB )); then
            kill_process "$pid" "Plugin bun worker memory hog: ${rss_mb}MB RSS [cwd: $cwd]"
            continue
        fi

        # CPU hog: kill if old enough
        if (( cpu_int > CPU_THRESHOLD )); then
            local age
            age="$(get_process_age_seconds "$pid")" || continue
            if (( age > MIN_AGE_SECONDS )); then
                kill_process "$pid" "Plugin bun worker CPU hog: ${cpu}% CPU for ${age}s [cwd: $cwd]"
                continue
            fi
        fi

        # Orphan (ppid=1) leftover from a dead Claude session
        if [[ "$ppid" == "1" ]]; then
            local age
            age="$(get_process_age_seconds "$pid")" || continue
            if (( age > MIN_AGE_SECONDS )); then
                kill_process "$pid" "Orphaned plugin bun worker: ppid=1, ${age}s old [cwd: $cwd]"
            fi
        fi
    done < <(ps -eo pid,ppid,%cpu,rss,comm 2>/dev/null | awk '$5 == "bun"')
}

# Kill orphaned Claude processes (parent=PID 1) with CPU > 10% and age > MIN_AGE_SECONDS.
kill_orphaned_children() {
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        local pid ppid cpu comm
        pid="$(echo "$line" | awk '{print $1}')"
        ppid="$(echo "$line" | awk '{print $2}')"
        cpu="$(echo "$line" | awk '{print $3}')"
        comm="$(echo "$line" | awk '{$1=$2=$3=""; print}' | xargs)"

        [[ "$ppid" != "1" ]] && continue

        local cpu_int
        cpu_int="$(echo "$cpu" | cut -d. -f1)"
        [[ -z "$cpu_int" ]] && continue

        if (( cpu_int > 10 )); then
            local age
            age="$(get_process_age_seconds "$pid")" || continue

            if (( age > MIN_AGE_SECONDS )); then
                kill_process "$pid" "Orphaned child: ppid=1, ${cpu}% CPU, ${age}s old [$comm]"
            fi
        fi
    done < <(ps -eo pid,ppid,%cpu,comm 2>/dev/null | grep -E 'claude|@anthropic' | grep -v grep)
}

# ---------- Main ----------

log "Watchdog v2 run started (cpu=${CPU_THRESHOLD}%, mem=${MEM_THRESHOLD_MB}MB, min_age=${MIN_AGE_SECONDS}s, dry_run=${DRY_RUN})"
kill_orphan_caffeinate
kill_memory_hogs
kill_memory_growth
kill_cpu_hogs
kill_orphaned_children
kill_plugin_bun_workers
log "Watchdog v2 run complete"
