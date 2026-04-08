#!/bin/bash
# ==============================================================================
# Claude Code Safe Launcher v4 — actually works on macOS, no theater
#
# Key insight from real-world testing on a frozen Mac (April 2026):
# the v2/v3 `yes |` recommendation in the README causes claude to fall back
# to --print mode (because piped stdin = no TTY), which then processes the
# infinite "y\n" stream as a prompt and triggers the ArrayBuffer leak from
# anthropics/claude-code#32729. Memory grows ~100 MB/s and freezes the box.
#
# The fix: launch claude inside a *real* tmux pty (no pipes at all), and
# dismiss the boot-time prompts via `tmux send-keys` from a background helper.
#
# Other v4 changes:
#   - Sources ~/.claude-auth.env if present (CLAUDE_CODE_OAUTH_TOKEN from
#     `claude setup-token`, headless-friendly subscription auth)
#   - Removed fake `ulimit -v` (no-op on macOS)
#   - Real V8 cap via NODE_OPTIONS=--max-old-space-size
#   - Optional `taskpolicy -b -c utility` for jetsam targeting
#   - Circuit breaker: refuses to launch if /tmp/claude-bot.disabled exists
#   - In-loop circuit breaker check
#   - Auto-trips circuit breaker after MAX_RESTARTS bursts
#   - Background prompt dismisser per claude launch (handles trust + bypass)
# ==============================================================================

set -euo pipefail

export PATH="/opt/homebrew/bin:$HOME/.bun/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

# ---------- Config ----------
NODE_HEAP_MB="${NODE_HEAP_MB:-2048}"
USE_TASKPOLICY="${USE_TASKPOLICY:-false}"
BOT_MODE="${BOT_MODE:-false}"
TELEGRAM_PLUGIN="${TELEGRAM_PLUGIN:-plugin:telegram@claude-plugins-official}"
TMUX_SESSION="${TMUX_SESSION:-claude-telegram}"
RESTART_ON_CRASH="${RESTART_ON_CRASH:-true}"
RESTART_DELAY="${RESTART_DELAY:-10}"
MAX_RESTARTS="${MAX_RESTARTS:-5}"
RESTART_WINDOW="${RESTART_WINDOW:-300}"
DISABLE_FLAG="${DISABLE_FLAG:-/tmp/claude-bot.disabled}"
AUTH_ENV_FILE="${AUTH_ENV_FILE:-$HOME/.claude-auth.env}"

# Trust prompt + bypass warning dismissal timing.
# Claude shows two boot-time prompts that --dangerously-skip-permissions
# does NOT skip. We dismiss them by sending keys to the tmux session.
TRUST_PROMPT_DELAY="${TRUST_PROMPT_DELAY:-6}"     # seconds before sending Enter to trust folder
BYPASS_PROMPT_DELAY="${BYPASS_PROMPT_DELAY:-4}"   # seconds after trust before Down + Enter

LOG_FILE=/tmp/claude-safe-launch.log

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# ---------- Circuit breaker (boot-time) ----------
if [[ -f "$DISABLE_FLAG" ]]; then
    log "CIRCUIT BREAKER TRIPPED: $DISABLE_FLAG exists, refusing to launch"
    log "  Investigate /tmp/claude-watchdog.log or /tmp/claude-safe-launch.log"
    log "  Clear with: rm $DISABLE_FLAG"
    exit 0
fi

# ---------- Build the claude command (NO yes pipe!) ----------
build_cmd() {
    local task_prefix=""
    if [[ "$USE_TASKPOLICY" == "true" ]]; then
        task_prefix="taskpolicy -b -c utility "
    fi

    # Source the OAuth env file inside the wrapper so claude sees the token.
    # PATH + NODE_OPTIONS also exported here (defense in depth, in case the
    # tmux pane shell is non-login).
    local prelude="export PATH=/opt/homebrew/bin:\$HOME/.bun/bin:/usr/local/bin:\$PATH && export NODE_OPTIONS=\"--max-old-space-size=${NODE_HEAP_MB}\""
    if [[ -f "$AUTH_ENV_FILE" ]]; then
        prelude="${prelude} && [ -f \"$AUTH_ENV_FILE\" ] && source \"$AUTH_ENV_FILE\""
    fi

    if [[ "$BOT_MODE" == "true" ]]; then
        # CRITICAL: no `yes |` here. Piping stdin makes claude fall back to
        # --print mode which triggers the ArrayBuffer leak (#32729).
        # Real TTY only — tmux provides the pty.
        echo "${prelude} && ${task_prefix}claude --channels $TELEGRAM_PLUGIN --dangerously-skip-permissions --permission-mode bypassPermissions"
    else
        echo "${prelude} && ${task_prefix}claude"
    fi
}

# ---------- Launch in tmux with auto-restart loop ----------
launch_bot() {
    local cmd
    cmd=$(build_cmd)

    # Wrapper inside tmux: re-runs claude on crash, dismisses prompts on each
    # launch via a background helper, gives up after MAX_RESTARTS bursts
    # (and trips the circuit breaker so launchd won't keep relaunching).
    local wrapper="
restarts=0
last_start=\$(date +%s)
while true; do
    if [ -f \"$DISABLE_FLAG\" ]; then
        echo \"[\$(date)] Circuit breaker tripped mid-loop, exiting wrapper\"
        break
    fi
    echo \"[\$(date)] Starting Claude Code (attempt \$((restarts+1)))...\"

    # Background dismisser: sends Enter (trust prompt) then Down+Enter
    # (bypass mode warning) so claude proceeds past the boot-time prompts.
    # Spawned per launch so restarts also get dismissed automatically.
    (
        sleep $TRUST_PROMPT_DELAY
        tmux send-keys -t '$TMUX_SESSION' Enter 2>/dev/null || true
        sleep $BYPASS_PROMPT_DELAY
        tmux send-keys -t '$TMUX_SESSION' Down 2>/dev/null || true
        sleep 1
        tmux send-keys -t '$TMUX_SESSION' Enter 2>/dev/null || true
    ) &
    DISMISSER_PID=\$!

    $cmd
    exit_code=\$?
    echo \"[\$(date)] Claude Code exited with code \$exit_code\"

    # Clean up dismisser if still in its sleep
    kill \$DISMISSER_PID 2>/dev/null || true

    now=\$(date +%s)
    elapsed=\$((now - last_start))

    if [ \$elapsed -gt $RESTART_WINDOW ]; then
        restarts=0
    fi

    restarts=\$((restarts + 1))

    if [ \"$RESTART_ON_CRASH\" != \"true\" ]; then
        echo \"Restart disabled, exiting.\"
        break
    fi

    if [ \$restarts -ge $MAX_RESTARTS ]; then
        echo \"Too many restarts (\$restarts in \${elapsed}s), tripping circuit breaker.\"
        touch \"$DISABLE_FLAG\"
        break
    fi

    echo \"Restarting in ${RESTART_DELAY}s...\"
    sleep $RESTART_DELAY
    last_start=\$(date +%s)
done
"

    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
    sleep 1

    log "Launching Claude (bot=$BOT_MODE, NODE_HEAP_MB=$NODE_HEAP_MB, taskpolicy=$USE_TASKPOLICY, auth_env=$([[ -f $AUTH_ENV_FILE ]] && echo yes || echo no))"
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
    cmd=$(build_cmd)
    log "Launching Claude Code directly (NODE_HEAP_MB=$NODE_HEAP_MB)"
    eval "$cmd"
fi
