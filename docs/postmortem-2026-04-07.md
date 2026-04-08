# Postmortem — Telegram bot freezes a Mac mini, 2026-04-06/07

## TL;DR

Bringing up the Claude Code Telegram bot on a M4 Mac mini (macOS Sequoia 15.5)
following the official README froze the entire machine within ~90 seconds of
launch. After ~6 hours of forensic work, the bot is now stable and the root
causes are documented below.

The README/setup as it existed on 2026-04-05 had **four independent bugs that
combined into the freeze**, plus a **fifth latent bug** that surfaced 17 hours
later when the bot went silent overnight. None of them were obvious at first
glance, and at least two of them are upstream issues in `claude-code` itself.

This post-mortem walks through each bug, the evidence, and the fix.

---

## What we observed

**Phase 1 (initial freeze):** Following the README I installed `claude-code`,
the telegram plugin, dropped the LaunchAgent into place, and started the bot.
Within ~30 seconds, `claude` hit ~2 GB RSS. Within ~90 seconds the entire
machine was unreachable: no SSH, no ICMP ping, no anything. ARP cache still
had the MAC address (kernel was alive at L2) but userland was completely
wedged. Other LAN hosts were fine — only this Mac was dead. Hard power-cycle
was the only recovery.

**Phase 2 (silent failure 17h later):** Once the freeze was prevented and the
bot was stable, it ran fine through several hours of real conversations.
Overnight (5+ hours of idle), the bot stopped responding to Telegram messages
without any visible crash. The `claude` and `bun` processes were both alive,
no kills in any log, but `lsof` showed zero ESTABLISHED TCP connections on
either process. Killing and restarting fixed it instantly. This is a different
bug from the freeze — same cleanup, separate root cause.

---

## Root cause #1 — `yes |` triggers the ArrayBuffer leak (#32729) via `--print` fallback

This was the freeze.

The README's recommended bot launch is:

```bash
yes | claude --channels plugin:telegram@claude-plugins-official \
    --dangerously-skip-permissions --permission-mode bypassPermissions
```

The `yes |` is documented as "auto-accepts the workspace trust dialog that
Claude Code shows on first launch." That's true on a foreground run. But
when stdin is a pipe, `claude` detects "no TTY attached" and **silently
falls back to `--print` mode** instead of running the channels listener.

In `--print` mode, claude reads its prompt from stdin. The pipe is `yes`
producing infinite `y\n`. Claude tries to process this stream as a single
prompt, allocating a fresh `ArrayBuffer` per chunk. It never finishes
reading (because `yes` never stops) and never frees any of the buffers.
This is exactly the failure mode of [anthropics/claude-code#32729][32729]
and [#32892][32892] — except triggered deterministically rather than
intermittently. **Memory grows at ~100 MB/sec.**

Evidence:

1. With `yes |`: `claude` RSS goes 0 → 2 GB in ~20 seconds, repeatable across
   versions 2.1.80 / 2.1.81 / 2.1.92.
2. Without `yes |` (running `claude --channels …` inside a real `tmux` pty):
   RSS stays at ~330 MB indefinitely. Verified for 17 hours.
3. The symptom is `bun=NONE` in process listings during the leak window —
   claude never reaches the point of spawning the plugin worker because it
   thinks it's in print mode, not channels mode.

[32729]: https://github.com/anthropics/claude-code/issues/32729
[32892]: https://github.com/anthropics/claude-code/issues/32892

**Fix:** `claude-safe-launch.sh` v4 launches claude inside a `tmux new-session`
with no piped stdin at all. tmux provides a real pty, so claude correctly
detects the channels mode. The trust prompt that the `yes |` was working
around is dismissed by a small background helper that uses `tmux send-keys`
to press Enter (trust folder) + Down + Enter (bypass permissions warning)
on a fixed delay. This works for the initial launch *and* every wrapper
restart.

**Note:** the `--dangerously-skip-permissions` and `--permission-mode
bypassPermissions` flags do **not** dismiss either of these two prompts.
Both are tested as of `claude-code` 2.1.92.

---

## Root cause #2 — `MAX_RAM_KB` / `ulimit -v` is theater on macOS

The original `claude-safe-launch.sh` v2/v3 set a virtual-memory ceiling
intended as a backstop for the leak above:

```bash
MAX_RAM_KB="${MAX_RAM_KB:-4194304}"  # 4 GB
prefix="ulimit -v $MAX_RAM_KB; "
```

On macOS Sequoia (and every macOS for years), **`RLIMIT_AS` is a no-op.**
The kernel doesn't enforce address-space caps the way Linux does. Same
goes for `RLIMIT_RSS` (`ulimit -m`) and the `ResidentSetSize` key in
`HardResourceLimits` of a launchd plist — `setrlimit(2)` accepts the
values, the kernel ignores them. Verified by the fact that the leaking
claude blew straight past 4 GB and froze the machine while `ulimit -v
4194304` was supposedly in effect.

References:
- [HN — macOS no longer allows setting system-wide ulimits](https://news.ycombinator.com/item?id=37233295)
- [Go #30401 — setrlimit behavior change on macOS](https://github.com/golang/go/issues/30401)
- [Python #78783 — setrlimit macOS quirks](https://github.com/python/cpython/issues/78783)

**What actually works on macOS:**

| Mechanism | Effective? | Notes |
|---|---|---|
| `ulimit -v` (RLIMIT_AS) | ❌ no | accepted, ignored by kernel |
| `ulimit -m` (RLIMIT_RSS) | ❌ no | accepted, ignored |
| launchd `HardResourceLimits.ResidentSetSize` | ❌ no | same — calls `setrlimit` |
| `NODE_OPTIONS=--max-old-space-size=N` | ✅ yes | caps the V8 heap (most of node's memory) |
| `taskpolicy -b -c utility` | ✅ yes | puts process in background QoS so jetsam targets it first under pressure |
| Polled watchdog reading RSS via `ps -o rss=` | ✅ yes | application-level enforcement (this repo's watchdog) |

**Fix:** `claude-safe-launch.sh` v4 removes `ulimit -v` entirely, exports
`NODE_OPTIONS="--max-old-space-size=2048"` before invoking claude (this
caps the V8 heap), and exposes an opt-in `USE_TASKPOLICY=true` to add
the jetsam-targeting wrapper. The watchdog continues to do RSS polling
as the real backstop.

---

## Root cause #3 — `setup.sh` silently fails to install the plugin

The `setup.sh` shipped in this repo had:

```bash
claude plugin marketplace add anthropics/claude-plugins-official 2>/dev/null || true
claude plugin install telegram@claude-plugins-official 2>/dev/null || true
```

On a clean Mac that's never run a claude marketplace install before, the
`marketplace add` step downloads the marketplace files into
`~/.claude/plugins/marketplaces/claude-plugins-official/external_plugins/telegram/`.
The `plugin install` step then registers it as an active plugin in
`claude plugin list`.

If `plugin install` fails for any reason, **the directory still exists**
but the plugin is **not actually installed**. When the bot launches with
`--channels plugin:telegram@claude-plugins-official`, claude prints:

```
plugin:telegram@claude-plugins-official · plugin not installed
```

…and the bun worker never starts. No error. No crash. The bot just
sits there listening to nothing.

The `2>/dev/null || true` in `setup.sh` masked the failure, so even
when the install step exited non-zero, setup reported success. We hit
this on the freeze recovery: the directory was there from a March
install, but `claude plugin list` returned `No plugins installed`.

**Fix:** `setup.sh` v4 lets `plugin install` print errors, captures the
output to a log, then **verifies** the plugin shows up in
`claude plugin list` and aborts with a clear message if not. New step
breakdown is 9 steps instead of 7 (added explicit auth check + plugin
verification).

---

## Root cause #4 — `claude auth login --claudeai` is unusable headlessly

The README says:

```bash
claude auth login --claudeai
```

> This gives you a URL to open in your browser. Sign in and paste the
> code back.

This works in a *graphical* shell session: `claude` runs `open <url>` to
launch the local browser, and the browser → callback chain hands the
token back via macOS Keychain.

In a headless / SSH-only context (which is half the README's premise —
"a Mac mini sitting in a closet running 24/7"), the flow breaks:

1. `claude auth login --claudeai` prints the URL.
2. Without a TTY+browser, `open` is a no-op.
3. **The `claude` process exits immediately after printing the URL.**
   It does *not* wait on stdin for a code paste.
4. There is no `claude auth code <code>` follow-up command.
5. There is no local HTTP listener for the OAuth callback.

So you've authenticated in your phone's browser, you're holding a code,
and there's no way to feed it back to the local CLI. `claude auth status`
keeps returning `loggedIn: false`.

The actual headless-friendly path is **`claude setup-token`**, which:

1. Prints the URL *and* a `Paste code here if prompted >` prompt.
2. **Waits on stdin** for the code (works fine via `tmux send-keys`).
3. On success, prints a long-lived `sk-ant-oat01-…` OAuth token.
4. The token is consumed via `export CLAUDE_CODE_OAUTH_TOKEN=…`.

The `oat01` prefix is the OAuth Access Token format — it's the same
subscription auth as `auth login`, just packaged for env-var consumption
instead of keychain. `--channels` works fine with it. Verified for ~60 min
uninterrupted of bot operation, including real conversations with the model.

**Fix:**

- `setup.sh` v4 detects unauthenticated state and prints both options
  (`auth login` for GUI, `setup-token` for headless) instead of assuming
  the GUI flow.
- `claude-safe-launch.sh` v4 sources `~/.claude-auth.env` (chmod 600)
  before invoking claude, so the env-var token survives across restarts
  and reboots.

---

## Root cause #5 — TCP socket goes stale + macOS keepalive default = 2 hours

This is the silent overnight failure.

After the bot was stable, it ran fine for ~6 hours of evening use, then
went idle. Sometime in the early morning (around 04:45 local), the bot
stopped responding to Telegram messages. No crash. `claude` PID alive
17 hours, `bun` PID alive 17 hours, both in process state `S+` (sleeping
in foreground), zero ESTABLISHED TCP connections.

What happened: the bun worker holds a long-poll TCP connection to
`api.telegram.org`. While idle, it sits in `recv()` waiting for the next
update. Sometime overnight, the connection went **half-open** — most
likely a Wi-Fi blip (DHCP renew, NAT timeout, AP roam) on the Mac side.
The TCP socket on the kernel still exists but the remote end no longer
knows about it. Bun has no way to know its socket is dead unless it
either tries to send something *or* the OS declares the socket dead via
TCP keepalive.

**macOS's default `net.inet.tcp.keepidle` is `7200000` ms = 2 hours.**
That is, the OS waits 2 hours of total idle before sending the first
keepalive probe. This is fine for desktop apps that don't care, but
murder for a bot whose only contact with the world is one long-lived
TCP socket.

The result: bun stuck on a `recv()` that will never return until macOS
finally probes the socket (~2h after the blip) and discovers it's dead.
During those hours, the bot is alive but deaf.

There is also a **secondary finding**: a separate bun process (PID 41001),
orphaned during the chaotic phase 1 setup, lingered on the system for
5h 50m and crashed at 04:45:55 with `EXC_BAD_ACCESS / SIGABRT —
libsystem_c.dylib: abort() called`. This was an internal Bun runtime
panic (the address `0xffffffff00000000` is a sentinel/poison value, not
real memory corruption), not the active bot. The watchdog should have
killed this orphan but its `kill_plugin_bun_workers` path didn't fire
for it (the orphan filter has a small race window). The crash was a
sideshow — the active bot's silence was the keepalive bug.

**Fix:** `claude-watchdog.sh` v4 adds a new check, `kill_stale_bot()`:

1. Find the active `bun server.ts` process and current `claude` process.
2. Read `nettop -P -L 1 -t external` to get bun's `bytes_in` / `bytes_out`
   counters. (Why nettop and not `lsof`: lsof on macOS doesn't show
   ESTABLISHED TCP for user processes without elevated privs in most
   configurations. nettop reports bytes per pid without elevation.)
3. Snapshot the counters to `/tmp/claude-watchdog-snapshots/bun-network`
   along with a "last change" timestamp.
4. On the next watchdog run (10s later), if bytes_in *and* bytes_out are
   both unchanged from the snapshot, and the snapshot timestamp is older
   than `NETWORK_STALE_SECONDS` (default 180s = 3 minutes, which is six
   long-poll cycles), kill `claude`. The wrapper auto-restarts it with
   fresh sockets.

Verified live: when the bot is healthy and grammy is doing its 30-second
long-poll cycle, bytes grow predictably (~50–100 bytes/cycle) and the
snapshot timestamp resets. When the socket dies, the bytes freeze and
the kill fires within ~3 minutes.

A complementary OS-level fix is also possible:

```bash
sudo sysctl -w net.inet.tcp.keepidle=180000     # 3 minutes
sudo sysctl -w net.inet.tcp.keepintvl=15000     # 15 seconds between probes
sudo sysctl -w net.inet.tcp.keepcnt=8           # 8 probes before giving up
```

Persisted to `/etc/sysctl.conf`. This is **complementary**, not
redundant — it lowers the OS-level dead-socket detection window from
2 hours to ~3 minutes. Bots with their own keepalive logic can ignore
it; bots like grammy that just call `recv()` benefit from it.

---

## Timeline of the incident

Times are EDT.

| When | What |
|---|---|
| 2026-04-06 19:00 | I follow README, bot launched in tmux with `yes \|` |
| 19:36:46 | `claude` reaches 2034 MB RSS — watchdog v3 kills it for "memory hog" |
| 19:37 | Wrapper auto-restarts. Same thing again. Same again. |
| 19:38 | Watchdog circuit breaker trips after 3 kills in 1 minute |
| 19:39 | Mac mini becomes unreachable. SSH dead. Ping dead. Hard power-cycle. |
| 22:54 | After 3 hours of forensic work + a research agent, deploy v4 fixes: no `yes \|`, `setup-token` auth, plugin properly installed, watchdog with 10s interval and NODE_OPTIONS heap cap |
| 22:55 | Bot starts cleanly. claude=327 MB, bun spawns, listens for messages |
| 23:30 | First real conversation with the bot. Researches topics, replies via MCP. Works perfectly. |
| 23:43 | `/telegram:access pair`, `/telegram:access policy allowlist`. Bot locked down. |
| ~23:50 | Last conversation. User goes to sleep. Bot idle. |
| 04:45:55 | Orphan bun (PID 41001) from the recovery chaos crashes with `abort()`. **Unrelated to active bot.** |
| ~05:00–16:00 | Active bun TCP socket goes stale at some point. Long-poll hangs. Bot deaf but alive. |
| 16:07 | User notices bot doesn't reply. Reports it. |
| 16:08 | I confirm: claude alive 17h, bun alive 17h, lsof shows zero ESTABLISHED. Classic stale-socket signature. |
| 16:09 | `kill -9 claude bun`. Wrapper auto-restarts. Fresh sockets. Bot revives in 25 seconds. |
| 16:55 | Watchdog v4 deployed with `kill_stale_bot()`. Validated: bytes grow, no false positives, kill triggers correctly when frozen. |

---

## Lessons

1. **`yes |` is not a valid auto-trust workaround for `claude --channels`.**
   It triggers a fundamentally different code path (--print mode) that
   leaks. Use a real pty + `tmux send-keys` for the trust prompt instead.

2. **macOS resource limits are mostly theater.** Anything based on
   `setrlimit(2)` with `RLIMIT_AS` / `RLIMIT_RSS` is ignored by the
   kernel. The only real backstops are application-aware (NODE_OPTIONS,
   polling watchdogs) or QoS-based (taskpolicy + jetsam).

3. **`claude auth login` is GUI-only.** For headless setups, use
   `claude setup-token` and stick the resulting `sk-ant-oat01-…` token
   into an env file your launcher sources.

4. **Verify the plugin actually installed.** Don't trust `2>/dev/null
   || true` on a `plugin install`. Cross-check with `claude plugin list`
   and abort if the entry is missing.

5. **`lsof` is unreliable for socket counting on macOS.** Use `nettop`
   for byte-counter polling — it works for unprivileged users and
   gives you per-pid I/O totals.

6. **A 2-hour TCP keepalive default is too long for a long-poll bot.**
   Either lower it system-wide via `sysctl`, or detect at the
   application/watchdog layer (this repo's choice).

7. **The watchdog should poll the network too, not just CPU+RAM.** The
   "alive but stuck" failure mode is invisible to traditional resource
   watchdogs and only shows up if you specifically check that the
   long-poll socket is still moving bytes.

---

## What changed in this repo as a result

```
scripts/com.claude.telegram.plist          → uses safe-launch.sh, $HOME-templated, ThrottleInterval=300
scripts/setup.sh                            → 9 steps, plugin install verified, headless auth path
scripts/watchdog/claude-safe-launch.sh      → v4, no yes pipe, NODE_OPTIONS, circuit breaker, prompt dismisser
scripts/watchdog/claude-watchdog.sh         → v4, 10s interval, kill -9, crash-loop breaker, kill_stale_bot
scripts/watchdog/com.claude.watchdog.plist  → StartInterval=10, ThrottleInterval=10, /usr/local/bin path
```
