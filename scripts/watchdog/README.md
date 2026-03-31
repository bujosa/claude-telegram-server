# Claude Code Watchdog

Kills hung Claude Code processes that burn CPU at 80-100% after sessions end.

## Why This Exists

Claude Code has a [known, unresolved bug](https://github.com/anthropics/claude-code/issues/22275) (20+ open issues, no fix as of March 2026) where processes keep running at full CPU after a session closes. Root causes include:

- **TUI renderer never idles** — Ink/React renders at ~60Hz even with no activity
- **Busy-wait event loop** — Bun runtime calls `epoll_pwait` with `timeout=0` (tight spin loop)
- **`caffeinate` leak** (macOS) — spawns new processes on each action, never cleans them up
- **Orphaned child processes** — Desktop app and VS Code extension don't kill children on exit

The watchdog runs every 5 minutes and cleans up these zombie processes.

## What It Does

1. **Kills orphaned `caffeinate` processes** (macOS) — parent is dead or PID 1
2. **Kills CPU-hogging `claude`/`@anthropic` processes** — above 80% CPU, running >2 min, no TTY attached
3. **Kills orphaned children** — parent is PID 1, burning >10% CPU for >2 min

It will **not** kill active sessions that have a terminal attached.

## Configuration

Override defaults via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `CPU_THRESHOLD` | `80` | CPU % above which a process is considered stuck |
| `MIN_AGE_SECONDS` | `120` | Only kill processes older than this (avoids killing startups) |
| `LOG_FILE` | `/tmp/claude-watchdog.log` | Where kills are logged |
| `DRY_RUN` | `false` | Set to `true` to log what would be killed without actually killing |

## Quick Test (Dry Run)

```bash
DRY_RUN=true bash claude-watchdog.sh
cat /tmp/claude-watchdog.log
```

## Install — macOS (LaunchAgent)

```bash
# Copy script
sudo cp claude-watchdog.sh /usr/local/bin/claude-watchdog.sh
sudo chmod +x /usr/local/bin/claude-watchdog.sh

# Install timer (runs every 5 minutes)
cp com.claude.watchdog.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.claude.watchdog.plist
```

Verify:

```bash
launchctl list | grep watchdog
tail -f /tmp/claude-watchdog.log
```

Uninstall:

```bash
launchctl unload ~/Library/LaunchAgents/com.claude.watchdog.plist
rm ~/Library/LaunchAgents/com.claude.watchdog.plist
sudo rm /usr/local/bin/claude-watchdog.sh
```

## Install — Linux (systemd timer)

```bash
# Copy script
sudo cp claude-watchdog.sh /usr/local/bin/claude-watchdog.sh
sudo chmod +x /usr/local/bin/claude-watchdog.sh

# Edit service file — replace YOUR_USERNAME
sudo cp claude-watchdog.service /etc/systemd/system/
sudo cp claude-watchdog.timer /etc/systemd/system/

sudo systemctl daemon-reload
sudo systemctl enable --now claude-watchdog.timer
```

Verify:

```bash
systemctl list-timers | grep watchdog
journalctl -u claude-watchdog.service -f
```

Uninstall:

```bash
sudo systemctl disable --now claude-watchdog.timer
sudo rm /etc/systemd/system/claude-watchdog.{service,timer}
sudo systemctl daemon-reload
sudo rm /usr/local/bin/claude-watchdog.sh
```

## Manual Run

```bash
# Kill for real
sudo bash claude-watchdog.sh

# Just see what would be killed
DRY_RUN=true bash claude-watchdog.sh

# Custom thresholds
CPU_THRESHOLD=50 MIN_AGE_SECONDS=60 bash claude-watchdog.sh
```

## Logs

All actions are logged to `/tmp/claude-watchdog.log`:

```
[2026-03-31 14:30:01] Watchdog run started (threshold=80%, min_age=120s, dry_run=false)
[2026-03-31 14:30:01] Cleaned 3 orphaned caffeinate process(es)
[2026-03-31 14:30:01] Killing PID 48291 (CPU 97%, age 1832s, no TTY) — /usr/local/bin/node /usr/local/bin/claude
[2026-03-31 14:30:03] Killed 1 CPU-hogging process(es)
[2026-03-31 14:30:03] Watchdog run complete
```

## Related Issues

- [#22275](https://github.com/anthropics/claude-code/issues/22275) — High sustained CPU usage (~100%) even when idle
- [#22509](https://github.com/anthropics/claude-code/issues/22509) — High CPU usage at idle/prompt state (macOS)
- [#40706](https://github.com/anthropics/claude-code/issues/40706) — Desktop app leaves orphaned child processes at 100% CPU
- [#36729](https://github.com/anthropics/claude-code/issues/36729) — Unrecoverable CPU spin after MCP tool response
- [#41122](https://github.com/anthropics/claude-code/issues/41122) — VS Code extension causes high CPU load
