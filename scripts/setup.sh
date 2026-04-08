#!/bin/bash
# Claude Code Telegram Server - Quick Setup Script (v4)
# Installs all dependencies and configures the bot on macOS.
#
# v4 changes vs older setups:
#   - Verifies the plugin actually installed (instead of silencing errors)
#   - Suggests `claude setup-token` for headless OAuth (not `claude auth login`)
#   - Removes the `yes |` from the launch instructions — that was the cause
#     of a real-world incident where the bot leaked ~100 MB/s and froze the
#     machine. See docs/postmortem-2026-04-07.md for the full forensic story.
#   - Drops claude-safe-launch.sh and claude-watchdog.sh into place
#   - Replaces /Users/USERNAME placeholder in plists with the actual $HOME

set -e

echo "=== Claude Code Telegram Server Setup (v4) ==="
echo ""

# Check macOS
if [[ "$(uname)" != "Darwin" ]]; then
    echo "This script is for macOS only. See the README for Linux/Windows instructions."
    exit 1
fi

# Check if Homebrew is installed
if ! command -v brew &>/dev/null; then
    echo "[1/9] Installing Homebrew..."
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zshrc
    eval "$(/opt/homebrew/bin/brew shellenv)"
else
    echo "[1/9] Homebrew already installed"
fi

export PATH=/opt/homebrew/bin:$HOME/.bun/bin:$PATH

# Install Node.js
if ! command -v node &>/dev/null; then
    echo "[2/9] Installing Node.js..."
    brew install node
else
    echo "[2/9] Node.js already installed ($(node --version))"
fi

# Install Bun
if ! command -v bun &>/dev/null; then
    echo "[3/9] Installing Bun..."
    curl -fsSL https://bun.sh/install | bash
    export PATH=$HOME/.bun/bin:$PATH
else
    echo "[3/9] Bun already installed ($(bun --version))"
fi

# Install tmux
if ! command -v tmux &>/dev/null; then
    echo "[4/9] Installing tmux..."
    brew install tmux
else
    echo "[4/9] tmux already installed"
fi

# Install Claude Code
if ! command -v claude &>/dev/null; then
    echo "[5/9] Installing Claude Code..."
    npm install -g @anthropic-ai/claude-code
else
    echo "[5/9] Claude Code already installed ($(claude --version))"
fi

# Authenticate Claude Code
# Note: `claude auth login --claudeai` only works in a graphical session
# (it expects to open a browser locally). For headless setups (SSH-only,
# remote servers, etc.), use `claude setup-token` instead — it generates a
# long-lived OAuth token you save to ~/.claude-auth.env, sourced by
# safe-launch.sh on every claude launch.
echo "[6/9] Authenticate Claude Code"
if claude auth status 2>/dev/null | grep -q '"loggedIn": *true'; then
    echo "  ✓ already authenticated"
else
    echo "  ⚠ not authenticated. Pick ONE of these:"
    echo ""
    echo "  • If this machine has a browser:  claude auth login --claudeai"
    echo ""
    echo "  • Headless / SSH-only setup:      claude setup-token"
    echo "    Then save the printed token to ~/.claude-auth.env:"
    echo "    echo 'export CLAUDE_CODE_OAUTH_TOKEN=\"<token>\"' > ~/.claude-auth.env"
    echo "    chmod 600 ~/.claude-auth.env"
    echo ""
    echo "  Re-run this script after you authenticate."
fi
echo ""

# Configure Telegram bot
echo "[7/9] Configuring Telegram bot..."
if [[ -f ~/.claude/channels/telegram/.env ]] && grep -q "TELEGRAM_BOT_TOKEN=" ~/.claude/channels/telegram/.env; then
    echo "  ✓ token already configured at ~/.claude/channels/telegram/.env"
else
    read -p "  Enter your Telegram bot token from @BotFather: " BOT_TOKEN
    if [[ -n "$BOT_TOKEN" ]]; then
        mkdir -p ~/.claude/channels/telegram
        echo "TELEGRAM_BOT_TOKEN=$BOT_TOKEN" > ~/.claude/channels/telegram/.env
        chmod 600 ~/.claude/channels/telegram/.env
        echo "  Token saved (chmod 600)."
    else
        echo "  Skipped. Configure later:"
        echo "    mkdir -p ~/.claude/channels/telegram"
        echo "    echo 'TELEGRAM_BOT_TOKEN=your-token' > ~/.claude/channels/telegram/.env"
        echo "    chmod 600 ~/.claude/channels/telegram/.env"
    fi
fi
echo ""

# Install Telegram plugin — and ACTUALLY verify it. Earlier versions silenced
# errors with `2>/dev/null || true` which masked install failures and left
# users with a "plugin not installed" runtime error.
echo "[8/9] Installing Telegram plugin..."
claude plugin marketplace add anthropics/claude-plugins-official 2>&1 | grep -v "already" || true
if claude plugin install telegram@claude-plugins-official 2>&1 | tee /tmp/claude-plugin-install.log; then
    if claude plugin list 2>&1 | grep -q "telegram@claude-plugins-official"; then
        echo "  ✓ telegram@claude-plugins-official installed and visible to claude plugin list"
    else
        echo "  ⚠ install command succeeded but plugin not visible to 'claude plugin list'"
        echo "    Check: ~/.claude/plugins/marketplaces/claude-plugins-official/external_plugins/telegram"
        exit 1
    fi
else
    echo "  ✗ plugin install failed. See /tmp/claude-plugin-install.log"
    exit 1
fi
echo ""

# Disable sleep
echo "[9/9] Disabling sleep for 24/7 operation..."
sudo pmset -a sleep 0 displaysleep 0 disksleep 0 standby 0 \
    autopoweroff 0 hibernatemode 0 networkoversleep 0 \
    powernap 0 womp 1 tcpkeepalive 1 autorestart 1
echo ""

# Drop the launcher and watchdog scripts
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
echo "Installing claude-safe-launch.sh + claude-watchdog.sh..."
cp "$SCRIPT_DIR/watchdog/claude-safe-launch.sh" "$HOME/claude-safe-launch.sh"
chmod +x "$HOME/claude-safe-launch.sh"
sudo cp "$SCRIPT_DIR/watchdog/claude-watchdog.sh" /usr/local/bin/claude-watchdog.sh
sudo chmod +x /usr/local/bin/claude-watchdog.sh
echo "  ✓ ~/claude-safe-launch.sh"
echo "  ✓ /usr/local/bin/claude-watchdog.sh"
echo ""

# Install LaunchAgents — substitute USERNAME placeholder in the plists
echo "Installing LaunchAgents (with $USER substituted in)..."
mkdir -p ~/Library/LaunchAgents
sed "s|/Users/USERNAME|$HOME|g" "$SCRIPT_DIR/com.claude.telegram.plist" \
    > ~/Library/LaunchAgents/com.claude.telegram.plist
cp "$SCRIPT_DIR/watchdog/com.claude.watchdog.plist" ~/Library/LaunchAgents/
launchctl unload ~/Library/LaunchAgents/com.claude.telegram.plist 2>/dev/null || true
launchctl unload ~/Library/LaunchAgents/com.claude.watchdog.plist 2>/dev/null || true
launchctl load ~/Library/LaunchAgents/com.claude.watchdog.plist
launchctl load ~/Library/LaunchAgents/com.claude.telegram.plist
echo "  ✓ both LaunchAgents loaded"
echo ""

echo "=== Setup Complete ==="
echo ""
echo "Next steps:"
echo "  1. If you haven't yet, authenticate: claude setup-token (headless) OR claude auth login --claudeai (GUI)"
echo "  2. Wait ~30s for the bot to start, then message it from Telegram"
echo "  3. The bot replies with a 6-char pairing code"
echo "  4. From a claude session: /telegram:access pair <code>"
echo "  5. Lock down: /telegram:access policy allowlist"
echo ""
echo "IMPORTANT: do NOT use 'yes | claude --channels' anywhere — that triggers"
echo "the ArrayBuffer leak in claude-code via --print mode fallback. The new"
echo "safe-launch.sh runs claude in a real tmux pty without piped stdin."
echo "See docs/postmortem-2026-04-07.md for the forensic story."
echo ""
