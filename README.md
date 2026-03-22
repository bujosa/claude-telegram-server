# Claude Code Telegram Server

Turn any computer into a 24/7 Claude Code assistant you can talk to from Telegram. Send a message from your phone — Claude reads your files, writes code, runs commands, and replies right back.

## How It Works

```
┌──────────────┐         ┌─────────────────────────┐         ┌──────────────┐
│              │         │    Your Server (any OS)  │         │              │
│   Telegram   │────────▶│  tmux / screen session   │────────▶│  Your Code   │
│   on phone   │◀────────│  Claude Code + Plugin    │◀────────│  & Terminal  │
│              │         │                          │         │              │
└──────────────┘         └─────────────────────────┘         └──────────────┘
```

1. You message your Telegram bot from anywhere
2. The official Telegram plugin pushes the message into Claude Code
3. Claude reads files, edits code, runs tests, makes commits — whatever you ask
4. Claude replies directly in your Telegram chat

It's like having your IDE in your pocket.

## Requirements

| Requirement | Details |
|-------------|---------|
| **Claude Code** | v2.1.80+ ([install guide](https://docs.anthropic.com/en/docs/claude-code)) |
| **Claude subscription** | Pro, Max, Team, or Enterprise (OAuth login) |
| **Node.js** | v18+ |
| **Bun** | Required for channel plugins |
| **tmux or screen** | To keep the session alive after disconnecting |
| **Telegram account** | To create a bot via BotFather |

## Quick Start

### Step 1 — Install Claude Code

```bash
npm install -g @anthropic-ai/claude-code
```

Authenticate with your Claude subscription:

```bash
claude auth login --claudeai
```

This gives you a URL to open in your browser. Sign in and paste the code back.

### Step 2 — Install Bun

Claude Code plugins run on Bun.

**macOS / Linux:**

```bash
curl -fsSL https://bun.sh/install | bash
```

**Windows (PowerShell):**

```powershell
irm bun.sh/install.ps1 | iex
```

### Step 3 — Create a Telegram Bot

1. Open [@BotFather](https://t.me/BotFather) in Telegram
2. Send `/newbot`
3. Pick a name and a username (must end in `bot`)
4. Copy the **token** BotFather gives you

### Step 4 — Install the Telegram Plugin

```bash
# Add the official plugin marketplace
claude plugin marketplace add anthropics/claude-plugins-official

# Install the plugin
claude plugin install telegram@claude-plugins-official
```

### Step 5 — Configure Your Bot Token

```bash
mkdir -p ~/.claude/channels/telegram
echo 'TELEGRAM_BOT_TOKEN=<your-token-here>' > ~/.claude/channels/telegram/.env
```

Replace `<your-token-here>` with the token from BotFather.

### Step 6 — Launch Claude Code with Telegram

```bash
claude --channels plugin:telegram@claude-plugins-official
```

You should see:

```
Listening for channel messages from: plugin:telegram@claude-plugins-official
```

### Step 7 — Pair Your Telegram Account

1. Send any message to your bot in Telegram
2. The bot replies with a **pairing code**
3. In Claude Code, type:

```
/telegram:access pair <code>
```

### Step 8 — Lock It Down

Set the access policy to **allowlist** so only you can use the bot:

```
/telegram:access policy allowlist
```

Anyone else who messages the bot will be silently ignored.

### That's It

Message your bot from Telegram. Claude Code responds.

## Running 24/7

The bot only works while Claude Code is running. To keep it alive permanently, use a terminal multiplexer.

### With tmux

```bash
# Start a detached session
tmux new-session -d -s claude-telegram \
  'claude --channels plugin:telegram@claude-plugins-official'

# Verify it's running
tmux list-sessions

# Attach to see output
tmux attach -t claude-telegram

# Detach without stopping: Ctrl+B, then D
```

### With screen

```bash
screen -dmS claude-telegram \
  claude --channels plugin:telegram@claude-plugins-official

# Reattach
screen -r claude-telegram

# Detach: Ctrl+A, then D
```

### With systemd (Linux)

Create `/etc/systemd/system/claude-telegram.service`:

```ini
[Unit]
Description=Claude Code Telegram Bot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=your-username
Environment=PATH=/usr/local/bin:/usr/bin:/bin:/home/your-username/.bun/bin
ExecStart=/usr/local/bin/claude --channels plugin:telegram@claude-plugins-official
Restart=on-failure
RestartSec=10
WorkingDirectory=/home/your-username

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now claude-telegram
```

## Platform Guides

<details>
<summary><strong>🐧 Linux (Ubuntu / Debian)</strong></summary>

### Install dependencies

```bash
# Node.js
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt install -y nodejs

# Bun
curl -fsSL https://bun.sh/install | bash

# tmux
sudo apt install -y tmux

# Claude Code
npm install -g @anthropic-ai/claude-code
```

### Enable SSH

```bash
sudo apt install -y openssh-server
sudo systemctl enable --now ssh
```

### Set static IP (Netplan)

Edit `/etc/netplan/01-config.yaml`:

```yaml
network:
  version: 2
  ethernets:
    eth0:
      addresses: [10.0.0.19/24]
      routes:
        - to: default
          via: 10.0.0.1
      nameservers:
        addresses: [8.8.8.8, 8.8.4.4]
```

```bash
sudo netplan apply
```

### Disable sleep

```bash
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
```

</details>

<details>
<summary><strong>🪟 Windows</strong></summary>

### Install dependencies

```powershell
# Node.js
winget install OpenJS.NodeJS

# Bun
irm bun.sh/install.ps1 | iex

# Claude Code
npm install -g @anthropic-ai/claude-code
```

### Keep it running

For always-on operation, use one of these methods:

**Task Scheduler:** Create a task that runs at login:

```
claude --channels plugin:telegram@claude-plugins-official
```

**NSSM (service wrapper):**

```powershell
nssm install ClaudeTelegram "C:\Program Files\nodejs\claude.cmd" "--channels plugin:telegram@claude-plugins-official"
nssm start ClaudeTelegram
```

### Set static IP

Settings > Network & Internet > Wi-Fi/Ethernet > Edit IP > Manual

Or via PowerShell:

```powershell
New-NetIPAddress -InterfaceAlias "Wi-Fi" -IPAddress 10.0.0.19 -PrefixLength 24 -DefaultGateway 10.0.0.1
Set-DnsClientServerAddress -InterfaceAlias "Wi-Fi" -ServerAddresses 8.8.8.8,8.8.4.4
```

### Disable sleep

```powershell
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
powercfg /change monitor-timeout-ac 0
```

</details>

<details>
<summary><strong>🍎 macOS</strong></summary>

### Install dependencies

```bash
# Homebrew
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
echo 'eval $(/opt/homebrew/bin/brew shellenv)' >> ~/.zshrc

# Node.js & tmux
brew install node tmux

# Bun
curl -fsSL https://bun.sh/install | bash

# Claude Code
npm install -g @anthropic-ai/claude-code
```

### Set static IP

```bash
sudo networksetup -setmanual Wi-Fi 10.0.0.19 255.255.255.0 10.0.0.1
sudo networksetup -setdnsservers Wi-Fi 8.8.8.8 8.8.4.4
```

> **Important:** On macOS, CLI-configured static IPs may not persist across reboots. For reliability, set it via **System Settings > Network > Wi-Fi > Details > TCP/IP > Manually**.

### Disable sleep

```bash
sudo pmset -a sleep 0 displaysleep 0 disksleep 0 \
  standby 0 autopoweroff 0 hibernatemode 0 networkoversleep 0
```

### Enable SSH

```bash
sudo systemsetup -setremotelogin on
```

### Headless MacBook?

If you're repurposing a MacBook as a dedicated server, check out the full walkthrough:

**[→ Headless MacBook Server Guide](guides/headless-macbook/README.md)**

Covers fake HDMI adapters, Wi-Fi issues with the lid closed, auto-start on boot, SSH setup, and common troubleshooting.

</details>

## Security

- **Allowlist mode** — Only paired Telegram IDs can interact with the bot. Everyone else is silently dropped
- **Permission prompts** — Claude Code asks for approval before running potentially dangerous operations
- **Unattended mode** — For fully autonomous operation, use `--dangerously-skip-permissions` (only in trusted, isolated environments)
- **OAuth tokens** — Stored locally on the server, no API keys exposed
- **Bot token** — Stored in `~/.claude/channels/telegram/.env` — keep it private and out of version control

## Example Prompts

Once your bot is live, try these from Telegram:

```
"list all TODO comments in the codebase"
"the login endpoint returns 500 — find and fix the bug"
"add input validation to the signup form"
"run the test suite and report results"
"create a new branch, fix the typo in README, and commit"
"what changed in the last 5 commits?"
"set up a new Express API with TypeScript"
```

## FAQ

**Does my computer need to stay on?**
Yes. Claude Code must be running for the bot to respond. Use tmux + a startup service so it auto-starts on boot.

**Can I use an API key instead of a subscription?**
The `--channels` flag requires OAuth login with a Claude subscription (Pro/Max/Team/Enterprise). Console API keys don't support channels.

**Can multiple people use the bot?**
Yes. Add more Telegram IDs to the allowlist:
```
/telegram:access allow <telegram-user-id>
```

**Does it work on a Raspberry Pi / ARM device?**
Claude Code requires Node.js 18+ and Bun, both of which run on ARM64 Linux. If your device runs a 64-bit OS, it should work.

**Can Claude see my screen or browser?**
No. Claude Code works with files and terminal only. For browser testing, configure a [Playwright](https://playwright.dev/) or [Puppeteer](https://pptr.dev/) MCP server.

**What happens if the session crashes?**
Use a process supervisor (systemd on Linux, LaunchAgent on macOS, NSSM on Windows) to auto-restart it.

## References

- [Claude Code Channels & Telegram setup walkthrough](https://x.com/trq212/status/2034761016320696565) — Community post that inspired this project
- [Claude Code Official Documentation](https://docs.anthropic.com/en/docs/claude-code) — Installation, configuration, and features
- [Claude Code Channels Guide](https://docs.anthropic.com/en/docs/claude-code/channels) — Official docs on the Channels feature (research preview)
- [Claude Code Plugins](https://docs.anthropic.com/en/docs/claude-code/plugins) — How plugins and marketplaces work

## Guides

| Guide | Description |
|-------|-------------|
| [Headless MacBook Server](guides/headless-macbook/README.md) | Complete walkthrough for running on a MacBook with no monitor |

## License

MIT
