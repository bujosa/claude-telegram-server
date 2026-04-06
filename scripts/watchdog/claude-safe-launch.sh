#!/bin/bash
# ==============================================================================
# Claude Code Safe Launcher
# Starts Claude Code with resource limits to prevent system freeze from
# CPU burn and memory leak bugs.
# Works on macOS and Linux.
# ==============================================================================

set -euo pipefail

# Ensure tools (tmux, claude, bun) are findable when invoked from non-interactive
# SSH or launchd contexts that don't source the user's shell rc.
export PATH="/opt/homebrew/bin:$HOME/.bun/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

# ---------- Config ----------
# Defaults: no nice, no RAM cap. These laptops exist to run Claude agents,
# so the agent should NOT be deprioritized. The watchdog handles runaways.
# Set MAX_RAM_KB or NICE_LEVEL via env to opt back in.
MAX_RAM_KB="${MAX_RAM_KB:-0}"                # 0 = unlimited
NICE_LEVEL="${NICE_LEVEL:-0}"                # 0 = normal priority
BOT_MODE="${BOT_MODE:-false}"                # Set to "true" for Telegram bot mode
TELEGRAM_PLUGIN="${TELEGRAM_PLUGIN:-plugin:telegram@claude-plugins-official}"
TMUX_SESSION="${TMUX_SESSION:-claude-telegram}"
RESTART_ON_CRASH="${RESTART_ON_CRASH:-true}"
RESTART_DELAY="${RESTART_DELAY:-10}"
MAX_RESTARTS="${MAX_RESTARTS:-5}"
RESTART_WINDOW="${RESTART_WINDOW:-300}"      # Reset restart counter after 5 min of stability

LOG_FILE=/tmp/claude-safe-launch.log

# Detect OS
OS="$(uname -s)"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# Build claude command
build_cmd() {
    local prefix=""
    if [[ "$MAX_RAM_KB" != "0" ]]; then
        prefix="ulimit -v $MAX_RAM_KB 2>/dev/null; "
    fi
    if [[ "$NICE_LEVEL" != "0" ]]; then
        prefix="${prefix}nice -n $NICE_LEVEL "
    fi
    local cmd="export PATH=/opt/homebrew/bin:\$HOME/.bun/bin:/usr/local/bin:\$PATH && ${prefix}"

    if [[ "$BOT_MODE" == "true" ]]; then
        cmd="${cmd}claude --channels $TELEGRAM_PLUGIN --dangerously-skip-permissions --permission-mode bypassPermissions"
    else
        cmd="${cmd}claude"
    fi
    echo "$cmd"
}

# Launch in tmux with auto-restart loop
launch_bot() {
    local cmd
    cmd=$(build_cmd)
    local wrapper="
restarts=0
last_start=\$(date +%s)
while true; do
    echo \"[\$(date)] Starting Claude Code (attempt \$((restarts+1)))...\"
    $cmd
    exit_code=\$?
    echo \"[\$(date)] Claude Code exited with code \$exit_code\"

    now=\$(date +%s)
    elapsed=\$((now - last_start))

    # Reset counter if it ran long enough
    if [ \$elapsed -gt $RESTART_WINDOW ]; then
        restarts=0
    fi

    restarts=\$((restarts + 1))

    if [ \"$RESTART_ON_CRASH\" != \"true\" ]; then
        echo \"Restart disabled, exiting.\"
        break
    fi

    if [ \$restarts -ge $MAX_RESTARTS ]; then
        echo \"Too many restarts (\$restarts in \${elapsed}s), giving up.\"
        break
    fi

    echo \"Restarting in ${RESTART_DELAY}s...\"
    sleep $RESTART_DELAY
    last_start=\$(date +%s)
done
"

    # Kill existing session
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
    sleep 1

    log "Launching Claude Code in tmux session '$TMUX_SESSION' (nice=$NICE_LEVEL, max_ram=${MAX_RAM_KB}KB, bot=$BOT_MODE)"
    tmux new-session -d -s "$TMUX_SESSION" "$wrapper"

    sleep 2
    if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        log "Session started successfully"
        tmux list-sessions
    else
        log "ERROR: Session failed to start"
        exit 1
    fi
}

# ---------- Main ----------
if [[ "$BOT_MODE" == "true" ]]; then
    launch_bot
else
    # Direct launch with limits
    cmd=$(build_cmd)
    log "Launching Claude Code directly (nice=$NICE_LEVEL, max_ram=${MAX_RAM_KB}KB)"
    eval "$cmd"
fi
