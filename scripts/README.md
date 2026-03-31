# Scripts

Ready-to-use configuration files and scripts for setting up Claude Code as a Telegram bot.

## Files

| File | Platform | Description |
|------|----------|-------------|
| [setup.sh](setup.sh) | macOS | One-command setup script — installs all dependencies, configures sleep, installs LaunchAgent |
| [com.claude.telegram.plist](com.claude.telegram.plist) | macOS | LaunchAgent for auto-starting the bot on boot |
| [claude-telegram.service](claude-telegram.service) | Linux | systemd service file for auto-starting the bot on boot |

## Watchdog

Claude Code has a [known CPU burn bug](https://github.com/anthropics/claude-code/issues/22275) where processes keep running at 80-100% CPU after sessions close. The watchdog kills these zombie processes automatically.

See **[watchdog/](watchdog/)** for the script, install instructions, and platform-specific service files.

## Quick Start (macOS)

```bash
git clone https://github.com/bujosa/claude-telegram-server.git
cd claude-telegram-server/scripts
chmod +x setup.sh
./setup.sh
```

## Manual Install (Linux)

1. Copy and edit the systemd service file:

```bash
sudo cp claude-telegram.service /etc/systemd/system/
# Edit the file and replace YOUR_USERNAME with your actual username
sudo nano /etc/systemd/system/claude-telegram.service
sudo systemctl daemon-reload
sudo systemctl enable --now claude-telegram
```
