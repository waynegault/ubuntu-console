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
re-baseline (`tools/ratchet-baseline.tsv`, eighth block). The swallow check reaches here too:
`tools/contracts_check.py` scans `scripts/*.sh, bin/*, tools/*.sh, tools/hooks/*,
tools/qwen-hooks/*, nas/**/*.sh` (widened 2026-10-02), and `nas/` is the one group walked
RECURSIVELY because these files sit two levels down. What does *not* reach here:
`tools/lint.sh`'s whole-tree pass enumerates `tactical-console.bashrc`, `install.sh`, `env.sh`,
`scripts/`, `tools/`, `tools/qwen-hooks/` and `bin/` — so `nas/` gets no whole-tree shellcheck.
Its `.sh` files **are** shellchecked when staged (that is how the two fixes below were found).
Extending the whole-tree lint scope is the follow-up that makes the mirror a full lint gate
rather than a partial one. These files also carry **no `# Module Version:` marker and no
`AI INSTRUCTION` header, by design** (card `05509ef9`): `tools/check-module-versions.sh` examines
only files that already carry the marker, and the `AI INSTRUCTION` cross-script case in
`tests/tactical-console{,-fast}.bats` enumerates `bin/*.sh` and `scripts/*.sh` only — neither
reaches `nas/**`. A marker here would be a version number nothing bumps and a header nothing
reads, on files that are copies of NAS content rather than editable-in-place modules; adding
them would also trigger a needless §18.3 re-baseline. The omission is the deliberate convention,
so do not read it as drift.

## One deliberate exception to byte-identical mirroring

`nas/butler/scripts/lib/butler_common.py` (card `974f99ff`) is the ONE shared module the
collectors import rather than each carrying a private copy: one OTP extractor, one Microsoft
Graph GET/DELETE client, one InfluxDB line-protocol POST. It deploys to
`/mnt/HD/HD_a2/butler/scripts/lib/` alongside the scripts — a script run as
`python /path/to/foo.py` has its own directory on `sys.path`, so
`from lib.butler_common import ...` resolves. This is a deliberate departure from the
byte-for-byte copy, taken because the alternative was five drifting `_extract_otp` copies and
four divergent Graph clients. The OAuth reader keeps its own Graph client on purpose: it returns an HTTP-error
payload with `_http_status` rather than raising, and uses a custom SSL context.

The dead `nas-cpap-full.py` stub was **deleted** from the mirror (2026-10-03, card `8dda5918`)
— see the divergence list below for why and for the NAS-side delete.

## In scope (committed)

`*.sh`, `*.py`, `*.cron`, `*.conf`, `*.php`, plus the extension-less init script
`bt-bridge/S35bt-mqtt-bridge`.

## Deliberately NOT copied — and blocked by `.gitignore`

- **Credentials and state**: `*.env` (`openclaw-collectors.env`, `cpap-collector.env`),
  `microsoft-env.sh`, `*token*` (`myair-graph-token.json`, `outlook-mcp-token-cache`),
  `openclaw/secrets.json`, `myair-email-otp.txt`. The NAS export carries
  `GLOWMARKT_PASSWORD` and `RESMED_PASSWORD`; those must never enter this repo.

The CPAP scripts therefore hold **no literals** (credential-hardening, 2026-10-02 — card
`a7383ea0`): `cpap-myair-fetch.py` reads `CPAP_MYAIR_USERNAME`,
`CPAP_MYAIR_PASSWORD` and `CPAP_MYAIR_API_KEY` from the environment, and
`cpap-collect-with-otp.sh` self-sources `cron/openclaw-collectors.env` +
`cron/cpap-collector.env` (the latter defines the names, aliasing `CPAP_MYAIR_PASSWORD` to
`RESMED_PASSWORD`) before it runs. The live `/etc/crontab` 08:00 entry sources nothing, so
that self-sourcing is what keeps the job working without hardcoded values.
- **Litter and vendored trees**: `*.bak*` / `*.orig`, `*.log`, `__pycache__/`,
  `entware-opt/`, `influxdb/`, `openclaw-data/`, `shared-data/`, `.trash-*`.

## The NAS is the runtime; this repo is the record

Nothing here is deployed automatically. Changes are made on the NAS by hand (or by the lane
that owns it) and this mirror is refreshed from the NAS afterwards. **A file that differs
between here and the NAS is drift** — and note the crontab names the `scripts/` copy, so a
fix applied to the `mi-scale/` copy alone changes nothing.

## Mirror divergences pending the NAS deploy (2026-10-02; extended 2026-10-03)

These differ from the NAS here while the NAS still carries the old content (deployment held —
see the one-writer note).  One list, so the deploy pass has a single source:

- `scripts/internet-quality-monitor.sh` — `TX`, `RX` and `MIN` were parsed and never used
  (SC2034); removed.
- `nas-hardening/nas-health-check.sh` — the size test used unquoted `$LOG` and `$(…)`
  (SC2046); both quoted.
- `scripts/nas-cpap-unified.py` (2026-10-03, card `8dda5918`) — `_fetch_cpap_data` returned a
  MOCK payload (`{"device": {}, "sleep_records": []}`) while `main()` printed `{"ok": true}`,
  so a caller saw success with nothing fetched.  It now raises `NotImplementedError` and `main()`
  reports the failure instead of a false success.  The NAS copy still returns the mock data
  until the deploy pass.
- `scripts/nas-cpap-full.py` **DELETED** (2026-10-03, card `8dda5918`) — an unreferenced stub
  that triggered MFA and printed `SUCCESS` **without fetching any data** (its fetch was a
  `# TODO`).  It was not called by the cron (`cron/openclaw-collectors.cron` runs
  `cpap-myair-collector.py`) nor by `cpap-collect-with-otp.sh` (which runs
  `cpap-myair-fetch.py` + `nas-graph-otp.py`); `git grep nas-cpap-full` matched only this README.
  The NAS copy still exists, so the deploy pass must delete it there too:
  `/mnt/HD/HD_a2/butler/scripts/nas-cpap-full.py`.

So this directory is the NAS content **plus three changed files and minus one deleted stub** —
the deploy pass's whole to-do list.  Deleting the stub is a change to the mirror's file *set*,
larger than the byte edits above, so it is recorded here deliberately instead of left as a
silent absence.

**Reversal (card `8dda5918`):** if the owner prefers the mirror to stay byte-identical, restore
`nas-cpap-full.py` from git history and revert `nas-cpap-unified.py` to its mock return, then
record the stub under "Known drift" instead.  The current choice applies the recommendation and
documents the divergence here.

## Known drift, already measured (2026-10-02)

`mi-scale-autocollect.sh` and `run-mi-scale-collector.sh` exist in **both** `scripts/` and
`mi-scale/` and **differ**; `mi-scale-2-collector.py` is a byte-identical duplicate.

## Naming — deliberate, documented, NOT renamed here (card `307df479`)

Most `scripts/` files are hyphenated, but one is not, and three readers share an OTP role.  This
is recorded rather than renamed because the mirror is a byte-for-byte copy of the NAS and the NAS
invokes these files by **absolute path**:

- `scripts/nas_health_collector.py` — the underscore outlier.  The NAS cron names it by absolute
  path (`cron/openclaw-collectors.cron`: `/mnt/HD/HD_a2/butler/scripts/nas_health_collector.py --once`),
  and `scripts/09d-oc-agents.sh` lists it by that name.  Renaming it to `nas-health-collector.py`
  would change the NAS path — the cron would have to change on the NAS too — and diverge this
  mirror's bytes and file set.  So the name is documented, not changed.

- Three OTP readers, each a different transport/contract (the audit's "3 OTP readers"):
  * `scripts/nas-graph-otp.py` — pure-stdlib Graph reader; USED by `cpap-collect-with-otp.sh`.
  * `scripts/read-myair-otp-imap.py` — IMAP reader; referenced by no cron entry and no live
    wrapper (tests only).
  * `scripts/read-myair-otp-graph-oauth.py` — Graph reader with its own client and an
    `_http_status` error payload (see "One deliberate exception" above); referenced by no cron
    entry and no live wrapper (tests only).

  The last two are the candidates for the "superseded duplicate" the naming audit names, but
  which supersedes which is the owner's call — they differ in transport and error contract — and
  deleting one here would change the mirror's file set.  Delete on the NAS first, then refresh
  this mirror so the record stays truthful.

- The `nas-cpap-full.py` / `nas-cpap-unified.py` pair: `full` was the dead stub **deleted** under
  card `8dda5918` (see the divergence list above); `unified` is the env-reading one that remains.

**Reversal (card `307df479`):** if the owner decides the rename/delete is worth the mirror
divergence, rename the NAS file and its cron reference first and refresh; the new names then
become the mirror's, and this section is removed.

## What runs (from `cron/openclaw-collectors.cron`)

`air-monitor-curl-collector.sh` (5 min) · `cpap-myair-collector.py` (daily 07:20) ·
`it500-influx-collector.py` (:07/:37) · `nas_health_collector.py --once`
(:02/:17/:32/:47) · `S35bt-mqtt-bridge start` (:03, watchdog) ·
`internet-quality-monitor.sh` (:09) · `glowmarkt-collector.py` (*/30).
