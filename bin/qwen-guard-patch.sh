#!/usr/bin/env bash
# qwen-guard-patch.sh — re-apply the local relaxations to the Qwen daemon's shell guard,
# after an IDE-companion update replaces the bundled chunk.
#
# WHAT IT PATCHES (three states, reported separately; "the two states" Wayne asked to be
# reported distinctly on 2026-10-01 are states 2 and 3 — state 1 is the older 2026-09-16 patch):
#
#   1. read-only allowlist (LOCAL PATCH 2026-09-16)
#      The guard's RELOCATED_READ_ONLY_GIT_SUBCOMMANDS lists exactly two verbs stock
#      ("cat-file", "rev-parse"), so every other read-only verb (log, status, diff, show,
#      ls-files, ...) is refused as a "mutating Git command" when it targets a repository
#      outside the session working directory.  This hunk adds the read-only-in-every-form
#      verbs.  Verbs with a write mode behind a flag (branch, tag, config, remote, worktree,
#      stash, reflog, symbolic-ref) are deliberately NOT listed: a subcommand-keyed allowlist
#      cannot express "only with --list".
#
#   2. git token must name git (LOCAL PATCH 2026-10-01)
#      evaluateUnrecognizedRun treated ANY token whose text contains the word `git` as a git
#      program (GIT_WORD_PATTERN = /\bgit\b/i).  So an ordinary argument that merely NAMES a
#      path — `.../qwen-memory-stores-under-git.md`, `/tmp/probe-git.md` — turned an unrelated
#      command into a "relocated Git command", and the denial then asserted a mutation AND a
#      repository target that did not exist.  Measured 2026-10-01, same cwd, byte-identical
#      files, only the filename differing:
#        DENIED   cd ~/.qwen && markdownlint --config .markdownlint.jsonc \
#                   memories/reference/qwen-memory-stores-under-git.md
#                 -> "denied a mutating Git command outside the session working directory:
#                     /home/wayne/.qwen"
#        ALLOWED  the same command naming /tmp/qgc/control-plain.md
#      A git token must now NAME git: the program word itself (`git`, `/usr/bin/git`) or a path
#      component named `.git`.  That keeps `cd <other> && cat .git/HEAD` refused (audit row 14)
#      while dropping matches inside plain arguments and quoted words.  Dropping those is safe:
#      command-substitution bodies are still evaluated recursively on their own merits, so a
#      mutating git hidden in `"$(...)"` is refused by the body's own evaluation, not by this
#      token test.  The test stays fail-CLOSED on purpose — it accepts any program-shaped git
#      token, which is what catches an unmodelled wrapper such as `nice -n 5 git -C <other>
#      commit` — so a bare `git` word used as an argument is still refused when the working
#      directory is outside the session root.  That residual false positive is stock behaviour,
#      unchanged here, and is now reported honestly rather than as a "mutating Git command".
#      The same hunk makes two denials name what was actually matched, instead of reusing the
#      "mutating Git command" prefix for a decision that is not a git invocation at all.
#
#   3. allowed mutating repositories (LOCAL PATCH 2026-10-01)
#      Wayne, 2026-10-01: "i authorise widening the guard's mutating-verb allowlist" so this
#      session can commit the ~/.qwen memory stores (two repos, the second nested in the
#      first).  Implemented as an EXPLICIT repository-root allowlist — those two paths only —
#      NOT a blanket "any relocated mutating git", which would remove the protection the guard
#      exists to provide for every other repository on the box.  Applied at the three gates
#      that decide an OUTSIDE_TARGET denial, so it relaxes ONLY "which repository is
#      reachable"; the dynamic-relocation, unparseable-payload and unrecognized-program
#      refusals are untouched.
#
# WHY THIS EXISTS
#   Full rationale, evidence and the harness that tests the patched file:
#   /home/wayne/ubuntu-console/docs/qwen-shell-guard-audit.md  (that doc now documents all
#   three states — state 1 under "Local patch", states 2 and 3 under "The 2026-10-01 patch";
#   ubuntu-console owns it).
#
# WHICH COPY MATTERS (corrected 2026-09-27)
#   Which copy enforces a session depends on where THAT session runs.  A WSL-remote
#   session's daemon and extension host both run WSL-side (that is what `-linux-x64`
#   means), so for the sessions this box actually runs the Linux copy is the one in
#   play; the win32 copy would be the one in play for a Windows-hosted session.  So:
#   patch EVERY copy (this script globs both roots), then restart the process that enforces
#   the session in question — for a WSL session that is a VS Code window reload, not a WSL
#   reboot (measured 2026-09-16: a reboot did not reload it).
#
#   A window that is NOT reloaded keeps running the code its daemon loaded at start, even
#   with the file already patched on disk — measured 2026-10-01: Wayne reloaded a window and
#   this session's daemon still refused, so the session's own daemon had to be identified
#   before the patch could be believed.  Companion updates revert the patch again; re-run
#   this script and reload.
#
# 0.24.6 SUPPORT (added 2026-09-27)
#   The 0.24.6 companion re-spelled the declaration without a semantic change, so the
#   0.24.5 anchor no longer matched and this script refused (correctly).  Both spellings
#   are now recognised, and the replacement is emitted in the matching style:
#     0.23.4-0.24.5:  var RELOCATED_READ_ONLY_GIT_SUBCOMMANDS = /* @__PURE__ */ new Set(["cat-file", "rev-parse"]);
#     0.24.6:         var RELOCATED_READ_ONLY_GIT_SUBCOMMANDS=new Set(["cat-file","rev-parse"]);
#   (The doc's first draft of the 0.24.6 re-audit said "no var"; that was a grep-pattern
#   artefact — the pattern excluded it.  The var IS there; only the @__PURE__ annotation
#   and the spacing changed.)
#
#   The optional second hunk (naming the refused verb in the OUTSIDE_TARGET message) is
#   applied only when its 0.24.5-shaped anchor is present.  On 0.24.6+ it is SKIPPED and
#   reported: the new shape's enclosing scope for `invocation` is not verifiable by inspection
#   here, and `node --check` validates syntax only — a wrong reference would pass the check and
#   fail at runtime, which is not a trade worth making for a diagnostic nicety.  The honest
#   wording in state 2 covers the same ground without touching that scope.
#
# SAFETY
#   * Patches by EXACT string match and refuses anything it does not recognise —
#     a future bundle whose shape has changed is REPORTED, never patched blind.
#   * The hunks are per-chunk all-or-nothing: if any anchor a chunk needs is missing, the
#     chunk is left byte-identical, the backup taken for the attempt is removed, and the
#     chunk is reported MISMATCH.
#   * Backs up the chunk once (…js.orig-<timestamp>) before the first patch.
#   * Asserts the stock pair ("cat-file", "rev-parse") AND every allowlisted repository root
#     survive into the replacement — the 2026-09-27 fault listed only the ADDITIONS and so
#     shipped a guard STRICTER than stock; that now fails loudly instead of silently.
#   * Runs `node --check` afterwards and rolls back if the bundle stops parsing.
#   * Idempotent: a chunk already carrying all three markers is left alone.
#
# USAGE
#   qwen-guard-patch.sh          # apply (or report) for every installed companion
#   qwen-guard-patch.sh --check  # report only; exit 1 if any state is missing
#
# TRACKED HERE since 2026-10-01: this script lived only as a loose copy at
# ~/.local/bin/qwen-guard-patch.sh, so the patch that keeps relocated read-only git
# working (docs/qwen-shell-guard-audit.md) was unversioned and its re-application
# after a companion update rested on an untracked file.  `install.sh` links every file
# in `bin/` into ~/.local/bin, so the stable path keeps resolving — now as a symlink to
# this file.  The companion to it, qwen-guard-selfheal.sh, is tracked beside it.
#
# AI INSTRUCTION: Increment version on significant changes.
# Module Version: 1
set -euo pipefail

MARKER_RO="LOCAL PATCH 2026-09-16"
MARKER_TOKEN="LOCAL PATCH 2026-10-01 (git token must name git)"
MARKER_WRITE="LOCAL PATCH 2026-10-01 (allowed mutating repositories)"

STOCK_0245='var RELOCATED_READ_ONLY_GIT_SUBCOMMANDS = /* @__PURE__ */ new Set(["cat-file", "rev-parse"]);'
STOCK_0246='var RELOCATED_READ_ONLY_GIT_SUBCOMMANDS=new Set(["cat-file","rev-parse"]);'

# Repository roots this box may mutate from OUTSIDE the session working directory.  Both are
# git repositories and the second is nested inside the first, so both are named explicitly.
ALLOWED_MUTATING_REPOSITORY_ROOTS=(
    "/home/wayne/.qwen"
    "/home/wayne/.qwen/memories"
)

check_only=0
[[ "${1:-}" == "--check" ]] && check_only=1

shopt -s nullglob
chunks=(
    # WSL-side (remote) installs
    "$HOME"/.vscode-server/extensions/qwenlm.qwen-code-vscode-ide-companion-*/dist/qwen-cli/chunks/daemon-git-worktree-guard-*.js
    # Windows-side installs
    /mnt/c/Users/*/.vscode/extensions/qwenlm.qwen-code-vscode-ide-companion-*/dist/qwen-cli/chunks/daemon-git-worktree-guard-*.js
)
if (( ${#chunks[@]} == 0 ))
then
    echo "qwen-guard-patch: no companion guard chunk found — nothing to do"
    exit 0
fi

# The allowlisted roots as a JavaScript array-literal body, via python's json encoder, so a
# path containing a quote or a backslash cannot break the emitted source.
roots_as_json="$(python3 -c 'import json,sys; print(",".join(json.dumps(a) for a in sys.argv[1:]))' \
    "${ALLOWED_MUTATING_REPOSITORY_ROOTS[@]}")"

rc=0
for f in "${chunks[@]}"
do
    name="$(basename "$f")"

    # The three states, as they stand on disk right now.  state_ro: any value other than
    # applied/BROKEN means the stock anchor is not there either, i.e. UNKNOWN shape.
    state_ro="MISSING"
    if grep -qF "$MARKER_RO" "$f"
    then
        if grep -qF '"cat-file"' "$f" && grep -qF '"rev-parse"' "$f"
        then
            state_ro="applied"
        else
            state_ro="BROKEN"
        fi
    elif ! grep -qF "$STOCK_0245" "$f" && ! grep -qF "$STOCK_0246" "$f"
    then
        state_ro="UNKNOWN"
    fi
    state_token="MISSING"
    grep -qF "$MARKER_TOKEN" "$f" && state_token="applied"
    state_write="MISSING"
    grep -qF "$MARKER_WRITE" "$f" && state_write="applied"

    if [[ "$state_ro" == "BROKEN" ]]
    then
        echo "  BROKEN   $name (read-only allowlist: BROKEN; git-token rule: $state_token; mutating-repo allowlist: $state_write)" >&2
        echo "           carries the LOCAL PATCH 2026-09-16 marker but the stock verbs are gone." >&2
        echo "           That is the 2026-09-27 allowlist-replacement fault: restore the" >&2
        echo "           …js.orig-* backup over the chunk and re-run this script." >&2
        rc=1
        continue
    fi

    if [[ "$state_ro" == "UNKNOWN" ]]
    then
        echo "  UNKNOWN  $name (read-only allowlist: UNKNOWN — neither known stock allowlist string is present)" >&2
        echo "           The bundle changed shape again; inspect it before patching:" >&2
        echo "           grep -n RELOCATED_READ_ONLY_GIT_SUBCOMMANDS $f" >&2
        rc=1
        continue
    fi

    if [[ "$state_ro" == "applied" && "$state_token" == "applied" && "$state_write" == "applied" ]]
    then
        echo "  ok       $name (read-only allowlist: applied; git-token rule: applied; mutating-repo allowlist: applied)"
        continue
    fi

    if (( check_only ))
    then
        echo "  NEEDS    $name (read-only allowlist: $state_ro; git-token rule: $state_token; mutating-repo allowlist: $state_write)" >&2
        rc=1
        continue
    fi

    if [[ "$state_ro" == "applied" ]]
    then
        style=""
    elif grep -qF "$STOCK_0246" "$f"
    then
        style="0246"
    else
        style="0245"
    fi

    backup="$f.orig-$(date +%Y%m%d-%H%M%S)"
    cp -p "$f" "$backup"
    echo "  backup   $backup"

    # The edits are applied by python (exact, multi-line, no sed escaping games).  Every anchor
    # must be present exactly once; nothing is written unless every hunk that is still needed
    # finds its anchor, so the states are applied atomically per chunk.  Post-conditions then
    # re-check the promises (stock verbs, allowlisted roots, the inserted symbols) before the
    # new text is written.
    if ! PATCH_FILE="$f" PATCH_STYLE="$style" PATCH_ROOTS="$roots_as_json" python3 - <<'PY'
import json, os, pathlib

p = pathlib.Path(os.environ["PATCH_FILE"])
style = os.environ["PATCH_STYLE"]
roots_literal = os.environ["PATCH_ROOTS"]
roots = json.loads("[" + roots_literal + "]") if roots_literal else []
src = p.read_text(encoding="utf-8")

VERBS_AND_COMMENT = '''  // LOCAL PATCH 2026-09-16 (see docs/qwen-shell-guard-audit.md): the stock set held
  // only cat-file and rev-parse, so `git -C <other-repo> log|status|diff|show ...` was
  // denied as a "mutating Git command" although nothing is written. Every verb added
  // here is read-only in EVERY form it accepts. Verbs with a write mode behind a flag
  // (branch, tag, config, remote, worktree, stash, reflog, symbolic-ref) are
  // deliberately NOT listed - a subcommand-keyed allowlist cannot express "only with
  // --list" - and --output/--filters/--textconv remain disqualifying below.
  //
  // The stock pair is repeated FIRST because NEW replaces the whole declaration. The
  // 0.24.6 revision of this script listed only the additions, which silently DROPPED
  // cat-file and rev-parse - taking away the two verbs upstream verifies and shipping
  // a guard stricter than stock. Caught 2026-09-27 by evaluating the patched chunk
  // through its own exported guard, before the reload that would have made it live.
  // The assertion below now makes that mistake fail loudly instead of silently.
  "cat-file", "rev-parse",
  "blame", "count-objects", "describe", "diff", "for-each-ref", "grep", "log",
  "ls-files", "ls-tree", "merge-base", "name-rev", "rev-list", "shortlog", "show",
  "show-ref", "status", "verify-commit", "verify-tag", "whatchanged"
'''

# Inserted immediately before evaluateUnrecognizedRun.  Escapes are doubled for the Python
# literal; the emitted JavaScript is what the comments below describe.
INSERTED_BLOCK = '''// LOCAL PATCH 2026-10-01 (git token must name git): the stock rule treated ANY token
// whose text contains the word git as a git program (GIT_WORD_PATTERN), so an ordinary argument
// that merely NAMES a path - ".../qwen-memory-stores-under-git.md", "/tmp/probe-git.md" - turned
// an unrelated command into a "relocated Git command", and the denial then asserted a mutation
// and a repository target that did not exist. Measured 2026-10-01, same cwd, byte-identical
// files, only the filename differing: `cd ~/.qwen && markdownlint --config .markdownlint.jsonc
// memories/reference/qwen-memory-stores-under-git.md` -> "denied a mutating Git command outside
// the session working directory: /home/wayne/.qwen", while the same command naming
// /tmp/qgc/control-plain.md was allowed. A git token must now NAME git: the program word itself
// (git, /usr/bin/git) or a path component named .git - which keeps `cd <other> && cat .git/HEAD`
// refused. Matches inside plain arguments and quoted words no longer count, and that is safe
// because command-substitution bodies are still evaluated recursively on their own merits: a
// mutating git hidden in "$(...)" is refused by the body's own evaluation, not by this token
// test. The test stays fail-CLOSED on purpose - it accepts any program-shaped git token, which is
// what catches an unmodelled wrapper such as `nice -n 5 git -C <other> commit` - so a bare `git`
// word used as an argument is still refused when the working directory is outside the session
// root; that residual false positive is stock behaviour, unchanged here, and now reported honestly.
function isGitCommandPositionToken(token) {
  return executableBaseName(token) === "git" || /(?:^|[\\\\/])\\.git(?:[\\\\/]|$)/i.test(token.text);
}
__name(isGitCommandPositionToken, "isGitCommandPositionToken");
// LOCAL PATCH 2026-10-01 (allowed mutating repositories): an EXPLICIT allowlist of the repository
// roots this box may mutate from OUTSIDE the session working directory - the ~/.qwen memory
// stores, the second nested inside the first. Deliberately narrow: naming those two stores keeps
// the protection the guard exists to provide for every OTHER repository on the box, which a
// blanket "any relocated mutating git" would remove. Applied at the three OUTSIDE_TARGET gates,
// so it relaxes only WHICH repository is reachable and leaves the dynamic-relocation,
// unparseable-payload and unrecognized-program refusals intact.
var ALLOWED_MUTATING_GIT_REPOSITORY_ROOTS = new Set([__ROOTS__]);
async function isAllowedMutatingGitTarget(target) {
  const canonicalTarget = await realpathNearestExistingAsync(target);
  for (const root of ALLOWED_MUTATING_GIT_REPOSITORY_ROOTS) {
    if (isWithinRoot(canonicalTarget, await realpathNearestExistingAsync(root))) return true;
  }
  return false;
}
__name(isAllowedMutatingGitTarget, "isAllowedMutatingGitTarget");
// LOCAL PATCH 2026-10-01 (honest denial): two denials used to reuse the "mutating Git command"
// prefix for a decision that is not a git invocation at all - a run the guard does not model, and
// a requested working directory. Name what was actually matched instead of asserting a mutation.
// The wording says "names git" rather than "in command position" on purpose: the token test is
// deliberately fail-closed, so it accepts ANY program-shaped git token (which is what catches an
// unmodelled wrapper such as `nice -n 5 git -C <other> commit`), and that token can be an
// argument. Claiming command position would overstate what was matched.
function denyUnrecognizedGitToken(token, target) {
  const matched = token === void 0 ? "git" : JSON.stringify(token.text);
  const prefix = `Daemon shell guard denied a shell command: its text contains the token ${matched}, which names git, and its working directory is outside the session working directory: `;
  return { allowed: false, reason: prefix + sanitizeDenialPath(target, prefix) };
}
__name(denyUnrecognizedGitToken, "denyUnrecognizedGitToken");
var WORKDIR_OUTSIDE_DENIAL_PREFIX = "Daemon shell guard denied a shell command whose requested working directory is outside the session working directory: ";
'''
INSERTED_BLOCK = INSERTED_BLOCK.replace("__ROOTS__", roots_literal)

A1_OLD = 'if(!run.some(token=>GIT_WORD_PATTERN.test(token.text)))return void 0;'
A1_NEW = 'if(!run.some(token=>isGitCommandPositionToken(token)))return void 0;'
A2_OLD = 'async function evaluateUnrecognizedRun(run,state,basisCwd,context,relink){'
A2_NEW = INSERTED_BLOCK + A2_OLD

W1_OLD = 'if(!isWithinRoot(repositoryTarget,context.canonicalEffectiveCwd)){return denyTarget(OUTSIDE_TARGET_DENIAL_PREFIX,repositoryTarget)}'
W1_NEW = 'if(!isWithinRoot(repositoryTarget,context.canonicalEffectiveCwd)&&!await isAllowedMutatingGitTarget(repositoryTarget)){return denyTarget(OUTSIDE_TARGET_DENIAL_PREFIX,repositoryTarget)}'
W2_OLD = 'if(!isWithinRoot(canonicalDiscovered,context.canonicalEffectiveCwd)){return denyTarget(OUTSIDE_TARGET_DENIAL_PREFIX,canonicalDiscovered)}'
W2_NEW = 'if(!isWithinRoot(canonicalDiscovered,context.canonicalEffectiveCwd)&&!await isAllowedMutatingGitTarget(canonicalDiscovered)){return denyTarget(OUTSIDE_TARGET_DENIAL_PREFIX,canonicalDiscovered)}'
W3_OLD = 'const canonicalBasis=await realpathNearestExistingAsync(basisCwd);if(!isWithinRoot(canonicalBasis,context.canonicalEffectiveCwd)){return denyTarget(OUTSIDE_TARGET_DENIAL_PREFIX,canonicalBasis)}'
W3_NEW = 'const canonicalBasis=await realpathNearestExistingAsync(basisCwd);if(!isWithinRoot(canonicalBasis,context.canonicalEffectiveCwd)&&!await isAllowedMutatingGitTarget(canonicalBasis)){return denyUnrecognizedGitToken(run.find(token=>isGitCommandPositionToken(token)),canonicalBasis)}'
W4_OLD = 'if(!isWithinRoot(startDirectory,canonicalEffectiveCwd)){return denyTarget(OUTSIDE_TARGET_DENIAL_PREFIX,startDirectory)}'
W4_NEW = 'if(!isWithinRoot(startDirectory,canonicalEffectiveCwd)){return denyTarget(WORKDIR_OUTSIDE_DENIAL_PREFIX,startDirectory)}'

hunks = []
if style == "0245":
    STOCK = 'var RELOCATED_READ_ONLY_GIT_SUBCOMMANDS = /* @__PURE__ */ new Set(["cat-file", "rev-parse"]);'
    hunks.append(("read-only allowlist", STOCK, 'var RELOCATED_READ_ONLY_GIT_SUBCOMMANDS = /* @__PURE__ */ new Set([\n' + VERBS_AND_COMMENT + ']);'))
elif style == "0246":
    # 0.24.6 spelling: `var` present, no @__PURE__ annotation, no spaces after commas.
    STOCK = 'var RELOCATED_READ_ONLY_GIT_SUBCOMMANDS=new Set(["cat-file","rev-parse"]);'
    hunks.append(("read-only allowlist", STOCK, 'var RELOCATED_READ_ONLY_GIT_SUBCOMMANDS=new Set([\n' + VERBS_AND_COMMENT + ']);'))

# The replacement replaces the whole declaration, so every verb the stock set carried must be
# present in it.  This is the check that would have caught the 2026-09-27 drop.
for label, _old, new in hunks:
    if label == "read-only allowlist":
        for required in ('"cat-file"', '"rev-parse"'):
            if required not in new:
                raise SystemExit(f"refusing to patch: {required} is missing from the replacement allowlist")

# States 2 and 3 are applied in the same pass, so one window reload covers both.
hunks += [
    ("git-token rule: predicate at the evaluateUnrecognizedRun entry", A1_OLD, A1_NEW),
    ("git-token rule: helpers inserted before evaluateUnrecognizedRun", A2_OLD, A2_NEW),
    ("mutating-repo allowlist: git-invocation repository gate", W1_OLD, W1_NEW),
    ("mutating-repo allowlist: discovered-repository gate", W2_OLD, W2_NEW),
    ("mutating-repo allowlist: unrecognized-run gate + honest denial", W3_OLD, W3_NEW),
    ("honest denial: directory-argument working-directory gate", W4_OLD, W4_NEW),
]

applied = []
already = []
for label, old, new in hunks:
    if new in src:
        already.append(label)
        continue
    count = src.count(old)
    if count != 1:
        raise SystemExit(
            f"refusing to patch: the anchor for '{label}' occurs {count} times (expected exactly 1)"
        )
    src = src.replace(old, new)
    applied.append(label)

# Post-conditions: everything this patch promises must be present in the text about to be written.
for symbol in (
    '"cat-file"',
    '"rev-parse"',
    "isGitCommandPositionToken",
    "isAllowedMutatingGitTarget",
    "ALLOWED_MUTATING_GIT_REPOSITORY_ROOTS",
    "denyUnrecognizedGitToken",
    "WORKDIR_OUTSIDE_DENIAL_PREFIX",
):
    if symbol not in src:
        raise SystemExit(f"refusing to patch: post-condition failed, {symbol} is absent from the result")
for root in roots:
    if json.dumps(root) not in src:
        raise SystemExit(f"refusing to patch: post-condition failed, allowlisted root {root} is absent")

for label in applied:
    print(f"  patched  {label}")
for label in already:
    print(f"  already  {label}")
print(f"  roots    mutating-git allowlist: {', '.join(roots)}")

p.write_text(src, encoding="utf-8")
PY
    then
        rm -f "$backup"
        echo "  MISMATCH $name — an anchor did not match; the chunk is UNCHANGED and the backup removed" >&2
        rc=1
        continue
    fi

    if node --check "$f"
    then
        echo "  ok       $name (syntax verified)"
    else
        echo "  BROKEN   $name — rolling back from $backup" >&2
        cp -p "$backup" "$f"
        rc=1
    fi
done

if (( rc == 0 ))
then
    echo "qwen-guard-patch: done. The patch is loaded per daemon/window, so a VS Code WINDOW RELOAD is required before it takes effect; the next companion update reverts it (re-check with --check)."
fi
exit "$rc"
# end of file
