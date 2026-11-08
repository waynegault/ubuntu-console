#!/usr/bin/env bash
# shellcheck shell=bash
# ==============================================================================
# check-hooks-path.sh — refuse to believe a green whose hooks belong to another tree.
# ==============================================================================
# WHY (card 3604e43f, measured 2026-11-06T23:0xZ):
#
#   git config core.hooksPath  ->  /home/wayne/wt/autotune-baseline-002/tools/hooks
#
# A linked WORKTREE of this same repository. Every gate then ran from that tree's
# content: tools/hooks/pre-commit's check-module-versions.sh resolves its repository
# from its OWN path ("cd $(dirname "$0")/../.."), so it compared a stage against a PEER
# worktree's HEAD and refused a commit for a bump that was plainly present. The pre-push
# hook has the same shape — it judges REPO_ROOT's HEAD, so a push from another worktree
# is gated on content that is not the content being pushed.
#
# The inverse is worse than the false red: when the peer worktree is removed, the path
# disappears and git SILENTLY SKIPS missing hooks. The gates stop running with no error,
# which is a green about nothing at all.
#
# The scope sentence this guard enforces: "the hooks that judge this tree are this tree's
# own hooks". It reads config plus the worktree list and fails loudly on the two ways
# that scope silently widens — pointing at a peer worktree, or pointing nowhere.
#
# Exit: 0 the hooks belong to this tree; 1 refused, with the reason named on stdout.
# ==============================================================================
# AI INSTRUCTION: Increment Module Version on significant changes.
# Module Version: 4
#   v4 (2026-11-08): the repo-wide `# end of file` sentinel, which every tools/*.sh must
#     carry — the nightly's hygiene case 131 was red on this file alone.
#   v3 (2026-11-07): the pre-push hook's materialised checkout is skipped by design. That copy
#   is made to be READ, no commit starts in it, and its core.hooksPath correctly names the real
#   tree — so "the hooks that judge this tree must be this tree's own" does not apply there.
#   The hook sets TAC_GATES_SCRATCH_WORKTREE=1; without it this guard read the case as a PEER
#   WORKTREE and refused every push made while another lane had edits. The skip is keyed on
#   that variable alone, so an ordinary tree is judged exactly as before.
#   v2 (2026-11-07): every message goes through warn/die, so the tool carries one stderr path
#   instead of two hand-written ones (18.3 10.7) and its usage status is an argument rather
#   than a literal exit code (9.7).  The worktree loop states its default arm (4.2.4) and
#   realpath_or_self gains the comment it was missing (9.5).  Behaviour unchanged.
set -uo pipefail

# warn — one message per call, on stderr. The redirect is grouped, not on the printf line,
# in the shape tools/sync-openclaw-completion.sh uses for the same job.
warn() {
    {
        printf 'check-hooks-path: %s\n' "$*"
    } >&2
}

# die <code> <message> — warn, then exit with the status the header documents. The code is
# passed rather than written in, so the header stays the one place the exit statuses are
# explained (64 = EX_USAGE).
die() {
    local _code="$1"; shift
    warn "$*"
    exit "$_code"
}

REPO=""
while (( $# > 0 )); do
    case "$1" in
        --repo) REPO="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
        *) die 64 "unknown argument: $1" ;;
    esac
done

if [[ -z "$REPO" ]]; then
    REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
# swallow-ok: a bad --repo is reported by the REFUSED line below; the cd's own noise adds nothing
if ! REPO="$(cd "$REPO" 2>/dev/null && pwd)"; then
    die 1 "REFUSED — no such directory"
fi

# realpath_or_self — resolve to an absolute path when realpath exists, else return the string
# unchanged, so both sides of every comparison are normalised the same way on every box.
realpath_or_self() {
    # swallow-ok: realpath is optional; the fallback returns the same string every comparison accepts
    if command -v realpath >/dev/null 2>&1; then realpath -m -- "$1"; else printf '%s\n' "$1"; fi
}

# The FIRST entry of the worktree list is the main working tree; anything else is linked.
MAIN_WORKTREE=""
while IFS= read -r line; do
    case "$line" in
        worktree\ *) MAIN_WORKTREE="$(realpath_or_self "${line#worktree }")"; break ;;
        *) ;;
    esac
# swallow-ok: not-a-git-tree is reported by the rev-parse check below; an empty list is the honest reading
done < <(git -C "$REPO" worktree list --porcelain 2>/dev/null)

# A LINKED worktree cannot carry its own core.hooksPath in shared config: the value lives in
# the common .git/config, so suggesting `git config core.hooksPath <this worktree>` would
# recreate this defect from the other side. Say what actually works.
fix_hint() {
    local expected="$1"
    if [[ -n "$MAIN_WORKTREE" && "$(realpath_or_self "$REPO")" != "$MAIN_WORKTREE" ]]; then
        printf '  fix: this is a LINKED worktree, so shared config cannot hold a value that is right\n'
        printf '       for both trees. Either name the hook path for the command:\n'
        printf '         git -c core.hooksPath=%s commit …\n' "$expected"
        printf '       or enable per-worktree config once in the main tree:\n'
        printf '         git config extensions.worktreeConfig true\n'
        printf '         git -C %s config --worktree core.hooksPath %s\n' "$REPO" "$expected"
    else
        printf '  fix: git config core.hooksPath %s\n' "$expected"
    fi
}

# CI is the one place where no hooks are installed by design: a runner has no developer
# config and the gates are the job itself. Say so rather than going red on something the
# environment cannot fix.
if [[ -n "${CI:-}${GITHUB_ACTIONS:-}" ]]; then
    echo "check-hooks-path: skipped — CI runs the gates directly, so core.hooksPath is not in scope here"
    exit 0
fi

# The pre-push hook materialises HEAD into a throwaway worktree when the tree and the commit
# disagree, and runs the gates there. That copy is READ, never committed in, so its
# core.hooksPath naming the real tree is correct — and the peer-worktree refusal below would
# otherwise fire on every push from a tree with any lane's edits in it. The hook says so
# explicitly; a tree without the marker is judged exactly as before.
if [[ "${TAC_GATES_SCRATCH_WORKTREE:-0}" == "1" ]]; then
    echo "check-hooks-path: skipped — this is the pre-push hook's scratch checkout, which never commits"
    exit 0
fi

if ! git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
    echo "check-hooks-path: skipped — $REPO is not a git working tree"
    exit 0
fi

EXPECTED="$(realpath_or_self "$REPO/tools/hooks")"
# Last value wins in git, so the last line of --get-all is the effective one.
# swallow-ok: an unset value IS what this guard refuses on two lines down, so it must not raise here
CONFIGURED="$(git -C "$REPO" config --get-all core.hooksPath 2>/dev/null | tail -n 1 || true)"

if [[ -z "$CONFIGURED" ]]; then
    echo "check-hooks-path: REFUSED — core.hooksPath is unset, so this tree's gates do not run at all."
    echo "  expected: $EXPECTED"
    fix_hint "$EXPECTED"
    echo "  A missing hook is skipped by git with no error — that is a silent green, not a pass."
    exit 1
fi

if [[ "$CONFIGURED" != /* ]]; then
    echo "check-hooks-path: REFUSED — core.hooksPath is relative ('$CONFIGURED'), so it resolves against"
    echo "  whichever directory the command ran in. Two callers then run two different gates."
    fix_hint "$EXPECTED"
    exit 1
fi

ACTUAL="$(realpath_or_self "$CONFIGURED")"

if [[ "$ACTUAL" == "$EXPECTED" ]]; then
    for hook in pre-commit pre-push; do
        if [[ ! -x "$ACTUAL/$hook" ]]; then
            echo "check-hooks-path: REFUSED — core.hooksPath is this tree's tools/hooks, but '$hook' is"
            echo "  missing or not executable, so that half of the gate is skipped silently."
            exit 1
        fi
    done
    echo "check-hooks-path: OK — hooks resolve to this tree's own tools/hooks"
    exit 0
fi

# Points somewhere else. If the destination sits inside a LINKED WORKTREE of this
# repository, name that worktree together with the revision its hooks would have judged.
PEER=""
PEER_HEAD=""
while IFS= read -r line; do
    case "$line" in
        worktree\ *)
            wt="$(realpath_or_self "${line#worktree }")"
            if [[ "$wt" != "$(realpath_or_self "$REPO")" && "$ACTUAL" == "$wt"/* ]]; then
                PEER="$wt"
                # swallow-ok: a peer whose HEAD cannot be read is named 'unknown' rather than attributed to this tree
                PEER_HEAD="$(git -C "$wt" rev-parse --short HEAD 2>/dev/null || echo unknown)"
            fi
            ;;
    esac
# swallow-ok: same list, second read — the refusal below names the peer; an empty list cannot match one
done < <(git -C "$REPO" worktree list --porcelain 2>/dev/null)

if [[ -n "$PEER" ]]; then
    echo "check-hooks-path: REFUSED — the hooks that would judge this tree belong to a PEER WORKTREE."
    echo "  core.hooksPath: $ACTUAL"
    echo "  peer worktree:  $PEER  (HEAD $PEER_HEAD)"
    echo "  Those hooks resolve their repository from their own path, so a commit or push from"
    echo "  here would be judged against $PEER_HEAD — a green about a different tree."
    fix_hint "$EXPECTED"
    exit 1
fi

echo "check-hooks-path: REFUSED — core.hooksPath points outside this repository's tools/hooks."
echo "  core.hooksPath: $ACTUAL"
echo "  expected:       $EXPECTED"
fix_hint "$EXPECTED"
exit 1
# end of file
