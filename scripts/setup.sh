#!/bin/bash
# Claude Code Telegram Server - Quick Setup Script
# Installs all dependencies and configures the bot on macOS

set -e

echo "=== Claude Code Telegram Server Setup ==="
echo ""

# Check macOS
if [[ "$(uname)" != "Darwin" ]]; then
    echo "This script is for macOS only. See the README for Linux/Windows instructions."
    exit 1
fi

# Check if Homebrew is installed
if ! command -v brew &>/dev/null; then
    echo "[1/7] Installing Homebrew..."
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zshrc
    eval "$(/opt/homebrew/bin/brew shellenv)"
else
    echo "[1/7] Homebrew already installed"
fi

export PATH=/opt/homebrew/bin:$HOME/.bun/bin:$PATH

# Install Node.js
if ! command -v node &>/dev/null; then
    echo "[2/7] Installing Node.js..."
    brew install node
else
    echo "[2/7] Node.js already installed ($(node --version))"
fi

# Install Bun
if ! command -v bun &>/dev/null; then
    echo "[3/7] Installing Bun..."
    curl -fsSL https://bun.sh/install | bash
    export PATH=$HOME/.bun/bin:$PATH
else
    echo "[3/7] Bun already installed ($(bun --version))"
fi

# Install tmux
if ! command -v tmux &>/dev/null; then
    echo "[4/7] Installing tmux..."
    brew install tmux
else
    echo "[4/7] tmux already installed"
fi

# Install Claude Code
if ! command -v claude &>/dev/null; then
    echo "[5/7] Installing Claude Code..."
    npm install -g @anthropic-ai/claude-code
else
    echo "[5/7] Claude Code already installed ($(claude --version))"
fi

# Authenticate Claude Code
echo "[6/7] Authenticating Claude Code..."
echo "Run 'claude auth login --claudeai' and follow the OAuth flow."
echo ""

# Configure Telegram bot
echo "[7/7] Configuring Telegram bot..."
read -p "Enter your Telegram bot token from @BotFather: " BOT_TOKEN
if [[ -n "$BOT_TOKEN" ]]; then
    mkdir -p ~/.claude/channels/telegram
    echo "TELEGRAM_BOT_TOKEN=$BOT_TOKEN" > ~/.claude/channels/telegram/.env
    echo "Token saved."
else
    echo "Skipped. You can configure it later:"
    echo "  mkdir -p ~/.claude/channels/telegram"
    echo "  echo 'TELEGRAM_BOT_TOKEN=your-token' > ~/.claude/channels/telegram/.env"
fi

# Install Telegram plugin
echo ""
echo "Installing Telegram plugin..."
claude plugin marketplace add anthropics/claude-plugins-official 2>/dev/null || true
claude plugin install telegram@claude-plugins-official 2>/dev/null || true

# Disable sleep
echo ""
echo "Disabling sleep for 24/7 operation..."
sudo pmset -a sleep 0 displaysleep 0 disksleep 0 standby 0 \
    autopoweroff 0 hibernatemode 0 networkoversleep 0 \
    powernap 0 womp 1 tcpkeepalive 1 autorestart 1

# Install LaunchAgent
echo ""
echo "Installing LaunchAgent for auto-start on boot..."
cp scripts/com.claude.telegram.plist ~/Library/LaunchAgents/ 2>/dev/null || \
    cp com.claude.telegram.plist ~/Library/LaunchAgents/ 2>/dev/null || true
launchctl load ~/Library/LaunchAgents/com.claude.telegram.plist 2>/dev/null || true

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Next steps:"
echo "  1. Run: claude auth login --claudeai"
echo "  2. Launch: tmux new-session -d -s claude-telegram 'claude --channels plugin:telegram@claude-plugins-official --dangerously-skip-permissions'"
echo "  3. Message your bot in Telegram"
echo "  4. Pair: /telegram:access pair <code>"
echo "  5. Lock: /telegram:access policy allowlist"
echo ""
