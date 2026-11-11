# inspection.md audit — 2026-11-11, §1 Pre-Flight and §2 Security (items 1.1–2.3.7)

- **Commit audited:** `727bacaf76aad16e6b6d7f64b17f1048f81a98fe` — `git rev-parse HEAD`, checked before any probe.
- **Date:** 2026-11-11 (Europe/London).
- **Method:** the commit was exported with `git archive 727bacaf | tar -x -C <tmp>`; every file probe ran against
  that export, not the live worktree, which carried another lane's uncommitted edits at audit time. Every count was
  re-derived from the export; none was carried forward from the document. Live-box items (1.13, 2.3.7) ran
  read-only against this box. Corpus = 261 files: loaders, `scripts/*.sh`, `tools/*.sh`, `tools/hooks/*`,
  `tools/qwen-hooks/*.sh`, `bin/*`, `nas/**/*.sh`, `tests/**/*.bats`. Each section ends with the control that
  proves its probes can fail. FAILs are recorded, not repaired: this pass edited no source file.
- **Items measured: 27** — 13 in §1 and 14 in §2 up to 2.3.7. The brief said 42; the document holds no items
  between 2.3.7 and 2.4, and §2.4–2.6 are outside the requested range.
- **HEAD moved mid-pass.** It was `727bacaf` when the pass started and is `3dd9c532` now (a peer's commit on top,
  touching `bin/autotune-rows.sh`, `tools/ratchet-baseline.tsv` and `.agents/skills/`). The export froze the audited
  tree, so no measurement below describes the newer commit — which is the point of the freeze rule.

## §1 Pre-Flight

| Item | Disposition | Command (or citation) | Measured |
|---|---|---|---|
| 1.1 | PROCEDURE | `wc -l <file>` | Works; `tactical-console.bashrc` = 371 lines. Right instruction. |
| 1.2 | HOLDS | `grep -n '_TAC_LOADER_VERSION=\|TACTICAL_PROFILE_VERSION=' tactical-console.bashrc`; `grep '^# Module Version:' scripts/*.sh` | Loader `_TAC_LOADER_VERSION="13"` :76, `TACTICAL_PROFILE_VERSION` computed :267. 16/16 canonical modules carry the marker, 0 missing. |
| 1.3 | HOLDS | `grep 'AI INSTRUCTION' <loader/module>` | Loader :5 and :69; 16/16 modules carry it. (Corpus-wide 149/261 lack it — outside this item's stated scope.) |
| 1.4 | PROCEDURE | `git status --short` | Still right. Measured 3 dirty paths, another lane's (`bin/autotune-rows.sh`, `tools/ratchet-baseline.tsv`, `.agents/hooks/`) — why the pass used an export. |
| 1.5 | PROCEDURE | `git stash` / `cp <file> <file>.bak` | Right in intent; `git stash` on a shared worktree would stash a peer's work. `git archive <commit>` is the safe form today. |
| 1.6 | FAILS | `head -1 <file>` ×261 | 104 `env bash`, 3 `/bin/bash`, 28 `shellcheck shell=bash`, 11 nas `/bin/sh`. `tools/hooks/_kgraph-auto-rebuild` has neither shebang nor directive. nas count is 11, not the stated 12 (11 at 2026-10-25 too). |
| 1.7 | PROCEDURE | `shellcheck -s bash -x --source-path=$PWD <file> 2>&1 \| grep -c 'In '` | Sound: 0 on a clean file, 1 on a fixture with one finding. Right instruction. |
| 1.8 | HOLDS | `file -b <file>` ×261 | 0 BOM. 28 "UTF-8 Unicode text", 233 ASCII/other; none "with BOM". |
| 1.9 | HOLDS | `grep -Pc '\r' <file>` ×261 | 0 files with a carriage return. |
| 1.10 | HOLDS | `tail -c 1 <file> \| xxd -p` ×261 | 0 files missing the final `0a`. |
| 1.11 | FAILS | last non-blank line must name `end of file` | 93/261 lack it: 15 nas + 2 `tools/hooks` (the gaps the item names), plus 71 `tests/*.bats` and 5 extensionless `bin/` entry points it never scopes. 0 within the stated automated scope. |
| 1.12 | FAILS | `grep -rn 'shellcheck disable'`; rationale on same or previous line | 25 sites; 3 undocumented: `load-vault-env.sh:202`, `18-lint.sh:21`, `bench-timeout-runner.sh:120`; a 4th (`_tac-bin-lib.sh:294`) only covered by its sibling's block. File-level lists minimal: removing env.sh's and tactical-console.bashrc's reports exactly SC1090,SC1091. |
| 1.13 | FAILS | `ls -la /usr/bin/bash /usr/bin/bash.distrib; dpkg-divert --list \| grep usr/bin/bash; dpkg --verify bash` | No symlink, no `.distrib`, no diversion. `/usr/bin/bash` is the packaged `bash 5.3-2ubuntu1` (`dpkg -S` says so), `dpkg --verify` silent. The described Homebrew arrangement does not exist on this box. |

**Section controls — §1:** (a) `file -b` on a BOM fixture → "UTF-8 (with BOM) text"; (b) `grep -Pc '\r'` on a CRLF
fixture → 2; (c) `tail -c 1` on a fixture with no final newline → `65`; (d) the 1.11 probe flags a fixture whose last
line lacks the marker; (e) the 1.12 probe flags a synthetic directive with no rationale; (f) the 1.2 probe reports
MISSING on a module copy without the marker; (g) `ls /usr/bin/bash.distrib` errors, so 1.13 reports absence rather
than silence.

## §2 Security — Critical (2.1–2.3.7)

| Item | Disposition | Command (or citation) | Measured |
|---|---|---|---|
| 2.1.1 | HOLDS | stated regex ×261 | 1 hit, a comment (`tactical-console.bashrc:16`); 0 code. |
| 2.1.2 | HOLDS | `grep -n '\beval\b'` ×261 | 39 hits, 33 non-comment, each verified: trap restore, fd dup, `direnv hook`, test harnesses, help prose. `bin/gh:94` evals a line from a cache it mode-checks 600 first. |
| 2.1.3 | HOLDS | stated anchored regex ×261 | 301 sites (doc's 100 is dated 2026-09-18). Targets are `$REPO_ROOT/…`, `$1`, `$cache` — repo paths, none remote. |
| 2.2.1 | HOLDS | stated regex; `gitleaks dir . --redact` (pinned 8.30.1) | 1456 keyword hits, all env reads, redaction patterns or warnings; gitleaks: no leaks. |
| 2.2.2 | HOLDS | stated regex; gitleaks | 25 long alnum runs, all CamelCase identifiers or SHA-256 checksums; no key-shaped literal. |
| 2.2.3 | HOLDS | `stat -c '%a %U %n'` on the stores; grep the reads | `tac_win_api_keys` 600, `~/.qwen/.env` 600, `openclaw.json` 600; `~/.openclaw/secrets.env` absent, loader guards with `[[ -f ]]`. Reads are env vars / 0600 files. |
| 2.2.4 | HOLDS | `grep -nE 'set -x\|set -o xtrace'` ×261 | 0 hits. |
| 2.3.1 | HOLDS | `grep -n '\bsudo\b'` ×261 | 83 non-comment sites; 0 unindented/top-level; all inside functions, message strings, or tests' stubs. |
| 2.3.2 | HOLDS | `grep -nE 'chmod 777'`; `grep -nE 'chmod a\+rwx'` | 0 real: 1 comment (`tactical-console.bashrc:17`) + 1 regex literal at `post-edit-check.sh:160` (doc says 137). |
| 2.3.3 | HOLDS | `grep -n 'chown root'` ×261 | 0 hits. |
| 2.3.4 | FAILS | stated probe ×261 | 45 sites, not 21: 28 in `autotune-model.sh` (doc: 18), 1 in `11f-llm-runtime.sh:235` (doc: 302), 15 tests, 1 nas. `11b`'s site is gone; `11e` now writes behind `${LLM_MODELSHELL_PID_DIR:-/tmp}` at :2523 (doc: 1202) — a form the probe cannot see. |
| 2.3.5 | HOLDS | stated 3-branch regex ×261 | 0 sites against 267 chmod/umask lines (doc says 17). |
| 2.3.6 | HOLDS | `grep -n 'umask 077\|chmod 600'` ×261 | 35 sites; every credential cache (`tac_win_api_keys`, token files, `.env` drop-ins) is 600/077. |
| 2.3.7 | FAILS | `ls -la /dev/shm/tac_*` | 11 files, all owned by wayne; 5 are `664` (`tac_gog_ok`, `tac_openclaw_ok`, `tac_win_api_key_names`, `.hash`, `.resolved`), not the required 600/644. |

**Section controls — §2:** (a) 2.1.1 and 2.2.4 on synthetic fixtures → 1 each (both greps fire); (b) 2.3.5's
9 must-match and 10 must-not-match samples all as predicted; (c) `gitleaks dir` on a fixture with a synthetic AKIA
key → "leaks found: 2", exit 7 (AWS's published example key did *not* fire — gitleaks allowlists it, so the control
had to use a non-example key); (d) 2.3.4's synthetic `> /tmp/x` → 1; (e) `ls /dev/shm/*.suspend` → "No such file or
directory", proving the 2.3.7 glob reports absence.

## §2 Security — Critical (2.4–2.6), audited at `30fe9812`

Frozen at `30fe9812` (`fix(ci): one import identity per module, and the typed-test errors mypy found`) and
exported with `git archive`. HEAD was `08b8b1cc` when this chunk started — one commit past the target, this
audit's own §1/§2 commit — so every measurement below describes `30fe9812`, not HEAD. No live-box reading is
used in this section.

| Item | Disposition | Command (or citation) | Measured |
|---|---|---|---|
| 2.4.1 | HOLDS | `grep -n 'PATH=.*:\.:'` ×261 | 0 matches. |
| 2.4.2 | HOLDS | `grep -n 'pkill -f' \| grep -v comment` | 0 code; 3 comments (`autotune-model.sh:787`, `interview-benchmark.sh:12`, `tests/tactical-console.bats:2383`). The doc's `:415` is stale. |
| 2.4.3 | HOLDS | `grep -n 'kill \$('` ×261 | 0 matches. |
| 2.4.4 | FAILS | `grep -n 'pkill' \| grep -v comment` | 14 mentions, 6 without `-u`; 1 real invocation: `tools/hooks/pre-push:115` (`pkill -TERM -P "$GATE_PID"`), scoped by parent pid, not `-u`. The doc's "every real invocation carries -u" is false. |
| 2.4.5 | FAILS | inspect each pkill site | 6 real sites: 1 pgrep-verifies (`autotune-model.sh:791`), 3 sleep only, 2 neither (`09f-oc-misc.sh:577`, `pre-push:115`). |
| 2.5.1 | HOLDS | `grep -nE '\$@\|\$\*' \| grep -v '"'` | 0 unquoted on non-comment lines. |
| 2.5.2 | FAILS | `grep -nE '\[\[.*\$[a-zA-Z]'` | 4951 matches — every `[[ … $var … ]]`, quoted or not; a correctly-quoted `[[ -n "$x" ]]` matches (control). The rule is also wrong for `[[ ]]`: no word splitting, and patterns must stay unquoted. |
| 2.5.3 | FAILS | `grep -n 'printf.*\$'` | 1949 matches (every `printf … "$var"`); 20 sites put a variable in the format string (colour tokens, e.g. `05-ui-engine.sh:283`). |
| 2.5.4 | HOLDS | `grep -nE 'rm.*\$\|mv.*\$\|cp.*\$'` | 819 matches, quoted and unquoted alike; re-derived: 0 unquoted path variables. |
| 2.5.5 | HOLDS | `grep -n '\bread\b' \| grep -v '\-r'` | 146 hits, all prose ("cannot read"); every real call is `read -r` (335) or `read -ra` (8). |
| 2.5.6 | HOLDS | `grep -n 'IFS='` | 279 sites; 5 bare assignments, all `local IFS=` or a restore (`11e-llm-model.sh:4238`). |
| 2.6.1 | FAILS | `grep -nE '> .*\$\|>> '` | 1904 matches — a census, not a check (an atomic `> "$f.tmp" && mv` matches too, control). Re-derived: 1 direct shared-state write, `09d-oc-agents.sh:2200`. |
| 2.6.2 | FAILS | timer → unit → ExecStart, then `grep flock` | 12 timers; 7 of 9 in-repo targets have no flock/lockfile, including `autotune-resume.sh`, run by BOTH `autotune-resume.timer` (OnBootSec=2min) and `autotune-resume-keeper.timer` (every 15 min). |
| 2.6.3 | FAILS | inspect `.pid` readers | `11d-llm-gpu.sh:199` checks `kill -0` before trusting; `11e-llm-model.sh:2915-2925` signals the recorded pid with no liveness check, so a reused pid would be TERMed. |
| 2.6.4 | NOT-RUN | inspect `[[ -f ]]` then act | 383 check-then-act sites; the 8 credential/lock ones sampled are all `if [[ -f ]]; then …` with a window. A per-site review is what would settle it. |

**Section controls — §2.4–2.6:** (a) 2.4.1 on a synthetic `PATH="$PATH:.:/bin"` → 1; (b) 2.4.3 on a synthetic
`kill $(pgrep -f x)` → 1; (c) 2.5.1 on a synthetic unquoted `$@` → 1; (d) 2.5.2's control *is* the finding — a
correctly-quoted `[[ -n "$x" ]]` matches the stated probe → 1; (e) 2.6.1's control — a synthetic atomic
`> "$f.tmp" && mv` matches the stated probe → 1, proving it cannot tell atomic from direct.

## §3 Safety — Critical, audited at `30fe9812`

Same frozen export as §2.4–2.6. No live-box reading is used in this section.

| Item | Disposition | Command (or citation) | Measured |
|---|---|---|---|
| 3.1 | HOLDS | `grep -n "case \$- in"` | 4 hits: 2 profile guards (`tactical-console.bashrc:57`, `14-wsl-extras.sh:168`), 1 echo (`12-dashboard-help.sh:576`), 1 test (`tests/tactical-console.bats:68`). The doc's 3 hits / 2 guards and its line numbers are stale; the substance holds. |
| 3.2 | HOLDS | `grep -nE 'nohup\|&$\|disown'` | 11 nohup/disown sites, all inside functions (`07-telemetry.sh:81` in `__tac_track_bg_job`, `09f:128` in `oc-kgraph`, `11e:2507` in `__model_use_launch_server`) or standalone nas scripts. |
| 3.3 | HOLDS | `head -10` per file class | Loader + 16 modules: no `set -euo`. `install.sh:62` yes. 8 `bin/*.sh` yes (MAY). `tools/lint.sh:86` has `-e`; `tools/run-tests.sh:28` is `set -uo` with the stated reason at :25-27. |
| 3.4 | HOLDS | `grep -nE "trap .*[[:space:]]ERR"` | 1 ERR trap (`02-error-handling.sh:338`), and that file has `set -E`. |
| 3.5 | FAILS | `grep -n 'trap'` | 32 files trap EXIT; 19 have no INT/TERM trap, so their cleanup does not run on SIGTERM/SIGINT — bash does not run the EXIT trap for an untrapped signal. |
| 3.6 | HOLDS | `grep -n 'rm -rf.*\$'` | 29 shipped sites; 4 carry `:?`/`[[ -n ]]`; the rest are safe by construction (mktemp, literal globs, function-local state paths). The 3 riskiest inspected (`09f:521`, `pre-push:275`, `08-maintenance:158`) are guarded by `[[ -d ]]`, mktemp and `[[ -e ]]`. |
| 3.7 | HOLDS | `grep -nE 'rm -rf\|rm -f'` | 197 shipped sites; same finding as 3.6 — no unvalidated target found in the sample. |
| 3.8 | HOLDS | inspect `.bashrc` files | The loader has no `set -e` (3.3), and neither does `scripts/14-wsl-extras.sh`. |
| 3.9 | HOLDS | inspect the ERR handler | `02-error-handling.sh:__tac_err_handler` returns early for `__tac_last_err <= 1` ("Skip logging for exit code 1"). |
| 3.10 | HOLDS | `grep -n 'sudo'` | 39 non-`-n` sites, all `install.sh` (gated by `sudo -n true` at :645/:687) or `08-maintenance.sh`'s user-invoked `up`/loopback functions; every source-time-path sudo uses `-n`. |
| 3.11 | HOLDS | `grep -nE '&$\|&)'` | 27 sites; 10 capture `$!`; the rest are `&&` line continuations the probe misreads, disowned daemons (`setsid … &`), or subshells with a file handshake (`pre-push:224`). |
| 3.12 | HOLDS | inspect `while true` / `while :` | 17 sites; 14 bounded (counter, bound, `return`, `break`, `timeout`); 3 are daemons by design (`llm-idle-release.sh:191`, `standby-keeper.sh:35`, `mi-scale-autocollect.sh:72`). |
| 3.13 | HOLDS | `grep -nE '^ {0,4}(curl\|wget\|nc) '` | 2 curl sites, both inside functions (`_bench_spawn`, `metrics_pair`); no source-time network call. |
| 3.14 | HOLDS | inspect `pwsh.exe` / `typeperf.exe` | 3 pwsh invocations, all timeout-wrapped (`09d:738` and `:1116` `timeout 20`, `01-constants.sh:498` `timeout 2`). |

**Section controls — §3:** (a) 3.1 on a synthetic `case $- in` → 1; (b) 3.4 on a synthetic `trap … ERR` with no
`set -E` → 1 trap, 0 `set -E`; (c) 3.6 on a synthetic `rm -rf "$UNSET_VAR"` → 1; (d) 3.12 on a synthetic
`while true; do :; done` → NO-BREAK; (e) 3.5 on a synthetic EXIT-only trap → "EXIT-only detected".

## Summary

| Section | Items | HOLDS | FAILS | NOT-RUN | PROCEDURE |
|---|---|---|---|---|---|
| §1 Pre-Flight | 13 | 5 | 4 | 0 | 4 |
| §2 Security (to 2.3.7) | 14 | 12 | 2 | 0 | 0 |
| §2 Security (2.4–2.6) | 15 | 7 | 7 | 1 | 0 |
| §3 Safety | 14 | 13 | 1 | 0 | 0 |
| **Total** | **56** | **37** | **14** | **1** | **4** |
