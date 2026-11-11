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

## §4 Correctness & Clean Code — High, audited at `bee06f14`

Frozen at `bee06f14` (`docs(lint): give the three undocumented shellcheck disables a rationale`) and exported
with `git archive`. HEAD was `3f174955` when this chunk started — one commit past the target, this audit's own
§2.4–2.6/§3 commit — so every measurement below describes `bee06f14`. The §18.3 figures come from the repo's own
counter (`tools/count-ratchet.sh --list`), whose 10 controls pass (10/10, `--selftest`). `tools/lint.sh` in the
export passes every stage except two that need a git repository (count-ratchet and the CI gate), which is an
export artefact, not a finding.

| Item | Disposition | Command (or citation) | Measured |
|---|---|---|---|
| 4.1.1 | HOLDS | `bash -n <file>` ×147 | 0 failures. Control: `if then` → syntax error. |
| 4.1.2 | FAILS | `shellcheck -s bash -x --source-path=$PWD <file>` ×147 | 157 findings across 47 files, none of them error-severity; "zero at all severity levels" is unachievable per-file, as the doc's own 4.3.3 says. The canonical gate (module graph, 29 members) PASSES. |
| 4.1.3 | HOLDS | `shellcheck -S error` ×147 | 0 error-severity findings, so nothing is owed under "error = must fix"; 157 warning/info/style remain (4.1.2). |
| 4.1.4 | NOT-RUN | inspect awk/sed snippets | No extractor for embedded programs; running each against a fixture (or `awk --lint`) would settle it. |
| 4.1.5 | HOLDS | `grep -nE '\$\[\|\blet\b'` ×259 | 18 hits, all non-bash: JS `let` in heredocs (`qwen-memory-index-patch.sh`), a builtin-name case list (`05-ui-engine.sh:200`), a regex literal. 0 `$[` and 0 bash `let`. |
| 4.2.1 | FAILS | the item's `grep -nE` over `&&`/`\|\|` ×259 | 1716 matches — a plain `a && b` matches (control), so it is a census; the 167 real `&& … \|\| …` sites are mostly the braced `X && { a \|\| b; }` form the ratchet calls house style. |
| 4.2.2 | FAILS | inspect `;` chains | 3929 lines chain with `;`, 3213 of them the `; then`/`; do` idiom; no probe separates a two-command chain from that idiom. |
| 4.2.3 | HOLDS | shellcheck fall-through (SC2221/SC2222) | 0 findings across 147 files. |
| 4.2.4 | FAILS | `tools/count-ratchet.sh --list` §18.3 4.2.4 | 20 case blocks with neither a `*)` arm nor an explanatory comment. |
| 4.2.5 | FAILS | `grep -nE 'if .*;.*then'` | 1649 matches — every `if …; then`, the house form the ratchet deliberately does not ratchet. The rule would flag the idiom itself. |
| 4.2.6 | FAILS | `tools/count-ratchet.sh --list` §18.3 4.2.6 | 9 whole `for … do … done` loops on one line. |
| 4.2.7 | HOLDS | `grep -nE '(^\|[;&\|{][[:space:]]*)exit'` in the 16 sourced modules | 0 hits in modules; the 31 in `scripts/` are standalone entry points, which 3.3 permits. |
| 4.2.8 | HOLDS | nested `name() {` at indent | Nested helpers exist (`09d:563 _human`, `11e:3563 __bench_restore_traps`) and each carries a purpose comment; none captures an outer variable, so no dynamic-scoping note is owed. |
| 4.3.1 | FAILS | `grep -nE 'local [a-z_]+=\$\('` | 96 sites (SC2155): assign and declare on separate lines. |
| 4.3.2 | FAILS | `grep -nE 'for [a-z_]+ in \$[a-z_]'` | 14 unquoted-string iterations (e.g. `for p in $PATH` after `IFS=':'`), not arrays. |
| 4.3.3 | HOLDS | `tools/lint.sh` (module graph, 29 members) | PASS — and the per-file alternative's 157 findings are the SC2034/SC2154 noise the item warns against. |
| 4.3.4 | HOLDS | `grep '^function'` then count references | 0 functions in `scripts/*.sh` defined and never referenced. |
| 4.3.5 | NOT-RUN | inspect functions | ~1,000 functions; a per-function check of every assignment is needed. What would settle it: a shellcheck rule or an AST pass over assignments inside function bodies. |
| 4.3.6 | FAILS | `tools/count-ratchet.sh --list` §18.3 4.3.6 | 31 `local`/`declare` names in mixedCase. |
| 4.3.7 | NOT-RUN | inspect top-level assignments | Needs per-variable usage analysis (which function reads each global); no probe exists. Would settle: an AST pass mapping reads to enclosing functions. |
| 4.3.8 | HOLDS | `grep -n 'declare -i'` | 0 uses — the item is withdrawn and the repo matches the withdrawal. |
| 4.3.9 | HOLDS | `grep -n '\breadonly\b'` | 46 readonly declarations present (e.g. `10-deployment.sh:41 _COMMIT_MAX_TOKENS`). |
| 4.3.10 | HOLDS | `local NAME` also `^NAME=` in the same module | 0 shadowing pairs found across `scripts/*.sh`. |
| 4.3.11 | HOLDS | `grep -n 'OPENCLAW_ROOT'` | 2 sites: the alias at `01-constants.sh:204` under a 3-line DEPRECATION comment (:201-203), and a display line marked deprecated (`09e:1090`). |

**Section controls — §4:** (a) 4.1.1 on a synthetic `if then` → syntax error; (b) 4.2.1's control *is* its
finding — a plain `a && b` matches the stated probe; (c) the §18.3 counters' own 10 controls all pass
(`tools/count-ratchet.sh --selftest`: "10 counters, all controls pass"); (d) 4.3.4's reference check on a fixture
defining an uncalled function reports refs=1; (e) 4.3.10's shadow check on a fixture with `X=1` plus `local X=2`
reports the pair.

## §5 Robustness — High, audited at `bee06f14`

Same frozen export as §4. No live-box reading is used in this section.

| Item | Disposition | Command (or citation) | Measured |
|---|---|---|---|
| 5.1 | HOLDS | `grep -n 'command -v'` ×259 | 227 guard sites. |
| 5.2 | HOLDS | `grep -nE '\b(curl\|wget)\b '` then read the flags | 65 mentions; every real invocation carries `--max-time`/`--connect-timeout` (the one flagged line, `11e:5864`, has `--connect-timeout 10 --max-time 20` on its continuation). |
| 5.3 | HOLDS | `grep -n '\${[A-Za-z_][A-Za-z0-9_]*:-'` | 1351 defaulted expansions. |
| 5.4 | FAILS | `grep -nE '(echo\|printf)[^;]*(\[FAIL\]\|Error:\|ERROR:)' \| grep -v '>&2'` | 18 hits; the styled UI lines are the documented exemption, but standalone scripts emit diagnostics on stdout (`autotune-model.sh:533`, `run-autotune-batch.sh:109`, `bin/autotune-resume.sh` ×6). |
| 5.5 | HOLDS | `grep -nE '\|\| (exit\|return)\|if ! '` | 744 checked-failure sites. |
| 5.6 | FAILS | `grep -nE '\(\([^)]*/[[:space:]]*[a-z_]'` | 16 variable-divisor sites; 2 guard with a `> 0 ?` ternary (`11e:1079`, `11e:1144`), the rest assume non-zero (`11d:1592`, `11e:1878`, `11f:318/660`). |
| 5.7 | HOLDS | `grep -n '\$(<'` then read the guard | 45 shipped reads, 40 behind `-f/-s/-r`; the 5 unguarded ones handle the failure explicitly (`\|\| return 0`, `\|\| var=""`) or read a proc file. My first pass counted 13 — it missed `-r` guards. |
| 5.8 | HOLDS | `grep -nE '^[[:space:]]*cd ' \| grep -v '\|\|'` | 20 unguarded `cd`s; the shipped ones are in `set -euo` scripts (`check-repo-boundaries.sh:9`, `nas-iot-bootstrap.sh:51`), and `11e:2481` is the documented stdin-keeper case where exiting is worse. |
| 5.9 | HOLDS | `grep -n 'pipefail'` | No sourced module SETS it; `04-aliases.sh` uses `${PIPESTATUS[0]}` at :153 and :238 (doc's :212 is stale). |
| 5.10 | HOLDS | inspect the one curl call | `11e:5862-5866` checks the result (`\|\| result=""`) and parses the trailing `http_code`. |
| 5.11 | FAILS | `grep -n '\bjq\b '` | 74 jq calls, 30 with the stated `2>/dev/null`; 44 rely on the caller's `\|\|`/empty check instead. |
| 5.12 | HOLDS | `grep -nE 'pwsh\|typeperf'` | 3 same as 3.14: every invocation is `timeout`-wrapped (`09d:738`, `09d:1116`, `01-constants.sh:498`). |
| 5.13 | HOLDS | `grep -nE '\[\[ -s \|stat -c%s\|wc -c'` | 20 size/validity checks on cache reads; `11e:5281` treats an unreadable lock as empty rather than trusting it. |
| 5.14 | HOLDS | `grep -n 'mkdir -p'` | 473 sites; the writer creates its parent before writing in the sampled paths. |

**Section controls — §5:** (a) 5.2 on a synthetic `curl http://x` with no timeout flag → 1 (the flag check can
fire); (b) 5.4 on a synthetic `echo "ERROR: x"` → 1; (c) 5.7 on a synthetic `x=$(< /nonexistent)` with no guard →
UNGUARDED; (d) 5.9's module check was run against a copy of a module with `set -o pipefail` added, and found it.

## §6 Efficiency & Native Bash, audited at `ba8708c9`

Frozen at `ba8708c9` (`test(hermetic): pin the CPU identity and resolve the interpreter`) and exported with
`git archive`. HEAD was `9a6216c4` when this chunk started — one commit past the target, this audit's own §4/§5
commit — so every measurement below describes `ba8708c9`. **§6 has no 6.6** (the document runs 6.5 → 6.7), hence
12 items. Counts are over the 146 shipped shell files unless a row says otherwise; the doc's dated figures
(2026-09-18, `f7403d24`) are compared against today's tree, which has grown.

| Item | Disposition | Command (or citation) | Measured |
|---|---|---|---|
| 6.1 | FAILS | `grep -nE '\b(sed\|awk\|grep)\b' \| grep -v comment` | 529 shipped sites (1832 with tests) against the doc's 228 at `f7403d24`. The doc calls this a migration backlog, not a defect — recorded as backlog. |
| 6.2 | FAILS | `grep -nE '\bcat [^\|]*\|[[:space:]]*[a-z]'` | 4 hits: 2 false positives (`journalctl --output=cat`, a usage comment), 1 nas message, and the genuine UUOC the doc names — still present, now at `cache-ram-probe-watch.sh:127` (doc says :118). |
| 6.3 | FAILS | `grep -nE '^[[:space:]]*\([^(]'` | 77 hits, but the sample is embedded jq/SQL (`.agentId // …`, `(name,)`), not subshells — a jq line matches too (control). Census, not a check. |
| 6.4 | HOLDS | the item's anchored `while … read` probe | 173 shipped sites: 63 whole-line, 60 field-splitting. The item was closed by reading the sizes (1–45 lines); nothing large was found then, and none appears now. |
| 6.5 | HOLDS | `grep -nE '\bpython3?\b\|\bperl\b\|\bnode\b'` | 151 mentions; 16 `python3` at command position (JSON templating). Core logic stays native. |
| 6.7 | FAILS | `tools/count-ratchet.sh --list` §18.3 6.7 | 106 `[ … ]` tests; baseline 106, so the ratchet is AT its baseline. This is the doc's threshold, not a new defect. |
| 6.8 | FAILS | `grep -nE '\[\[.*[[:space:]]-(gt\|lt\|ge\|le\|eq\|ne)[[:space:]].*\]\]'` | 305 sites against the doc's 232. The doc itself concludes the swap saves nothing (both are builtins, behaviour identical) — threshold, not defect. |
| 6.9 | FAILS | item's `grep -nE 'echo.*\|'` vs the doc's awk probe | 188 vs 84 (91 with tests). The item's own command is a census — the doc says so, and the two figures agree with its finding; 84 real `echo … \| cmd` sites remain. |
| 6.10 | HOLDS | `grep -n 'echo -e'` | 0 sites. |
| 6.11 | HOLDS | `grep -nE '\bmktemp\b' \| grep -v comment` | 40 sites (49 raw). The item's precondition ("consumed once") was read; 39 are `-d`, atomic-replace or multi-write, as the doc records. |
| 6.12 | HOLDS | `grep -n '\bdu\b'` | 4 sites, none on a `/mnt/*` drvfs path (`/var/cache/apt`, model dir, store, a log string). |
| 6.13 | FAILS | the item's per-file lookup loop | 36 (file, lookup) pairs repeat (153 call sites) against the doc's 23/100. The doc's own read found the premise fails for `command -v` (a builtin, 20 of 23) — threshold, not defect. |

**Section controls — §6:** (a) 6.2 on a synthetic `cat f | grep x` → 1; (b) 6.10 on `echo -e "x"` → 1; (c) 6.3 on
a synthetic `( cd /tmp; ls )` → 1 *and* on a jq line → 1, which is the finding: the probe cannot tell them apart;
(d) the §18.3 counters' 10 controls pass (`--selftest`).

## §7 Portability, audited at `ba8708c9`

Same frozen export as §6. No live-box reading is used in this section.

| Item | Disposition | Command (or citation) | Measured |
|---|---|---|---|
| 7.1 | HOLDS | `head -1 <file>` ×260 | 0 absolute-interpreter shebangs (`#!/home/…`, `#!/usr/local/…`), and no file lacks both a shebang and `# shellcheck shell=bash`. |
| 7.2 | FAILS | `grep -nE 'stat -c\|find.*-printf\|date \+%s%N\|readarray\|mapfile'` | 89 sites; 0 carry a GNU/Linux-only note within 3 lines. The item asks each be justified and documented. |
| 7.3 | FAILS | grep file headers for a bash minimum | 0 files state a minimum bash version, so nothing pins the 5.x features the repo uses (`${var@Q}`, `mapfile -d`). |
| 7.4 | FAILS | `grep -rnE '/mnt/[c-z]\|wslpath\|wsl\.exe\|clip\.exe\|pwsh\.exe'` | 129 sites, 116 with no `WSL_DISTRO_NAME` guard or `command -v …exe` probe within 5 lines. The sampled ones fail predictably (`timeout`, `2>/dev/null`, glob no-match); the item's stated two forms are what is missing. |
| 7.5 | HOLDS | `grep -nE '\.exe\b'` then read the calls | 33 real `.exe` invocations, 28 documented within 3 lines. The item's raw probe also matches `python-*.exe` globs — a census. |
| 7.6 | FAILS | `grep -n '/dev/shm'` | 61 uses; 3 carry a mount/WSL note within 3 lines. |
| 7.7 | FAILS | inspect `/mnt/` usage | 30 `/mnt/[c-z]` sites, 0 with a drvfs performance note within 3 lines. |

**Section controls — §7:** (a) 7.1 on a synthetic `#!/home/linuxbrew/.linuxbrew/bin/bash` → 1; (b) 7.2 on a
synthetic `stat -c %s f` with no comment → counted undocumented; (c) 7.5's probe on `python-*.exe` matches (the
census finding); (d) 7.6's note check on a `/dev/shm` line with no neighbouring comment → undocumented.

## §8 Style & Formatting, audited at `ba8708c9`

Same frozen export. Ratchet rows cite `tools/count-ratchet.sh --list`; the baseline equals the count for every
counter (the ratchet PASSES), so a FAILS here is the document's threshold, labelled as such.

| Item | Disposition | Command (or citation) | Measured |
|---|---|---|---|
| 8.1.1 | NOT-RUN | inspect visually | Blank-line placement is a visual judgement with no probe; a per-file sample read would settle it, and nothing in this pass did. |
| 8.1.2 | HOLDS | `grep -n '\[\[\$'` | 0 sites: no `[[$a==$b]]` compression. (A broader probe matches regex literals like `[[:space:]]` — a census.) |
| 8.1.3 | HOLDS | `grep -rlP '\t'` | 1 file: `tests/unit/24-contracts-guards.bats`, whose 4 tabs are literal tab characters inside expected-output strings, not indentation. 0 tab-indented lines. |
| 8.1.4 | HOLDS | `grep -Pn ' +$'` | 0 lines with trailing whitespace across 260 files. |
| 8.1.5 | FAILS | `grep -nE ';.*fi$'` | 119 lines against the doc's 48. Threshold, not a new defect. |
| 8.1.6 | FAILS | `tools/count-ratchet.sh --list` §18.3 4.2.6 | 9 one-line `for … do … done` loops, baseline 9 (at baseline). The item's own `;.*done$` returns 26 — a looser shape. Threshold. |
| 8.1.7 | FAILS | the item's `&&` / `\|\|` grep (same pattern as 4.2.1) | 1716 matches: a plain `a && b` matches, so the command is a census, not a test for `cmd && ok \|\| fail`. Threshold. |
| 8.1.8 | FAILS | `tools/count-ratchet.sh --list` §18.3 8.1.8 | 287 non-comment lines over 120 chars, baseline 287 (at baseline). Threshold. |
| 8.1.9 | HOLDS | `grep -n '<<-'` | 0 occurrences; heredoc bodies are space-indented with the delimiter at column 0. |
| 8.2.1 | FAILS | `grep -cE '^function '` and `grep -cE '^[a-z_][A-Za-z0-9_]*\(\)'` | 450 `function` and 941 bare `name()` — and **6 files mix both** (`01-constants.sh` 3/1, `11b-llm-autotune.sh` 23/1, `11d-llm-gpu.sh` 29/1, three tests). The doc claims no file mixes the two. |
| 8.2.2 | HOLDS | `grep -rhoE '(readonly\|export) [a-z][A-Za-z0-9_]*='` | 0 non-UPPER constant declarations. |
| 8.2.3 | FAILS | `tools/count-ratchet.sh --list` §18.3 4.3.6 | 31 mixedCase `local`/`declare` names, baseline 31 (at baseline). Threshold. |
| 8.2.4 | HOLDS | `grep -hoE '^# (=+\|═+\|─+)'` | One dominant divider form (192 `# ===…` rules); the lengths vary with the title, not the format. |
| 8.2.5 | HOLDS | `grep -nE '^\{'` | 28 `^{` lines, 0 of them following a function signature — they are block groupings (`{ … }` redirects). No Allman-brace function. |
| 8.2.6 | HOLDS | command-position probe over `rm`/`cp`/`mv`/`cd`/`mkdir` | 2 hits, both `mkdir -p $VAR` inside a printed message string, not an executed command; 0 unquoted path arguments. |

**Section controls — §8:** (a) 8.1.4 on a fixture ending in spaces → 1; (b) 8.1.9 on `cat <<-EOF` → 1; (c) 8.1.3
on a tab-indented fixture → 1; (d) 8.2.1 on a fixture with one `function` and one bare `name()` → both counters
read 1, so a mixed file is detectable.

## §9 Documentation & Future-Proofing, audited at `8083d981`

Frozen at `8083d981` (`fix(watch): read the cycle ledger with awk instead of cat | awk`) and exported with
`git archive`; the worktree was clean and HEAD equals this commit, so the venv-dependent tools ran against the same
tree. 148 shipped shell files, 20 docs, 112 BATS suites.

| Item | Disposition | Command (or citation) | Measured |
|---|---|---|---|
| 9.1 | HOLDS | `head -20 <file>` ×148 | 147 of 148 carry a header block with purpose + `# Module Version:` and dated version entries. No `author:` field is used anywhere — the house convention, not a gap. |
| 9.2 | HOLDS | comment-line vs code-line census | 22,732 comment lines against 34,176 code lines (40%), and the samples read in this audit explain *why*. |
| 9.3 | NOT-RUN | inspect complex Bashisms | Requires reading each fd-manipulation/regex site; a per-site sample read would settle it and none was done. |
| 9.4 | HOLDS | `ls scripts/[0-9][0-9]-*.sh \| grep -v 18-lint.sh`; `__tac_module_list` | 16 profile modules: 15 numbered + `09b-gog.sh`, exactly matching `_module-list.sh`'s 16. The doc's "the glob returns 17" is stale — it returns 16 (15 + `18-lint.sh`). `tools/*.sh` is 26, not the stated 21. |
| 9.4.1 | HOLDS | `tools/check-contracts.sh modules` | OK — 27 load positions, 95 declared `@depends` edges, 15 `@uses`, **0 disagreements, 0 cycles**. |
| 9.4.2 | HOLDS | `grep '^# Module Version:'` ×16 | 16/16 modules carry it, plus `@modular-section` and `@depends`; `tools/check-module-versions.sh --worktree` reports 0 unbumped modules. |
| 9.4.3 | HOLDS | `grep -c '_module-list'` | 5 references in each loader; neither globs `scripts/`. |
| 9.4.4 | FAILS | non-comment lines of `tactical-console.bashrc` | 113 lines. The item's enumeration omits the **10-line `mktemp` + `exec 8>&1 9>&2` output-hold block** and `HOMEBREW_NO_PATH_SHADOW_CHECK`, so "nothing else" is false. |
| 9.5 | FAILS | `tools/count-ratchet.sh --list` §18.3 9.5 | 116 function definitions with no comment directly above; baseline 116 (at baseline). Threshold. |
| 9.6 | FAILS | `grep -nE '\[\[.*=~'` | 476 sites; 132 have a comment within 2 lines. |
| 9.7 | FAILS | `tools/count-ratchet.sh --list` §18.3 9.7 | 79 literal exit/return codes other than 0/1 with no comment; baseline 79 (at baseline). Threshold. |
| 9.8 | NOT-RUN | inspect global writes in functions | Needs a per-function dataflow pass (which globals each function writes); none exists in the repo. |
| 9.9 | HOLDS | `grep -nEi '\b(TODO\|FIXME\|HACK)\b'` | 5 hits, all inside the two hygiene tests that assert their absence (`tactical-console*.bats`); 0 in shipped code. |
| 9.10 | HOLDS | `ls CHANGELOG*`; `git log` | No CHANGELOG exists, as the item requires; commit subjects carry the why. |
| 9.11 | HOLDS | `ls docs/*.md .agents/decisions/*.md` | 20 documents, including 7 decision records under `.agents/decisions/`. |

**Section controls — §9:** (a) 9.4's module count cross-checked against `_module-list.sh` (16 = 15 + 09b, and the
glob is 16 — the two agree only because `18-lint.sh` is excluded); (b) 9.9's probe on a fixture containing a real
`# TODO` line → 1, so the zero in shipped code can go red; (c) 9.6's comment window on a fixture with no comment → 0.

## §10 Refactor & Maintainability, audited at `8083d981`

Same frozen export. Ratchet rows cite `tools/count-ratchet.sh --list` (baseline equals count; the ratchet PASSES).

| Item | Disposition | Command (or citation) | Measured |
|---|---|---|---|
| 10.1 | FAILS | 5-line-block duplication scan over 148 files | 74 distinct normalised 5-line blocks occur 3+ times. |
| 10.2 | FAILS | `grep -nE '[^0-9][0-9]{5,}[^0-9]'` | 121 literals outside an UPPER_CASE assignment (`/ 1000000` in a timing divide, `86400` in comparisons, `18789` port defaults). |
| 10.3 | FAILS | `grep -c 'dry-run\|DRY_RUN'` | 11 files offer a dry mode; `install.sh` (0) and `tools/clean-orphans.sh` (0) — the two most destructive — do not. |
| 10.4 | FAILS | `tools/count-ratchet.sh --list` §18.3 10.4 | 41 functions over 100 lines; baseline 41 (at baseline). Threshold. |
| 10.5 | NOT-RUN | inspect nesting | The item needs an AST; an indentation proxy finds 750 lines at ≥20 spaces (worst `11e-llm-model.sh`, 196) but cannot tell nesting from heredoc content. |
| 10.6 | FAILS | `grep -nE 'localhost:[0-9]+\|127\.0\.0\.1:[0-9]+\|https?://'` | 18 inline endpoints in functions (`api.ipify.org`, `cloud.r-project.org`, `huggingface.co`), not top-of-file constants. |
| 10.7 | FAILS | `tools/count-ratchet.sh --list` §18.3 10.7 | 252 hand-written `>&2` sites instead of a helper; baseline 252 (at baseline). Threshold. |
| 10.8 | HOLDS | `grep -nE '\bENABLE_[A-Z_]+\b'` | 0 feature-flag variables. |
| 10.9 | HOLDS | `tools/check-contracts.sh modules` | 0 cycles, load order validated from `_module-list.sh`; the startup sequence is the documented list. |

**Section controls — §10:** (a) 10.8's probe on a fixture with `ENABLE_FOO=1` → 1; (b) 10.3's probe on a fixture
carrying `DRY_RUN` → 1; (c) the 5-line duplication scan against a fixture with one block repeated three times →
that block reported.

## §11 Testing & CI, audited at `8083d981`

Same frozen export; the Python tools ran in the repo's venv, whose tree equals this commit.

| Item | Disposition | Command (or citation) | Measured |
|---|---|---|---|
| 11.1 | HOLDS | `tools/lint.sh` usage header; `--staged` / `--files` arms | Three modes present (:468 `--staged`, the `--files` arm, and the whole-tree default); one place defines the shellcheck flags. |
| 11.2 | HOLDS | `ls tests/*.bats tests/unit/*.bats tests/integration/*.bats` | 112 suites; `tests/bats-suites.tsv` drives both bridges (41 rows, root + unit + integration families). |
| 11.3 | HOLDS | `tests/tactical-console-function-availability.bats` | Exists and runs — named in `nightly.yml:96`, not in ci.yml. |
| 11.4 | HOLDS | lint.sh syntax loop | Covers `tactical-console.bashrc`, `env.sh`, `install.sh`, `scripts/*.sh`, `tools/*.sh`, `tools/hooks/*`, `tools/qwen-hooks/*.sh`, `bin/*` — `.bashrc` and `.sh` both. |
| 11.5 | FAILS | `grep -c 'shellcheck disable'` + rationale check | 24 sites; 23 documented, 1 not (`bin/_tac-bin-lib.sh:294`, covered only by its sibling directive's block). The three the 2026-11-10 pass flagged are now fixed. |
| 11.6 | HOLDS | `tools/hooks/pre-commit` | Calls `tools/lint.sh --staged` (:59) and `tools/check-module-versions.sh`, not inline copies. |
| 11.7 | HOLDS | `grep -rn 'env -i' tests/*.bats` | `tactical-console-fast.bats:291-311`: `env -i` sourcing plus the `declare -F model` / `declare -F so` assertions — the half with teeth. |
| 11.8 | HOLDS | `.venv/bin/python3 -m ruff check scripts/kgraph/ scripts/oc-health-check.py tests/` | All checks passed. |
| 11.9 | HOLDS | the item's 16-file pytest command | 477 collected, **477 passed, 24 subtests passed** in 62 s. The doc's 463 is stale. |
| 11.10 | HOLDS | `scripts/kgraph/models.py` | `GraphNode.id: str = Field(..., min_length=1)` (:218); GraphEdge aliases and GraphBuilder dedup exercised by the passing suite. |
| 11.11 | HOLDS | `.github/workflows/ci.yml:420-470` | `python` job on `python-version: "3.14"`, running ruff, mypy, pyright and pytest. |
| 11.12 | FAILS | `ruff check --select BLE001,S110,S112` | **2 violations** at `scripts/oc-health-check.py:793`: `except Exception: pass`. |
| 11.13 | FAILS | `head -1 scripts/oc-health-check.py` | `#!/usr/bin/env python3`, not `.venv/bin/python`. |
| 11.14 | HOLDS | `config/concept-aliases.json`; `scripts/kgraph/constants.py` | The JSON exists and `load_concept_config()` (:82) is the single loader (:118 caches it). |

**CI suite census (the decisive evidence for 11.1–11.4):** 112 suites exist; **105 are named literally in
`ci.yml`** (102 unit/integration + 2 root + the integration block) and **7 are named only in `nightly.yml`** —
`05/06/07-spec-dec-*`, `08-autotune-workload`, `12-gpu-exclusivity`, `38-heavy-job`, and
`tactical-console-function-availability` (nightly.yml:87-96). Every suite runs in CI; the TSV is the bridge's
source of truth, not a runner list. No suite is orphaned.

**Section controls — §11:** (a) 11.5's rationale check on a fixture whose directive sits under a shebang first
returned **MISREAD** — `#!/usr/bin/env bash` was accepted as a comment — so the probe has a shebang blind spot;
re-run with shebangs excluded it still reports exactly 1 of 24 undocumented, and the only line-2 directive
(`env.sh:2`) carries inline prose. (b) 11.12's ruff selection is proven able to fail by the 2 real findings it
returns. (c) the CI census was cross-checked against `nightly.yml` — the 7 CI-unlisted suites are all found there,
so the "named literally" filter is not silently dropping them.

## §12 llama.cpp Integration, audited at `612a47ec`

Frozen at `612a47ec` (`fix(health): name the profile fallback and document the second SC2034`) and exported
with `git archive`. HEAD equalled this commit and the worktree was clean. 23 items; the profile/lane facts come
from `tools/box/profiles.py`, the launcher `scripts/11e-llm-model.sh` and the units under `systemd/`.

| Item | Disposition | Command (or citation) | Measured |
|---|---|---|---|
| 12.1.1 | HOLDS | `grep -n 'LLAMA_BUILD_VERSION' scripts/01-constants.sh` | :329 export, :331 `git rev-parse --short HEAD` with an `unknown` fallback, :333 the branch that uses it. Rendered by `model status` (`"build"` / `build=`). |
| 12.1.2 | FAILS | `grep -rn 'avx512\|avx2\|AVX' scripts/ bin/ tools/ config/` | **0 occurrences** anywhere. The CUDA half holds (`-DGGML_CUDA=ON` at `11e:5750`), but "AVX2/AVX512 detected and used" is absent — and on this aarch64 box neither ISA exists. |
| 12.1.3 | HOLDS | `grep -n 'function llm-build' scripts/11e-llm-model.sh` | `function llm-build()` at :5437, with v107–v117 changelog entries describing its rules. |
| 12.2.1 | HOLDS | `grep -rn -- '--jinja' scripts/ bin/ systemd/` | `cmd+=("--jinja")` at `11e:2208`, and every chat unit passes it (the Xe unit carries the 2026-09-18 why-comment). |
| 12.2.2 | HOLDS | `grep -rn -- '--flash-attn'` | Passed from the row/bench arguments (`autotune-model.sh:1732`, `spec_dec_crossover.sh:136`, `cache-ram-probe.sh:473`). |
| 12.2.3 | HOLDS | the item's three greps | Exactly **2** lines in `11e-llm-model.sh` (:2017 the `moe_offload_flag` assignment, :2019 the placement message); **0** in `systemd/`; **0** `override-tensor`/`--n-cpu-ffn`/`-ot`. The doc's figures reproduce exactly. |
| 12.2.4 | HOLDS | `tools/box/profiles.py`; `11e:2173` | **Re-checked, not quoted.** The shared-memory profile sets `gpu_layers=999` (:41) and `ngl_strategy="full_only"` (:52); the discrete profile sets `"ladder"` (:180). `11e:1846` records the old premise as wrong, and the launcher appends `--n-gpu-layers "$gpu_layers"` (:2173). The inversion is implemented. |
| 12.2.5 | HOLDS | `grep -rn 'load-mode'` | No `--load-mode mlock` anywhere, so the trade-off question is moot; the variant in use is `--load-mode none` (`autotune-model.sh:1723`), and the removed `--no-mmap` spelling appears 0 times. |
| 12.2.6 | HOLDS | `grep -rn -- '--no-context-shift'` | 0 occurrences, so the "if present, document why" condition does not fire. |
| 12.2.7 | HOLDS | `grep -rln -- '--reasoning' systemd/*.service` | **5 units** pin `--reasoning off` (minicpm5, xe-llama32, cuda-qwen35-pipeline, cuda-llama32, cpu-qwen25), matching the doc's five. No `--reasoning-budget` exists. |
| 12.2.8 | HOLDS | `grep -n -- '--batch-size\|--ubatch-size' scripts/11e-llm-model.sh` | :2171 passes both from the profile: 2048/512 on the shared-memory box, 512/256 on the discrete one (`profiles.py`). |
| 12.2.9 | HOLDS | `tests/unit/13-gguf-ctx-bounds.bats` | The suite pins GGUF-metadata parsing of the model's own context key (`general.context_length`, `<arch>.context_length`) against the rope-scaling original — the window is bounded by the model, not guessed. |
| 12.2.10 | HOLDS | `grep -rn 'cont-batching' scripts/ bin/ tools/ .github/` | 0 occurrences. `--parallel` is pinned to 1 with a warning (`kv_unified` off), as the doc records. |
| 12.3.1 | HOLDS | `grep -rn '/health'` vs `/v1/models` | 52 `/health` references, 4 `/v1/models`. The watchdog probes `/health` first (200 → ok, 503 → loading) and falls back to `/v1/models` only for an unrecognised code (`llama-watchdog.sh:377-383`); the 200+JSON pair is enforced at `11e:1804`. |
| 12.3.2 | HOLDS | `grep '/health' … \| grep -c connect-timeout` | 13 health curls carry `--max-time`; **0** carry `--connect-timeout` — exactly the doc's claim, and correct for loopback. |
| 12.3.3 | HOLDS | `grep -rn 'slots_idle\|slots_processing'` | 0 occurrences; the item is withdrawn and the tree matches the withdrawal. |
| 12.3.4 | HOLDS | `scripts/07-telemetry.sh` | TPS comes from the server's `/metrics` counters (`llamacpp:tokens_predicted*`) through awk arithmetic, so it is numeric by construction. |
| 12.3.5 | HOLDS | `grep -nE 'systemctl.*(stop\|restart)' bin/llama-watchdog.sh` | The watchdog delegates to `systemctl --user stop/restart` (:925, :1036, :1110), so systemd's SIGTERM → `TimeoutStopSec` → SIGKILL sequence applies; the unit file carries no override. |
| 12.4.1 | FAILS | `grep -rnE '\[\[ -(f\|r\|s) "\$…model…' scripts/11e-llm-model.sh` | No existence/readability or size check on the resolved GGUF before the command is built. The only guard is registry membership ("Model #N not found", :3170/:4581); the `-f` tests near the launcher are for the mmproj and the binary. Recorded as measured — not fixed. |
| 12.4.2 | HOLDS | `docs/llm.md:32` | The registry format is documented (`~/.llm/models.conf`, 48 columns) and parsed by `11a-llm-registry.sh`. |
| 12.4.3 | HOLDS | `ls config/quant-guide.conf config/hosts.d/*quant*` | Both guides exist and each profile names its own via `guide_rel_path` (`profiles.py`). |
| 12.4.4 | HOLDS | `grep -n 'load-mode' docs/llm.md` | `--load-mode none` is documented as the load-failed fallback at :95, :1443-1444 and :1617, with the `--no-mmap` removal noted. |
| 12.4.5 | FAILS | `bin/llama-watchdog.sh:153` | The watchdog records that it **cannot** drain: "every turn queued on it dies mid-request". A stop/switch errors in-flight turns rather than draining them — the item's expected behaviour, documented as absent. |

**Section controls — §12:** (a) 12.2.3's "expect ZERO" branch returns 2 in `scripts/` and 0 in `systemd/`, so the
filter both finds and clears; (b) 12.2.10's grep on a fixture containing `--cont-batching` → 1; (c) 12.3.2's
`connect-timeout` check on a fixture with a `/health` curl that carries it → 1; (d) 12.1.2's AVX grep on a fixture
containing `AVX2` → 1, which is what makes its zero a measurement rather than a blind pattern.

## §13 Cross-Script Consistency, audited at `612a47ec`

Same frozen export. Counts are over the shipped corpus (148 shell files) unless a row narrows it.

| Item | Disposition | Command (or citation) | Measured |
|---|---|---|---|
| 13.1.1 | HOLDS | `grep -rn 'LLM_PORT\|8081' scripts/ bin/ tactical-console.bashrc` | 4 code sites, all agreeing on 8081: the definition (`01-constants.sh:625`), two `${LLM_PORT:-8081}` fallbacks (`spec-decode-bench.sh:102,106`) and an `ss` grep (`run-autotune-batch.sh:257`). `oc-health-check.py` carries 18081, not 8081, as the doc corrects. |
| 13.1.2 | HOLDS | `grep -rn '/dev/shm/active_llm' \| grep -v 01-constants` | **0** outside `01-constants.sh`. |
| 13.1.3 | HOLDS | `grep -n 'LLAMA_.*SERVER_BIN='` | One source (`01-constants.sh:316,326,327`); the launchers repeat the default deliberately and `tests/unit/12-gpu-exclusivity.bats` asserts the two agree. |
| 13.1.4 | HOLDS | health-URL census | One form, `http://127.0.0.1:<port>/health`, with the port variable spelled `$LLM_PORT` / `$LLM_SERVICE_PORT` / `$_port` per lane — the intended two-port design. |
| 13.1.5 | HOLDS | `/dev/shm/` path census | Named files only (`llama-watchdog-cuda.suspend` 17 refs, `llm-idle-release.pid` 6, `autotune-cuda-cycles-` 10, …); no writer/reader disagreement. |
| 13.2.1 | FAILS | `grep -rhoE '"(ERROR\|Error\|error)[: ]'` | Three prefixes: `ERROR:` ×39, `Error:` ×12, `ERROR` (no colon) ×4. The dominant form is `ERROR:`, but 16 sites differ. |
| 13.2.2 | FAILS | `grep -rhoE 'exit [0-9]+' bin/*` | 0/1/2 dominate (68/61/35) but 2 is not one thing: `bin/fleet-model.sh` uses 2 for *refused* and 64 for usage, while others use 2 for usage; 3 (×12) and 4 (×7) have no shared table. |
| 13.2.3 | HOLDS | local `log`/`warn` helpers vs `_tac-bin-lib.sh` | 17 tools define their own helper and 10 `bin/` scripts source the shared lib — consistent with §18.3 10.7 (one stderr helper per tool), not drift. |
| 13.3.1 | HOLDS | `head -2 scripts/<module>.sh` | 16/16 carry `# shellcheck shell=bash`; no new file-level disables (24 disable sites repo-wide at this commit). |
| 13.3.2 | HOLDS | command-position unquoted-var probe | 2 hits, both `mkdir -p $VAR` inside a printed message string; 0 unquoted path arguments. |
| 13.3.3 | HOLDS | function-name prefix census | `__internal`/`_internal`/public split is uniform (`__autotune` 10, `_bench` 8, public `warn`/`usage`/`parse`). |
| 13.3.4 | HOLDS | `install.sh:275-282` | Every `bin/` file is linked into `~/.local/bin`, with a named `launcher` list for the ones that need an exec shim. |
| 13.4.1 | HOLDS | `for f in scripts/[0-9][0-9]-*.sh; do grep -q '^# Module Version:'` | 0 missing. |
| 13.4.2 | HOLDS | the item's AI-instruction loop | 0 missing. |
| 13.4.3 | FAILS | `grep -h '^# Module Version:' scripts/[0-9][0-9]-*.sh scripts/09b-gog.sh \| wc -l` | **20 lines, not one per module**: `01-constants.sh` has 3 (:5, :8, :10) and `04-aliases.sh` 2 (:5, :7). The loader sums every match, so the canonical sum **461** became **611** — `TACTICAL_PROFILE_VERSION` read 13.611 instead of 13.461. The defect the item records as fixed on 2026-10-25 had returned. **Fixed after this audit in `02d2b7db`**: 13 scripts (plus `env.sh`) carried their history as extra `# Module Version:` lines; they now hold one canonical line each and the loader reports 13.463. |
| 13.4.4 | HOLDS | `tactical-console.bashrc:221,255,267` | The composition is `<loader>.<sum>` and the sum is computed from every match — mechanism correct, value inflated at this commit by 13.4.3. |
| 13.4.5 | HOLDS | header-format check over the 16 modules | 16/16 carry the `# ─── Module:` divider, the AI block and the version line. |
| 13.5.1 | HOLDS | `grep -c 'continue' env.sh` | 2 (the `13-init.sh` skip and the PID-validation continue), and env.sh loads the 16 canonical modules from `_module-list.sh`. |
| 13.5.2 | HOLDS | `grep -n '__TAC_ENV_LOADED' env.sh` | :36 returns early when set, :37 sets it. |
| 13.5.3 | HOLDS | `grep -n '"\$@"' bin/tac-exec` | :112 `"$@" 2>&1` — arguments passed through unmodified. |
| 13.5.4 | HOLDS | `test -x bin/tac-exec` | OK. |
| 13.5.5 | HOLDS | the item's marker loop | Both `env.sh` and `bin/tac-exec` end with `# end of file`. |

**Section controls — §13:** (a) 13.1.2's "zero outside 01-constants" probe on a fixture that repeats the literal
in a second file → 1; (b) 13.4.3's duplicate detector on a fixture with two version lines → 2 (the check that
found the real defect); (c) 13.5.5's marker check on a file without it → the MISSING branch fires.

## §15 AI Agent Access, audited at `8343b7cc`

Frozen at `8343b7cc` (`test(guard): pin one Module Version line per canonical module`) and exported with
`git archive`; the worktree carried three unrelated in-flight shell edits, which the export excludes. The
`~/.local/bin` and `~/.openclaw` readings are **live-box state**, not commit facts, and are marked as such.

| Item | Disposition | Command (or citation) | Measured |
|---|---|---|---|
| 15.1 | HOLDS | `bash -c 'source env.sh && echo $__TAC_ENV_LOADED'` | Prints `1`, no stderr. |
| 15.2 | HOLDS | the item's `type oc … __test_port` chain | Prints `OK` — all eight functions defined. |
| 15.3 | HOLDS | `${__TAC_INITIALIZED:-unset}` | Prints `unset`; 13-init does not run in library mode. |
| 15.4 | HOLDS | source twice | Prints `OK`; :36 returns early on the second source. |
| 15.5 | HOLDS | `ls -la bin/tac-exec ~/.local/bin/tac-exec` | `-rwxr-xr-x` in-repo; `~/.local/bin/tac-exec` is a symlink to it (live). |
| 15.6 | HOLDS | `bin/tac-exec oc \| head -3` | Prints the `oc — OpenClaw Command Reference` header. |
| 15.7 | HOLDS | `bin/tac-exec model list \| head -2` | Prints the registry table header, multi-word args preserved. |
| 15.8 | HOLDS | `bin/tac-exec` with no args | Prints `Usage: tac-exec <command> [args...]`; **rc=1**. |
| 15.9 | FAILS | the item's six-wrapper loop (live) | `so`/`xo`/`serve` delegate OK, but `oc-backup`, `oc-model-list` and `oc-model-stop` **do not exist** in `~/.local/bin` — 3 of 6 absent. |
| 15.10 | FAILS | the item's `≤6 lines` loop (live) | One WARN: `~/.local/bin/oc-model-status` has **7 lines**, over the threshold the item sets. |
| 15.11 | HOLDS | `grep -c 'tac-exec' ~/.openclaw/workspace/TOOLS.md` | 5 (the item's floor is ≥5). Live. |
| 15.12 | HOLDS | source env.sh then test `$PROMPT_COMMAND` | Empty → `OK`; no interactive side-effect leaks. |
| 15.13 | HOLDS | `/usr/bin/time -f real=%e` around a source | **real=0.11 s**, well under the 1.0 s bound. |
| 15.14 | HOLDS | `[[ -d mcp-tools ]]` | Absent → `OK: removed`. |
| 15.15 | HOLDS | `env \| grep TAC_LIBRARY_MODE` | `TAC_LIBRARY_MODE=1`. |
| 15.16 | HOLDS | `env -i … PATH=/usr/local/bin:/usr/bin:/bin … tac-exec oc` | Prints the `oc` help header with no `~/.local/bin` on PATH. |

**Section controls — §15:** (a) 15.14's directory test on a fixture that *does* contain `mcp-tools/` → `FAIL:
exists`; (b) 15.15's `env | grep` on a shell without the variable → 0 lines; (c) 15.10's line-count loop flags a
7-line fixture, which is what makes its single WARN a measurement.

## §16 Final Validation, audited at `8343b7cc`

Same frozen export; 16.5 is live-box state.

| Item | Disposition | Command (or citation) | Measured |
|---|---|---|---|
| 16.1 | HOLDS | `bash -n tactical-console.bashrc` + every `scripts/[0-9][0-9]-*.sh` and `bin/*.sh` | rc=0 across all of them. |
| 16.2 | FAILS | `shellcheck -s bash -x --source-path=$PWD <loader + 16 modules>` | **38 findings** per-file, so "zero" is not met; the canonical module-graph pass (29 members) is clean, and §4.3.3 says a lone module's SC2034/SC2154 are its interface, not findings. |
| 16.3 | HOLDS | `bash -ic 'source tactical-console.bashrc; exit'` | rc=0 (the `tcgetpgrp`/job-control lines are interactive noise, not errors). |
| 16.4 | HOLDS | `model list`, `oc` from a library shell | `model list` prints the registry header (rc=0) and `oc` prints its reference. `m`/`h` are aliases (`04-aliases.sh:68,72`) but alias expansion is off in a non-interactive shell, so the item's own two alias examples cannot run there. |
| 16.5 | HOLDS | `systemctl --user status llama-watchdog.timer` | `active (waiting)`, last trigger 35 s before the read. Live. |
| 16.6 | HOLDS | `env -i HOME=$HOME bash --noprofile --norc -c 'source tactical-console.bashrc'` | rc=0, no stderr. |
| 16.7 | NOT-RUN | `bats tests/tactical-console.bats` | `grep -c '^@test'` = **397**; the suite was started on this box and reached **8 cases with 0 failures** in ~15 minutes before it was stopped — the leading static-analysis cases each re-run shellcheck over the corpus and take minutes under current load. A full run would settle it. |
| 16.8 | HOLDS | `ls scripts/[0-9][0-9]-*.sh \| wc -l` | **16** = 15 profile modules + `18-lint.sh`, with `_module-list.sh` naming 16 profile modules. |
| 16.9 | HOLDS | this file | The audit log is this document: one row per item with disposition, command and measurement, plus the FAILS list the parent has been triaging. |

**Section controls — §16:** (a) 16.1's `bash -n` on a broken fixture → rc=2; (b) 16.2's shellcheck on a fixture
with an unquoted variable → 1 finding; (c) 16.8's glob on a fixture directory holding two numbered files → 2, so the
count is derived rather than assumed.

## §17 New Insights & Standards, audited at `8343b7cc`

The items are dated field notes; each row measures whether the note still holds at this commit.

| Item | Disposition | Command (or citation) | Measured |
|---|---|---|---|
| 17.1 | FAILS | the item's `grep -rnE '# *noqa\|# *type: *ignore\|shellcheck disable=SC'` | **23 `shellcheck disable=` lines** against the doc's 20 at 2026-10-25 (+3, unattributed: the 2026-10-25 list is not in the repo), and 3 real `type: ignore[...]`/`noqa:` directives in tests (down from 8) plus 2 prose mentions. Every code is in a documented class (SC2154 8, SC1090 8, SC2034 4, SC2329 3, SC2317 3, SC2016 2, SC2221 1, SC2086 1, SC1091 1). The doc's "7 E402 path bootstraps" description is stale — none of the 3 is E402. |
| 17.2 | HOLDS | `grep -l '_module-list\.sh' env.sh tactical-console.bashrc` | 2 of 2; `tools/docs-sync-check.sh` derives the module count from the list (chunk 5, 16 OK). |
| 17.3 | HOLDS | the item's two negations | No `_tac_expected_modules=(` array in the loader and no `[0-9][0-9]-*.sh` glob in env.sh. |
| 17.4 | HOLDS | `grep -rnE '^[[:space:]]*exec [^0-9{]' scripts/*.sh tactical-console.bashrc` | 7 hits, **none in a function body**: 3 inside heredocs that generate pwsh shims (`14-wsl-extras.sh:52,62,76`) and 4 top-level in standalone entry points (`autotune-model.sh:416`, `retune-band-chunk.sh:64`, `run-autotune-batch.sh:99`, `spec-decode-bench.sh:57`). Matches the doc's 2026-10-25 reading. |
| 17.5 | HOLDS | `grep -rn "grep -q 'ok'" scripts/ bin/` | 0. |
| 17.6 | HOLDS | `health()` in `bin/llama-watchdog.sh` | `503) return 2` (:381), and 2 is treated as "not ready, don't touch" (:374, :714) — a loading lane is neither struck nor restarted. |
| 17.7 | HOLDS | `grep -rn '=~ \^/' scripts/` | 0 unanchored-alternation regexes. |
| 17.8 | HOLDS | `grep -rn 'grep -c .*\| echo' scripts/ bin/ tools/` | 0. |
| 17.9 | HOLDS | registry header vs consumers | `LLM_REGISTRY_HEADER` (`01-constants.sh:396`) puts `mmap_mode` at column **15** and `tps` at **17**, exactly the numbers the item cites. |
| 17.10 | HOLDS | `scripts/kgraph/server.py` | `validate_graph_payload` at :413 runs **before** `save_to_graph_db` at :416; `MAX_PAYLOAD_SIZE` imported :25; an explicit Origin allowlist (:43) rather than wildcard CORS. |
| 17.11 | HOLDS | `grep -n 'escape' scripts/kgraph/{pr_dashboard,call_flow,html}.py` | `from html import escape` and every interpolated value wrapped (`pr_dashboard.py:266-269` …). |
| 17.12 | HOLDS | `tests/conftest.py` | `_is_stale_lock` (:85) checks `os.kill(pid, 0)` **and** compares the process start time (:53, :105), so a recycled PID is not a live holder; the wait is bounded by the suite's own timeout (:36-38). |
| 17.13 | HOLDS | `__cl_step` doc block, `08-maintenance.sh:2094-2099` | States it "reads yes_mode and bumps deep_count through the caller's dynamic scope" — exactly the note the item asks for. |
| 17.14 | HOLDS | `ls scripts/_*.sh` | `_module-list.sh` and `_startup-env.sh`, both underscore-prefixed. |
| 17.15 | HOLDS | `grep -n 'consecutive' scripts/autotune-model.sh` | :510 states the two-consecutive-failure rule and :708 names the consecutive-stall threshold; the counter resets on a healthy launch (:1954). |
| 17.16 | FAILS | `kgraph update --repo .` then `kgraph wiring --repo .` | Update completes (6564 nodes, 15790 edges), but wiring reports **orphans 3, weak_wiring 3, unused_facades 1, cross_file_call_gaps 2510** where the item expects 0 of each (broken_imports is 0 ✓). Run against the live tree, which carried three unrelated shell edits. |

**Section controls — §17:** (a) 17.4's probe on a fixture with `exec` inside a function → 1; (b) 17.5's on a
fixture with `grep -q 'ok'` → 1; (c) 17.8's on a fixture with `grep -c x || echo 0` → 1.

## Summary

| Section | Items | HOLDS | FAILS | NOT-RUN | PROCEDURE |
|---|---|---|---|---|---|
| §1 Pre-Flight | 13 | 5 | 4 | 0 | 4 |
| §2 Security (to 2.3.7) | 14 | 12 | 2 | 0 | 0 |
| §2 Security (2.4–2.6) | 15 | 7 | 7 | 1 | 0 |
| §3 Safety | 14 | 13 | 1 | 0 | 0 |
| §4 Correctness & Clean Code | 24 | 12 | 9 | 3 | 0 |
| §5 Robustness | 14 | 11 | 3 | 0 | 0 |
| §6 Efficiency & Native Bash | 12 | 5 | 7 | 0 | 0 |
| §7 Portability | 7 | 2 | 5 | 0 | 0 |
| §8 Style & Formatting | 15 | 8 | 6 | 1 | 0 |
| §9 Documentation & Future-Proofing | 15 | 9 | 4 | 2 | 0 |
| §10 Refactor & Maintainability | 9 | 2 | 6 | 1 | 0 |
| §11 Testing & CI | 14 | 11 | 3 | 0 | 0 |
| §12 llama.cpp Integration | 23 | 20 | 3 | 0 | 0 |
| §13 Cross-Script Consistency | 22 | 19 | 3 | 0 | 0 |
| §15 AI Agent Access | 16 | 14 | 2 | 0 | 0 |
| §16 Final Validation | 9 | 7 | 1 | 1 | 0 |
| §17 New Insights & Standards | 16 | 14 | 2 | 0 | 0 |
| **Total** | **252** | **171** | **68** | **9** | **4** |

**Item coverage.** The document's §1–§17 as numbered total **252** items
(13+14+15+14+24+14+12+7+15+15+9+14+23+22+16+9+16), and every one of them has a row above. Nothing in the numbered
ranges is skipped. Three structural notes about the document itself: **§6 has no 6.6** (it runs 6.5 → 6.7), so §6 is
12 items; **§13's subsections are out of order** (13.5 is written before 13.4) but complete at 22; **§14 does not
exist** — the document jumps from §13 to §15; and **§18** is the document's own field notes, not a checklist, so it
carries no items.

**Closing note.** Audited commit `8343b7cc`; 252 items — 171 HOLDS, 68 FAILS, 9 NOT-RUN, 4 PROCEDURE. Three to fix
first: **12.4.5** (a lane stop/switch errors in-flight turns instead of draining them, `llama-watchdog.sh:153`),
**12.4.1** (no existence/readability check on the resolved GGUF before launch), **13.2.2** (exit code 2 means
*usage* in most tools and *refused* in `bin/fleet-model.sh`). 16.7 is the one item still owed a full run.
