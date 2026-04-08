#!/bin/bash
# ==============================================================================
# Claude Code Watchdog v4 — faster, harder, with circuit breaker + stale-TCP
#
# Changes from v3:
#   - NEW: kill_stale_bot() detects the "alive but stuck" failure mode where
#     bun's long-poll TCP socket to api.telegram.org goes dead (typically
#     after Wi-Fi blip + macOS 2-hour TCP keepalive default). Symptoms:
#     bun process alive, claude alive, no crashes, no kills — but bot doesn't
#     respond to Telegram messages because the recv() is blocked on a dead
#     socket. Detection: snapshot bun's bytes_in/out via nettop, if zero
#     growth for >NETWORK_STALE_SECONDS, kill claude (wrapper auto-restarts
#     with fresh sockets). Real-world incident this fixes: bot ran 17h then
#     went silent overnight, processes alive, lsof showed no ESTABLISHED
#     TCP — classic stale-socket signature.
#
# Changes from v2:
#   - Default MEM_THRESHOLD_MB lowered 3072 → 1800 (catches leak earlier)
#   - Default MEM_GROWTH_LIMIT_MB lowered 500 → 200 (catches leak faster)
#   - kill_process: SIGKILL immediately (telegram plugin ignores SIGTERM, #40706)
#   - Added crash-loop circuit breaker: after KILL_THRESHOLD kills in
#     KILL_WINDOW seconds, trip /tmp/claude-bot.disabled and unload the
#     telegram LaunchAgent so it stops flapping.
#   - Designed to run from a launchd plist with StartInterval=10 (the macOS
#     minimum). At 10s checks the leak still has a chance to OOM but reaction
#     time is 6x better than v2.
#
# Related: https://github.com/anthropics/claude-code/issues/22275
#          https://github.com/anthropics/claude-code/issues/32729
#          https://github.com/anthropics/claude-code/issues/40706
# ==============================================================================

set -uo pipefail

# ---------- Config (all overridable via env vars) ----------
CPU_THRESHOLD="${CPU_THRESHOLD:-80}"
MEM_THRESHOLD_MB="${MEM_THRESHOLD_MB:-1800}"
MIN_AGE_SECONDS="${MIN_AGE_SECONDS:-60}"
LOG_FILE="${LOG_FILE:-/tmp/claude-watchdog.log}"
DRY_RUN="${DRY_RUN:-false}"
MEM_SNAPSHOT_DIR="${MEM_SNAPSHOT_DIR:-/tmp/claude-watchdog-snapshots}"
MEM_GROWTH_LIMIT_MB="${MEM_GROWTH_LIMIT_MB:-200}"

# Circuit breaker: after KILL_THRESHOLD kills within KILL_WINDOW seconds,
# trip the disable flag and unload the telegram LaunchAgent. Prevents an
# infinite kill/restart loop from chewing through the machine.
KILL_LOG="${KILL_LOG:-/tmp/claude-watchdog-kills.log}"
DISABLE_FLAG="${DISABLE_FLAG:-/tmp/claude-bot.disabled}"
KILL_THRESHOLD="${KILL_THRESHOLD:-3}"
KILL_WINDOW="${KILL_WINDOW:-600}"
TELEGRAM_PLIST="${TELEGRAM_PLIST:-$HOME/Library/LaunchAgents/com.claude.telegram.plist}"

# Stale-TCP detection: bun's long-poll cycle hits api.telegram.org every ~30s
# even when idle (timeout=25 + getUpdates response). If bytes_in/out frozen
# for this many seconds, the socket is dead and we kill claude.
NETWORK_STALE_SECONDS="${NETWORK_STALE_SECONDS:-180}"
NETWORK_SNAPSHOT="${NETWORK_SNAPSHOT:-$MEM_SNAPSHOT_DIR/bun-network}"

OS="$(uname -s)"

mkdir -p "$MEM_SNAPSHOT_DIR"

# ---------- Functions ----------

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# Returns process age in seconds. Returns 1 if pid is gone.
get_process_age_seconds() {
    local pid="$1"

    if [[ "$OS" == "Darwin" ]]; then
        local lstart
        lstart="$(ps -o lstart= -p "$pid" 2>/dev/null)" || return 1
        lstart="$(echo "$lstart" | xargs)"
        [[ -z "$lstart" ]] && return 1

        local start_epoch
        start_epoch="$(date -j -f "%c" "$lstart" "+%s" 2>/dev/null)" || {
            start_epoch="$(python3 -c "
import time, sys
from datetime import datetime
s = '''$lstart'''
try:
    t = datetime.strptime(s.strip(), '%c')
    print(int(t.timestamp()))
except Exception:
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
        local etimes
        etimes="$(ps -o etimes= -p "$pid" 2>/dev/null)" || return 1
        etimes="$(echo "$etimes" | xargs)"
        [[ -z "$etimes" ]] && return 1
        echo "$etimes"
    fi
}

# Returns RSS in MB. Returns 1 if pid is gone.
get_rss_mb() {
    local pid="$1"
    local rss_kb
    rss_kb="$(ps -o rss= -p "$pid" 2>/dev/null)" || return 1
    rss_kb="$(echo "$rss_kb" | xargs)"
    [[ -z "$rss_kb" ]] && return 1
    echo $(( rss_kb / 1024 ))
}

# Track kills for the circuit breaker. Trips the disable flag and unloads
# the telegram LaunchAgent if too many kills happen in too short a window.
record_kill() {
    [[ "$DRY_RUN" == "true" ]] && return 0

    local now
    now="$(date +%s)"
    echo "$now" >> "$KILL_LOG"

    # Count kills in the last KILL_WINDOW seconds
    local cutoff=$(( now - KILL_WINDOW ))
    local recent
    recent="$(awk -v cutoff="$cutoff" '$1 >= cutoff' "$KILL_LOG" 2>/dev/null | wc -l | tr -d ' ')"
    log "  kill count in last ${KILL_WINDOW}s: $recent / $KILL_THRESHOLD"

    if (( recent >= KILL_THRESHOLD )); then
        log "  CIRCUIT BREAKER TRIPPED: $recent kills in ${KILL_WINDOW}s"
        log "  Creating $DISABLE_FLAG and unloading telegram LaunchAgent"
        touch "$DISABLE_FLAG"
        if [[ -f "$TELEGRAM_PLIST" ]]; then
            launchctl unload "$TELEGRAM_PLIST" 2>/dev/null || true
        fi
        # Also kill any tmux session so the wrapper inside doesn't restart
        if command -v tmux >/dev/null 2>&1; then
            tmux kill-session -t claude-telegram 2>/dev/null || true
        fi
    fi
}

# SIGKILL immediately. Telegram plugin ignores SIGTERM (#40706), so the
# graceful path is wasted time during which the leak keeps growing.
kill_process() {
    local pid="$1"
    local reason="$2"

    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY RUN] Would kill PID $pid: $reason"
        return 0
    fi

    log "Killing PID $pid (-9): $reason"
    kill -9 "$pid" 2>/dev/null || {
        log "  PID $pid already gone"
        return 0
    }

    record_kill
}

# macOS only: kill orphaned caffeinate processes
kill_orphan_caffeinate() {
    [[ "$OS" != "Darwin" ]] && return 0

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local pid ppid
        pid="$(echo "$line" | awk '{print $1}')"
        ppid="$(echo "$line" | awk '{print $2}')"

        if [[ "$ppid" == "1" ]] || ! kill -0 "$ppid" 2>/dev/null; then
            kill_process "$pid" "Orphaned caffeinate (ppid=$ppid)"
        fi
    done < <(ps -eo pid,ppid,comm 2>/dev/null | grep '[c]affeinate' | awk '{print $1, $2}')
}

# Kill claude processes burning >CPU_THRESHOLD% for >MIN_AGE_SECONDS, no TTY
kill_cpu_hogs() {
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        local pid cpu comm
        pid="$(echo "$line" | awk '{print $1}')"
        cpu="$(echo "$line" | awk '{print $2}')"
        comm="$(echo "$line" | awk '{$1=$2=""; print}' | xargs)"

        local cpu_int
        cpu_int="$(echo "$cpu" | cut -d. -f1)"
        [[ -z "$cpu_int" ]] && continue

        if (( cpu_int > CPU_THRESHOLD )); then
            local age
            age="$(get_process_age_seconds "$pid")" || continue

            if (( age > MIN_AGE_SECONDS )); then
                kill_process "$pid" "CPU hog: ${cpu}% for ${age}s [$comm]"
            fi
        fi
    done < <(ps -eo pid,%cpu,comm 2>/dev/null | grep -E 'claude|@anthropic' | grep -v grep)
}

# Kill claude processes exceeding absolute memory threshold (no age check)
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
            kill_process "$pid" "Memory hog: ${rss_mb}MB RSS [$comm]"
        fi
    done < <(ps -eo pid,rss,comm 2>/dev/null | grep -E 'claude|@anthropic' | grep -v grep)
}

# Track RSS snapshots and kill processes with excessive memory growth
kill_memory_growth() {
    local current_snapshot="$MEM_SNAPSHOT_DIR/current"
    local previous_snapshot="$MEM_SNAPSHOT_DIR/previous"
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

    if [[ -f "$current_snapshot" ]]; then
        mv "$current_snapshot" "$previous_snapshot"

        while IFS=: read -r pid current_rss; do
            [[ -z "$pid" || -z "$current_rss" ]] && continue
            local prev_rss
            prev_rss="$(grep "^${pid}:" "$previous_snapshot" 2>/dev/null | cut -d: -f2)"
            [[ -z "$prev_rss" ]] && continue

            local growth=$(( current_rss - prev_rss ))
            if (( growth > MEM_GROWTH_LIMIT_MB )); then
                local comm
                comm="$(ps -o comm= -p "$pid" 2>/dev/null)" || comm="unknown"
                kill_process "$pid" "Memory growth: +${growth}MB (${prev_rss}→${current_rss}MB) [$comm]"
            fi
        done < "$tmp_snapshot"
    fi

    mv "$tmp_snapshot" "$current_snapshot"
}

# Kill orphaned/runaway bun workers spawned by Claude plugins
kill_plugin_bun_workers() {
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        local pid ppid cpu rss_kb
        pid="$(echo "$line" | awk '{print $1}')"
        ppid="$(echo "$line" | awk '{print $2}')"
        cpu="$(echo "$line" | awk '{print $3}')"
        rss_kb="$(echo "$line" | awk '{print $4}')"

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

        if (( rss_mb > MEM_THRESHOLD_MB )); then
            kill_process "$pid" "Plugin bun worker mem hog: ${rss_mb}MB [cwd: $cwd]"
            continue
        fi

        if (( cpu_int > CPU_THRESHOLD )); then
            local age
            age="$(get_process_age_seconds "$pid")" || continue
            if (( age > MIN_AGE_SECONDS )); then
                kill_process "$pid" "Plugin bun worker CPU hog: ${cpu}% for ${age}s [cwd: $cwd]"
                continue
            fi
        fi

        if [[ "$ppid" == "1" ]]; then
            local age
            age="$(get_process_age_seconds "$pid")" || continue
            if (( age > MIN_AGE_SECONDS )); then
                kill_process "$pid" "Orphaned plugin bun worker: ppid=1, ${age}s old [cwd: $cwd]"
            fi
        fi
    done < <(ps -eo pid,ppid,%cpu,rss,comm 2>/dev/null | awk '$5 == "bun"')
}

# Kill orphaned claude processes (parent=PID 1) with CPU > 10%
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

# Detect "alive but stuck" bot — bun process up but its long-poll TCP socket
# to api.telegram.org has gone dead (Wi-Fi blip + 2-hour macOS keepalive default).
# We snapshot bun's bytes_in/out via nettop. If they don't move between two
# consecutive observations spaced >NETWORK_STALE_SECONDS apart, the socket is
# dead — kill claude so the wrapper can spawn fresh.
#
# Why nettop and not lsof: lsof on macOS doesn't show ESTABLISHED TCP for
# user processes without elevated privileges in many configurations. nettop
# does and reports cumulative byte counters per pid.
kill_stale_bot() {
    [[ "$OS" != "Darwin" ]] && return 0

    local bun_pid claude_pid
    # The actual server is `bun server.ts`, child of `bun run --cwd ... start`.
    # Match the inner one — it's the one holding the long-poll connection.
    bun_pid="$(pgrep -f 'bun server\.ts' 2>/dev/null | head -1)"
    claude_pid="$(pgrep -x claude 2>/dev/null | head -1)"

    if [[ -z "$bun_pid" || -z "$claude_pid" ]]; then
        return 0
    fi

    # bun must be old enough to have started its long-poll cycle
    local bun_age
    bun_age="$(get_process_age_seconds "$bun_pid")" || return 0
    if (( bun_age < NETWORK_STALE_SECONDS )); then
        return 0
    fi

    # Snapshot current network counters via nettop. Format is CSV with
    # bytes_in in column 5 and bytes_out in column 6 for the bun.PID row.
    # nettop -L 1 takes a single sample and exits.
    local nettop_out
    nettop_out="$(nettop -P -L 1 -t external 2>/dev/null | awk -F, -v want="bun.${bun_pid}" '$2 == want {print; exit}')"
    if [[ -z "$nettop_out" ]]; then
        # nettop didn't see this bun (maybe it has zero traffic) — record nothing
        return 0
    fi
    local current_in current_out
    current_in="$(echo "$nettop_out" | awk -F, '{print $5}')"
    current_out="$(echo "$nettop_out" | awk -F, '{print $6}')"

    if [[ -z "$current_in" || -z "$current_out" ]]; then
        return 0
    fi

    local now
    now="$(date +%s)"

    # Read previous snapshot: pid:in:out:last_change_ts
    local prev_pid="" prev_in="" prev_out="" prev_ts=""
    if [[ -f "$NETWORK_SNAPSHOT" ]]; then
        IFS=: read -r prev_pid prev_in prev_out prev_ts < "$NETWORK_SNAPSHOT"
    fi

    if [[ "$prev_pid" == "$bun_pid" && -n "$prev_in" ]]; then
        # Same bun process — compare counters
        if [[ "$current_in" == "$prev_in" && "$current_out" == "$prev_out" ]]; then
            # Frozen. How long?
            local stale_for=$(( now - prev_ts ))
            if (( stale_for >= NETWORK_STALE_SECONDS )); then
                kill_process "$claude_pid" "STALE TCP: bun pid=$bun_pid no traffic for ${stale_for}s (in=$current_in out=$current_out — likely dead long-poll socket)"
                rm -f "$NETWORK_SNAPSHOT"
                return 0
            fi
            # Frozen but not long enough yet — keep the old snapshot
        else
            # Counters moved — refresh snapshot with new last-change timestamp
            echo "${bun_pid}:${current_in}:${current_out}:${now}" > "$NETWORK_SNAPSHOT"
        fi
    else
        # New bun (different PID) or no prior snapshot — record baseline
        echo "${bun_pid}:${current_in}:${current_out}:${now}" > "$NETWORK_SNAPSHOT"
    fi
}

# ---------- Main ----------

log "Watchdog v4 run started (cpu=${CPU_THRESHOLD}%, mem=${MEM_THRESHOLD_MB}MB, growth=${MEM_GROWTH_LIMIT_MB}MB, age=${MIN_AGE_SECONDS}s, net_stale=${NETWORK_STALE_SECONDS}s, dry_run=${DRY_RUN})"

# If circuit breaker already tripped, just log and exit. We don't want the
# watchdog itself to keep doing work when the bot is intentionally stopped.
if [[ -f "$DISABLE_FLAG" ]]; then
    log "Circuit breaker is set ($DISABLE_FLAG). Watchdog still running but bot is intentionally disabled."
fi

kill_orphan_caffeinate
kill_memory_hogs
kill_memory_growth
kill_cpu_hogs
kill_orphaned_children
kill_plugin_bun_workers
kill_stale_bot
log "Watchdog v4 run complete"
