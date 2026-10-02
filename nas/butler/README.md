# NAS tooling (butler) — a versioned mirror

A byte-for-byte copy of the shell / Python / conf / php tooling that runs on the NAS
(WD **MyCloudEX2Ultra**, `192.168.33.20`; `ssh nas`, user `sshd`, key `~/.ssh/jarvis_sshd_key`).

Taken **2026-10-02** so the tooling stops being machine-local only: it now has history and
diffs. Source: `/mnt/HD/HD_a2/butler/` on the NAS. Copied over `ssh` and verified
**md5-identical for all 41 files**.

**Partly gated — measured, not assumed.** The §18.3 count ratchet **does** count this
tooling: it reads the tracked `*.sh` files, so mirroring the NAS took the corpus 92 → 108
files and moved four counters (6.7 +23, 8.1.8 +6, 9.5 +17, 10.7 +5 — all pre-existing style
of code that had no such convention), which is why landing this needed a deliberate
re-baseline (`tools/ratchet-baseline.tsv`, eighth block). What does *not* reach here:
`tools/lint.sh`'s whole-tree pass enumerates `scripts/`, `tools/`, `bin/`, so `nas/` gets no
whole-tree shellcheck and no swallow classification. Its `.sh` files **are** shellchecked
when staged (that is how the two fixes below were found). Extending the whole-tree scope is
the follow-up that makes the mirror a full gate rather than a partial one.

## In scope (committed)

`*.sh`, `*.py`, `*.cron`, `*.conf`, `*.php`, plus the extension-less init script
`bt-bridge/S35bt-mqtt-bridge`.

## Deliberately NOT copied — and blocked by `.gitignore`

- **Credentials and state**: `*.env` (`openclaw-collectors.env`, `cpap-collector.env`),
  `microsoft-env.sh`, `*token*` (`myair-graph-token.json`, `outlook-mcp-token-cache`),
  `openclaw/secrets.json`, `myair-email-otp.txt`. The NAS export carries
  `GLOWMARKT_PASSWORD` and `RESMED_PASSWORD`; those must never enter this repo.
- **Litter and vendored trees**: `*.bak*` / `*.orig`, `*.log`, `__pycache__/`,
  `entware-opt/`, `influxdb/`, `openclaw-data/`, `shared-data/`, `.trash-*`.

## The NAS is the runtime; this repo is the record

Nothing here is deployed automatically. Changes are made on the NAS by hand (or by the lane
that owns it) and this mirror is refreshed from the NAS afterwards. **A file that differs
between here and the NAS is drift** — and note the crontab names the `scripts/` copy, so a
fix applied to the `mi-scale/` copy alone changes nothing.

## First fixes landed HERE, not yet on the NAS (2026-10-02)

The pre-commit gate caught these when the copy was staged, so they are fixed in the mirror and
the NAS still carries the old version (deployment held — see the one-writer note):

- `scripts/internet-quality-monitor.sh` — `TX`, `RX` and `MIN` were parsed and never used
  (SC2034); removed.
- `nas-hardening/nas-health-check.sh` — the size test used unquoted `$LOG` and `$(…)`
  (SC2046); both quoted.

So this directory is the NAS content **plus these two files**, which are the first items for
the deploy pass.

## Known drift, already measured (2026-10-02)

`mi-scale-autocollect.sh` and `run-mi-scale-collector.sh` exist in **both** `scripts/` and
`mi-scale/` and **differ**; `mi-scale-2-collector.py` is a byte-identical duplicate.

## What runs (from `cron/openclaw-collectors.cron`)

`air-monitor-curl-collector.sh` (5 min) · `cpap-myair-collector.py` (daily 07:20) ·
`it500-influx-collector.py` (:07/:37) · `nas_health_collector.py --once`
(:02/:17/:32/:47) · `S35bt-mqtt-bridge start` (:03, watchdog) ·
`internet-quality-monitor.sh` (:09) · `glowmarkt-collector.py` (*/30).
