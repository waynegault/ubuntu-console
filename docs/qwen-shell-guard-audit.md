# Qwen daemon shell guard — audit, local patch, and upstream asks

Audited 2026-09-16, after a session was denied two commands it should have been
allowed to run. The guard is not ours; this records what it does, the two gaps
found, the local patch applied, and what to ask upstream.

> **Status 2026-09-27 — the local patch is NOT applied.** The 0.24.6 companion
> (installed 2026-09-26 14:50) replaced the guard chunk and silently reverted the
> allowlist to the stock two verbs, so the read-only exemption described below does
> **not** hold on this box today. `~/.local/bin/qwen-guard-patch.sh --check` reports
> `UNKNOWN … the bundle changed shape` and refuses to patch blind. Re-audit, the exact
> 0.24.6 strings, and the correction to this document's framing: §0.24.6. Everything
> before that section describes the 0.23.4–0.24.5 chunk.
>
> Upstream's own bundled docs were right all along (`bundled/qc-helper/docs/qwen-serve.md`):
> "Relocated commands whose subcommand is one of a small verified read-only set
> (`rev-parse`, `cat-file`) remain allowed". The wider list was never upstream
> behaviour — it was our patch, and this audit read the patched state as the shipped one.

## What it is, and where

The "Daemon shell guard" that prefixes denials with `Daemon shell guard denied …` is
part of the Qwen Code **VS Code IDE companion**, bundled as
`dist/qwen-cli/chunks/daemon-git-worktree-guard-<hash>.js` (0.23.4 first audited: 2337
lines, 84 KB, obfuscated identifiers, readable strings; 0.24.0 is the same shape at 84.9
KB).

**There are up to three copies, and the one that matters is the Windows-side one.** At
2026-09-16 17:00 this box had:

    ~/.vscode-server/extensions/…-0.23.4/…/daemon-git-worktree-guard-QU2CCJIE.js      (patched first — and USELESS)
    ~/.vscode-server/extensions/…-0.24.0/…/daemon-git-worktree-guard-BULXRIDA.js
    /mnt/c/Users/wayne/.vscode/extensions/…-0.24.0-win32-x64/…/daemon-git-worktree-guard-ER5WRHNU.js

The daemon that evaluates commands does **not** run inside WSL: a WSL reboot happened and
this session survived it, and the guard stayed unpatched afterwards. It is the
**Windows-side** extension that enforces the guard, which is why patching the Linux copies
alone changed nothing. `~/.local/bin/qwen-guard-patch.sh` now globs **both** install roots,
and the 0.24.0 update is a standing reminder that an update replaces the chunk — the stock
2-verb allowlist was still present in 0.24.0, so the upstream gap is unaddressed.

It is **not configurable**: no guard-related setting id exists anywhere in the
extension's `dist`, and the chunk reads no `settings.*` or `QWEN_*` value. The
only interface is the source.

Its own docs (`dist/qwen-cli/bundled/qc-helper/docs/qwen-serve.md`) describe it as a
control against **Git relocation** — a command aimed at a repository other than the
session working directory. They state plainly that it is "best-effort, not a
boundary", that it "does not interpret script files … or analyze heredoc bodies
(Git-shaped text inside a heredoc can be denied even though the shell never
executes it)", and: "Do not grant a daemon broader trust on the strength of it."

### Denial taxonomy (the `…_DENIAL` constants)

`DYNAMIC_RELOCATION`, `UNRESOLVED_TARGET`, `OUTSIDE_TARGET`, `UNPARSEABLE_COMMAND`,
`UNDECIDABLE_PAYLOAD`, `UNRECOGNIZED_PROGRAM`, `UNVERIFIABLE_SCOPE`,
`CMD_REWRITE_SYNTAX`, `WINDOWS_UNMODELLED_SYNTAX`, `SHADOW_REMOVAL`,
`PROMPTLESS_PROVIDER`, `EXTERNAL_TOOL_GUARD_MAX`.

Every one is fail-closed: what it cannot model, it refuses. That is the right
default for a control in this position, and it is not a bug.

## The two denials that prompted this, and their real cause

    $ git -C /home/wayne/llama.cpp rev-parse --short HEAD; git -C … status --porcelain | head -5
    Daemon shell guard denied a mutating Git command outside the session working directory: /home/wayne/llama.cpp
    $ cat .git/HEAD; cat .git/refs/heads/main; grep … .git/logs/HEAD   # cwd inside another repo
    Daemon shell guard denied a mutating Git command outside the session working directory: /home/wayne/investigator

**The trigger was the relocation, not the verb** — both were run against a repository
outside the session directory. Verified with the guard's own evaluator (harness
below): `cd /home/wayne/investigator && cat .git/HEAD` is denied, while a compound
command with no relocation is not. The terseness of the message is what made this
hard to see; "mutating Git command" names neither the rule nor the verb, and a `cat`
of `.git/HEAD` is neither mutating nor a Git command.

## Gap 1 — the read-only allowlist is two verbs long

The guard *does* have a read-only exemption:

    var RELOCATED_READ_ONLY_GIT_SUBCOMMANDS = /* @__PURE__ */ new Set(["cat-file", "rev-parse"]);

    if (RELOCATED_READ_ONLY_GIT_SUBCOMMANDS.has(invocation.subcommand ?? "") && !invocation.hasDisqualifyingFlag) {
      return void 0;
    }

So `git -C <other-repo> rev-parse …` was always allowed, and a *simple*
`git -C <other-repo> log …` was refused purely because `log` is not in that set.
`--filters`, `--output` and `--textconv` are the disqualifying flags.

## Gap 2 — a denial does not say what was refused

`denyTarget(prefix, target)` renders `prefix + target`, so the offending path is
included and nothing else is. Twelve distinct reasons exist, but the message never
names the **verb** or the **rule** that fired, which is why a read-only inspection
looked identical to a mutating one.

## Gap 3 — a relocated git inside a quoted substitution is denied (found 2026-09-21)

Found while working on the 0.24.3 WSL-side chunk (`…LQ3XGSBU.js`), not the 0.24.0 copy
audited above. This one is **not** the read-only allowlist, and the local patch neither
touches it nor should: it is the `UNRECOGNIZED_PROGRAM` branch, the fail-closed case for
programs the guard cannot model.

    $ echo "$(git -C /home/wayne/investigator log --oneline -1)"
    Daemon shell guard denied a shell command that may run a relocated Git command through an unrecognized program.

Measured — every row below was run, none inferred:

| Command | Result |
|---|---|
| `git -C <other> log --oneline -1` (top level) | ALLOW |
| `bash <script>; git -C <other> log --oneline -1` | ALLOW |
| `echo "<label> git"; git -C <other> log --oneline -1` | ALLOW |
| `q=$(git -C <other> log --oneline -1); echo "$q"` | ALLOW |
| `echo "$(git rev-parse --short HEAD)"` (session repo) | ALLOW |
| `echo "$(git -C <other> log --oneline -1)"` | **DENY** |
| `echo "<label>: $(git -C <other> log --oneline -1)"` | **DENY** |
| `echo "<label vcs>: $(git -C <other> log --oneline -1)"` | **DENY** |

**The trigger is the shape, not the word.** Three plausible readings were tested and
falsified: it is not the word "git" appearing in output text (row 3 allows; row 8 denies
without it), not command substitution as such (row 4 allows), and not nesting as such
(row 5 allows). What is refused is a *relocated* git command inside a substitution that
forms part of a **quoted word**, so the whole word becomes one token carrying both `git`
and `-C`.

In the chunk: `UNRECOGNIZED_PROGRAM_DENIAL` (`…LQ3XGSBU.js:347`) is raised by
`evaluateUnrecognizedRun` (line 1570) when a run that is not a modelled relocation holds
a token matching `GIT_WORD_PATTERN = /\bgit\b/i` (line 665) while the command carries a
relocation marker — `TEXT_RELOCATION_MARKER_PATTERN` matches a bare `-C`.

**The working shape** is capture-then-use: `q=$(git -C <other> log -1); echo "$q"`, or
run the git command at top level. The same rule is recorded in `~/.qwen/QWEN.md` so
sessions do not have to rediscover it. Nothing here wants a patch — the fix is the
command.

## Local patch (applied 2026-09-16; 0.23.4–0.24.5 chunks only — reverted by 0.24.6)

Two hunks in the chunk, at the guard's own extension points — no logic rewritten:

1. **Widen the allowlist** with verbs that are read-only in *every* form they accept:
   `blame, count-objects, describe, diff, for-each-ref, grep, log, ls-files, ls-tree,
   merge-base, name-rev, rev-list, shortlog, show, show-ref, status, verify-commit,
   verify-tag, whatchanged` (plus the stock `cat-file`, `rev-parse`). Verbs with a
   write mode behind a flag — `branch`, `tag`, `config`, `remote`, `worktree`,
   `stash`, `reflog`, `symbolic-ref` — are deliberately **not** listed: a
   subcommand-keyed allowlist cannot express "only with `--list`".
2. **Name the verb** in the `OUTSIDE_TARGET` message at the site where
   `invocation.subcommand` is in scope (one of the four).

- Backup: `…daemon-git-worktree-guard-<hash>.js.orig-<timestamp>` beside the chunk.
- Re-apply after a companion update (idempotent, refuses unknown shapes, rolls back
  if `node --check` fails): `~/.local/bin/qwen-guard-patch.sh [--check]`
- Revert: restore the `.orig-*` backup over the chunk, then reload.

Taking effect requires a **VS Code window reload** (Developer: Reload Window), not a WSL
restart: the guard runs in the Windows-side extension host, and a WSL reboot on 2026-09-16
demonstrably did not reload it. Until that reload, the running daemon still executes the
unpatched code — so the 12/12 harness below describes the *file*, not live behaviour.

## Verification

`node --check` on the patched bundle: **OK** (this is the check that matters most —
a syntax error here breaks the whole CLI).

Behavioural verification uses the chunk's own exported entry point
(`createDaemonToolGuard(null)` → an async evaluator over a request), so a patched
file is exercised without a reload — re-run on 2026-09-16 17:42 against the
Windows-side 0.24.0 chunk (`…ER5WRHNU.js`, the copy the daemon loads) and again 12/12:

| Command | Expected | Result |
|---|---|---|
| `git -C <other> log -n 1 --oneline` | allow | ALLOW |
| `git -C <other> status --porcelain` | allow | ALLOW |
| `git -C <other> diff --stat` | allow | ALLOW |
| `git -C <other> rev-parse --short HEAD` | allow (stock) | ALLOW |
| `git status --porcelain` (inside session dir) | allow | ALLOW |
| `git -C <other> log -n 1 --output=/tmp/x` | deny (`--output`) | DENY |
| `git -C <other> commit -m x` | deny | DENY |
| `git -C <other> branch -D topic` | deny | DENY |
| `git -C <other> config core.editor vim` | deny | DENY |
| `git -C <other> push` | deny | DENY |
| `cd <other> && git log -n 1 --oneline` | allow (read-only exemption) | ALLOW |
| `cd <other> && cat .git/HEAD` | **deny** (relocation control) | DENY |

The last row is the negative control that matters: the relocation control's non-git
path is untouched. Note the eleventh — the patch also allows a *cwd-relocated*
read-only git command, which is a real widening of what the exemption covers.

The Gap 3 table was measured a different way: in a live 0.24.3 session on 2026-09-21,
against the WSL-side chunk (`…LQ3XGSBU.js`) *with this patch applied*, by running each
command and reading the guard's verdict — not through the harness above. That is why its
results are a statement about the shipped, patched behaviour rather than about the
evaluator in isolation.

## 0.24.6 (re-audited 2026-09-27) — the chunk changed shape and the patch silently reverted

Measured on this box. The standing warning in the patch script came true: a companion
update replaces the chunk.

    qwenlm.qwen-code-vscode-ide-companion-0.24.5-*   chunk 86 705 B   marker present, .orig-20260925-071701   -> patched
    qwenlm.qwen-code-vscode-ide-companion-0.24.6-*   chunk 64 029 B   no marker, no backup                    -> STOCK

Both 0.24.6 copies were installed at 2026-09-26 14:50. The Windows-side one
(`...-0.24.6-win32-x64`, chunk `daemon-git-worktree-guard-BJFH5IIF.js`) is the copy the
daemon loads. 0.24.5's chunks (`...S3SFT3H7.js`, `...UWMLREGF.js`) were patched on
2026-09-25 and are still patched on disk — they are simply no longer the ones running.
The 86 705 -> 64 029 byte drop is the guard's own restructure, not a deletion: the logic
below is all still present, only its spelling changed.

`qwen-guard-patch.sh --check` now reports, correctly (rc=1):

      ok       daemon-git-worktree-guard-S3SFT3H7.js (patch already applied)              # 0.24.5 linux
      UNKNOWN  daemon-git-worktree-guard-I3X7TJFR.js — stock allowlist string not found   # 0.24.6 linux
      ok       daemon-git-worktree-guard-UWMLREGF.js (patch already applied)              # 0.24.5 win32
      UNKNOWN  daemon-git-worktree-guard-BJFH5IIF.js — stock allowlist string not found   # 0.24.6 win32

### What changed — cosmetic spelling, still two verbs

The patch script matches an exact string, and that string no longer occurs:

    var RELOCATED_READ_ONLY_GIT_SUBCOMMANDS = /* @__PURE__ */ new Set(["cat-file", "rev-parse"]);   # what the script matches (0.24.5)
         RELOCATED_READ_ONLY_GIT_SUBCOMMANDS=new Set(["cat-file","rev-parse"])                      # 0.24.6

Three differences, none semantic: no `var`, no `/* @__PURE__ */` annotation, and no space
after the commas. The set is **still two verbs in 0.24.6** — Gap 1 is unaddressed
upstream. The disqualifying flags became a named set rather than an inline check:

    RELOCATED_READ_ONLY_DISQUALIFYING_FLAGS=new Set(["--filters","--output","--textconv"])

and the exemption call site keeps its shape:

    RELOCATED_READ_ONLY_GIT_SUBCOMMANDS.has(invocation.subcommand??"")&&!invocation.hasDisqualifyingFlag){return void 0

### Still not configurable — and now checked one level higher

The 2026-09-16 audit checked the chunk for setting reads. 0.24.6 reads none either
(no `getConfiguration`, no `QWEN_*`), and the stronger check also holds: the extension
`package.json` contributes **5** configuration properties and **none** is
guard/shell/git-related. There is no supported way to widen the exemption; the only lever
remains the source patch.

### Gap 3 is unchanged

`GIT_WORD_PATTERN=/\bgit\b/i` and a `TEXT_RELOCATION_MARKER_PATTERN` matching a bare `-C`
are both still present, so the quoted-substitution refusal measured on 2026-09-21 still
stands, and still dies in the same fail-closed branch.

### A consequence the 2026-09-16 audit did not record: one denied shape refuses the WHOLE command line

Measured 2026-09-27, while bundling harmless read-only checks with a relocated
`git log`: the call returned **only** the denial — every other clause was refused with it.
The guard reasons about the command line, not about clauses, so one relocated git command
anywhere in a compound command can take down unrelated work. Run the git call as its own
top-level command.

### What a 0.24.6 re-patch would need

Generalise the script's exact-match string to the 0.24.6 spelling above, keep
`--filters`/`--output`/`--textconv` disqualifying (now via the named set), re-apply to both
copies, then **reload the VS Code window** — the guard runs in the Windows-side extension
host, so a WSL restart does nothing. Until then, relocated read-only verbs other than
`cat-file`/`rev-parse` are refused, including `log`, `status` and `diff` — which is why a
cross-repo inspection that worked in September fails in October.

## Upstream asks

Re-checked against 0.24.6 on 2026-09-27. **Ask 1 is still open** — the allowlist is still
`new Set(["cat-file","rev-parse"])`. **Ask 2 is still open** for the resolved-relocation
case — the live message is `Daemon shell guard denied a mutating Git command outside the
session working directory: <path>`, naming neither the verb nor the rule. **Ask 4 is
unchanged** — both patterns behind it are still present. **Ask 3 was mis-stated and is
largely satisfied**: upstream's bundled docs already give the two-verb set, the
`--output`/`--textconv`/`--filters` disqualifiers, both denial message forms and the
best-effort caveat. What they still do not give is an example of a *cwd* relocation into
another repository (the `cd <other> && cat .git/HEAD` case), which this audit did not
re-measure on 0.24.6.

1. **Widen `RELOCATED_READ_ONLY_GIT_SUBCOMMANDS`** to the standard read-only verbs
   (the list above), keeping `--output`/`--filters`/`--textconv` disqualifying. Two
   verbs is far below what a reader expects from a set with that name.
2. **Name the refusal** — the rule and, where it is in scope, the subcommand. One
   fixed sentence per category makes two very different commands indistinguishable.
3. **Document the trigger with an example.** The docs describe relocation but the
   practical rule is: a compound command is fine, and `git -C <other-repo> <read-only
   verb>` is fine once the allowlist covers it, but a *cwd relocation into another
   repository* is refused even for `cat .git/HEAD`. That sentence would have saved
   this audit.
4. **Model — or name — the quoted-substitution shape.** `echo "$(git -C <other> …)"` is
   the natural way to print one field of another repository's state, and no allowlist
   can reach it: it dies in `UNRECOGNIZED_PROGRAM` because the whole quoted word is one
   token carrying both `git` and `-C`. Either model a substitution whose only command is
   a read-only relocated git command, or make the refusal say that the quoted
   substitution is what triggered it.

None of these weaken the control; the first two make it usable, and the last two make
its behaviour predictable.
