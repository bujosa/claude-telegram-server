# Headless MacBook Server Guide

Turn a MacBook into a dedicated always-on server with no monitor, keyboard, or mouse. Access everything via SSH and run Claude Code 24/7 from Telegram.

## Hardware You Need

| Item | Why |
|------|-----|
| MacBook (Apple Silicon recommended) | The server itself |
| **Fake HDMI adapter** | Prevents GPU throttling and Wi-Fi degradation when the lid is closed |
| Power adapter | Always plugged in |
| USB-C to Ethernet adapter (optional) | More reliable than Wi-Fi for a server |

> **Why fake HDMI?** When a MacBook lid is closed and no display is detected, macOS aggressively throttles the GPU and can reduce Wi-Fi performance. A $5 fake HDMI dongle tricks macOS into thinking a monitor is connected, keeping everything running at full speed.

## Step-by-Step Setup

Do this once with a monitor and keyboard connected. After setup, you'll never need them again.

### 1. Set a Static IP (GUI Method — Survives Reboots)

Go to: **System Settings > Network > Wi-Fi > Details > TCP/IP**

| Field | Value |
|-------|-------|
| Configure IPv4 | Manually |
| IP Address | `10.0.0.19` (pick one outside your DHCP range) |
| Subnet Mask | `255.255.255.0` |
| Router | `10.0.0.1` (your gateway) |

Then go to the **DNS** tab and add your DNS servers:

| Priority | Server | Purpose |
|----------|--------|---------|
| Primary | `10.0.0.17` | Local DNS / Pi-hole (optional) |
| Fallback | `8.8.8.8` | Google Public DNS |

> **Why GUI over CLI?** The `networksetup -setmanual` command works, but on recent macOS versions the config can reset after a reboot. Setting it through System Settings writes to a more persistent location.

You can also do it via CLI if you prefer (just verify after a reboot):

```bash
sudo networksetup -setmanual Wi-Fi 10.0.0.19 255.255.255.0 10.0.0.1
sudo networksetup -setdnsservers Wi-Fi 10.0.0.17 8.8.8.8
```

### 2. Enable Remote Login (SSH)

**System Settings > General > Sharing > Remote Login → ON**

Make sure your user is listed under "Allow access for".

Or via terminal:

```bash
sudo systemsetup -setremotelogin on
```

### 3. Disable All Sleep

```bash
sudo pmset -a sleep 0 displaysleep 0 disksleep 0 \
  standby 0 autopoweroff 0 hibernatemode 0 networkoversleep 0
```

Verify everything is set to `0`:

```bash
pmset -g | grep -E 'sleep|standby|hibernate|autopoweroff'
```

Expected output:

```
 standby              0
 networkoversleep     0
 disksleep            0
 sleep                0
 hibernatemode        0
 displaysleep         0
```

### 4. Set Up Passwordless SSH

On your **main machine** (not the MacBook server):

```bash
# Copy your SSH key
ssh-copy-id your-user@10.0.0.19

# Test it
ssh your-user@10.0.0.19
```

Add a convenient alias to `~/.ssh/config` on your main machine:

```
Host myserver
    HostName 10.0.0.19
    User your-user
    IdentityFile ~/.ssh/id_ed25519
```

Now just run `ssh myserver`.

### 5. Go Headless

1. Plug in the **fake HDMI adapter**
2. Plug in the **power adapter**
3. **Close the lid**
4. From your main machine: `ssh myserver`

If SSH connects, you're good. The MacBook is now a headless server.

### 6. Install Dependencies (via SSH)

```bash
# Homebrew
NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
echo 'eval $(/opt/homebrew/bin/brew shellenv)' >> ~/.zshrc
source ~/.zshrc

# Node.js
brew install node

# Bun
curl -fsSL https://bun.sh/install | bash
source ~/.zshrc

# tmux
brew install tmux

# GitHub CLI (optional)
brew install gh

# Claude Code
npm install -g @anthropic-ai/claude-code
```

### 7. Authenticate Claude Code

```bash
claude auth login --claudeai
```

This prints a URL. Open it in a browser on any device, sign in with your Claude Max/Pro account, and paste the authorization code back into the terminal.

### 8. Set Up Telegram Bot

Follow the [main guide](../../README.md#step-3--create-a-telegram-bot) for creating the bot and installing the plugin, then:

```bash
# Configure bot token
mkdir -p ~/.claude/channels/telegram
echo 'TELEGRAM_BOT_TOKEN=your-token-here' > ~/.claude/channels/telegram/.env

# Launch in tmux
tmux new-session -d -s claude-telegram \
  'claude --channels plugin:telegram@claude-plugins-official'
```

Pair your account and set the allowlist policy (see [main guide](../../README.md#step-7--pair-your-telegram-account)).

### 9. Auto-Start on Boot

Create a LaunchAgent so Claude Code starts automatically when the MacBook boots (after a power outage, for example).

Create `~/Library/LaunchAgents/com.claude.telegram.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.claude.telegram</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/zsh</string>
        <string>-c</string>
        <string>sleep 10 &amp;&amp; export PATH=/opt/homebrew/bin:$HOME/.bun/bin:$PATH &amp;&amp; tmux kill-session -t claude-telegram 2>/dev/null; tmux new-session -d -s claude-telegram "export PATH=/opt/homebrew/bin:$HOME/.bun/bin:$PATH &amp;&amp; yes | claude --channels plugin:telegram@claude-plugins-official --dangerously-skip-permissions --permission-mode bypassPermissions"</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/claude-telegram.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/claude-telegram.err</string>
</dict>
</plist>
```

Load it:

```bash
launchctl load ~/Library/LaunchAgents/com.claude.telegram.plist
```

Check logs:

```bash
tail -f /tmp/claude-telegram.log
```

## Troubleshooting

| Problem | Cause | Fix |
|---------|-------|-----|
| Can't SSH after reboot | Remote Login not enabled | Turn it on in System Settings before going headless |
| Static IP resets on reboot | Configured via CLI | Redo it through System Settings GUI |
| Wi-Fi extremely slow or drops | No fake HDMI adapter | Plug one in — macOS throttles without a display |
| SSH connection times out | Poor Wi-Fi signal | Move closer to router or switch to Ethernet |
| Bot stops responding | tmux session crashed | Check `tmux list-sessions`; use LaunchAgent for auto-restart |
| `sudo` fails remotely | User not admin | Run `dscl . -read /Groups/admin GroupMembership` to verify |
| Homebrew install fails with "not admin" | `sudo` needs a TTY | Pre-auth with `echo 'password' \| sudo -S -v` before running installer |
| High SSH latency (>100ms) | Wi-Fi congestion | Use 5GHz band or Ethernet adapter |

## Network Diagram

```
┌─────────────┐         ┌──────────────────┐         ┌──────────────┐
│   Router    │         │  MacBook Server  │         │   Your Mac   │
│  10.0.0.1   │◀───────▶│  10.0.0.19       │◀── SSH ─│  10.0.0.14   │
│   (Wi-Fi)   │         │  Claude + tmux   │         │              │
└─────────────┘         └──────────────────┘         └──────────────┘
                                ▲
                                │ Telegram Bot API
                                ▼
                        ┌──────────────┐
                        │   Telegram   │
                        │  (your phone)│
                        └──────────────┘
```

## Tips

- **Keep the lid slightly open** if you don't have a fake HDMI adapter — even a crack helps Wi-Fi
- **Set the MacBook to auto-boot on power restore**: `sudo pmset -a autorestart 1` — if power goes out and comes back, it boots automatically
- **Monitor remotely**: `ssh myserver "pmset -g; uptime; df -h"` to check health
- **Update Claude Code remotely**: `ssh myserver "npm update -g @anthropic-ai/claude-code"`
