#!/usr/bin/env python3
"""CI verdict gate for ubuntu-console (CI-WATCH-CONSOLE-001).

CI is a WRITE-ONLY signal in this repo: nothing reads GitHub's verdict, so "main
is red" and "CI never ran" are both invisible until a human opens a web page.
Both classes have already happened here, measured:

* A RED main sat unread.  Nightly Full Suite 36215222418 failed on the pushed tip
  at 2026-09-26 03:34 and nothing in the repo noticed; and the same workflow had
  already failed once (36090943414) before that.  A verdict nothing reads is not
  a verdict.
* A run that never starts is indistinguishable from "no problems".  Measured
  2026-09-23: three pushes sat `queued` for over 30 minutes each, because the
  single self-hosted runner was finishing another job.

This gate treats CI status as one more GOVERNED BASELINE, in the same idiom as the
investigator's scripts/check_ci_status.py (card CI-WATCH-001): a red run may be
tolerated only while an unexpired entry names it, and every entry carries owner=,
card= and expiry= so it cannot be parked without a re-review deadline.

The rule is deliberately identical to the investigator's, with one measured
console difference that DECIDES the logic: .github/workflows/ci.yml has no
`concurrency:` block, so a superseded run is NOT cancelled — it QUEUES (observed:
three runs serially).  "The newest run" is therefore not "the newest commit's
verdict", and a completed run for an older commit is never attributed to the
current head.

RED     A completed, non-cancelled run FOR THE PUSHED TIP concluded
        failure/timed_out/startup_failure/action_required.  It BLOCKS unless an
        unexpired baseline entry names that workflow.
DARK    A commit on the branch newer than the newest run of a PUSH-TRIGGERED
        workflow: CI did not start for it.  Scoped to push-triggered runs by their
        `event`, because nightly.yml is schedule/dispatch-driven and produces no
        push run by design.
PENDING A run for the tip exists and has not completed.  "No verdict yet" — never
        green, and never red.
UNKNOWN GitHub could not be read.  This is NOT a pass: it is reported loudly and
        the gate declines to conclude (exit 2 only with --strict-unknown).

Usage:
    python3 scripts/check_ci_status.py                  # human report
    python3 scripts/check_ci_status.py --fail           # exit 1 on an unexempted red
    python3 scripts/check_ci_status.py --json
    python3 scripts/check_ci_status.py --print-baseline
    python3 scripts/check_ci_status.py --strict-unknown
"""

from __future__ import annotations

import argparse
import json
import logging
import re
import subprocess
import sys
from dataclasses import dataclass, field, replace
from datetime import UTC, date, datetime
from pathlib import Path

logger = logging.getLogger("check_ci_status")

REPO_DIR = Path(__file__).resolve().parent.parent
#: The baseline lives with the other baselines (tools/*-baseline.*); only the
#: checker is Python, and Python sources live under scripts/ (pyproject.toml).
BASELINE_FILE = REPO_DIR / "tools" / "ci-status-baseline.txt"
#: Never committed: inside .git, so it needs no .gitignore entry.
CACHE_FILE = REPO_DIR / ".git" / "console-ci-status.json"

#: Baseline line layout (shared governance format with the other baselines).
_BASELINE_FORMAT = "workflow=<name> | owner=<owner> | card=<card> | expiry=YYYY-MM-DD | reason"

#: Run conclusions that count as a red branch.
RED_CONCLUSIONS: frozenset[str] = frozenset(
    {"failure", "timed_out", "startup_failure", "action_required"}
)

_META_FIELD_RE = re.compile(r"^(owner|card|expiry)=(.+)$")

#: Fields requested from `gh run list`.  `event` is what scopes DARK to
#: push-triggered runs without a hardcoded workflow list that can drift.
_RUN_FIELDS = "workflowName,conclusion,status,headSha,createdAt,url,event"

#: One-line description for `--help` (and the module's own identity).
_SUMMARY = "CI verdict gate (CI-WATCH-CONSOLE-001): a red main blocks the gate"


def _iso_date(value: str) -> date | None:
    """Parse ``YYYY-MM-DD`` into a ``date``, or return None when invalid."""
    try:
        return date.fromisoformat(value.strip())
    except ValueError:
        logger.debug("unparseable expiry %r", value, exc_info=True)
        return None


def _parse_ts(value: str) -> datetime | None:
    """Parse a GitHub ISO-8601 UTC timestamp, or None when unparseable."""
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        logger.debug("unparseable timestamp %r", value, exc_info=True)
        return None


@dataclass(frozen=True)
class BaselineEntry:
    """One governed exemption: a workflow whose red state is tolerated."""

    workflow: str
    owner: str
    card: str
    expiry: date
    reason: str
    lineno: int

    @property
    def expired(self) -> bool:
        """True when the entry's re-review deadline has passed."""
        return self.expiry < date.today()

    def as_line(self) -> str:
        """Render in the shared baseline governance format."""
        return (
            f"workflow={self.workflow} | owner={self.owner} | card={self.card} "
            f"| expiry={self.expiry.isoformat()} | {self.reason}"
        )


@dataclass(frozen=True)
class WorkflowStatus:
    """One workflow's newest completed verdict, plus whether one is still pending.

    ``conclusion`` is empty when the workflow has no completed, non-cancelled run
    at all — which is a state of its own, not a green one.
    """

    workflow: str
    conclusion: str
    head_sha: str
    created_at: datetime | None
    url: str
    #: The newest run of this workflow (ANY status) is not completed yet.
    pending: bool = False
    pending_sha: str = ""

    @property
    def red(self) -> bool:
        """True when this workflow's newest completed verdict is a failure."""
        return self.conclusion in RED_CONCLUSIONS


@dataclass
class Report:
    """The gate's verdict, with enough detail to act on without re-querying."""

    branch: str
    tip_sha: str
    red: list[WorkflowStatus] = field(default_factory=list)
    exempted: list[tuple[WorkflowStatus, BaselineEntry]] = field(default_factory=list)
    expired_entries: list[BaselineEntry] = field(default_factory=list)
    #: Verdicts that exist but belong to a DIFFERENT commit than the pushed tip.
    superseded: list[WorkflowStatus] = field(default_factory=list)
    #: Workflows with a run for the tip that has not completed.
    pending: list[WorkflowStatus] = field(default_factory=list)
    dark: bool = False
    dark_reason: str = ""
    unknown_reason: str = ""
    newest_push_run_at: datetime | None = None
    tip_committed_at: datetime | None = None
    checked_at: datetime | None = None
    #: The local checkout's HEAD, which may be ahead of the pushed tip.
    local_sha: str = ""
    awaiting_push: bool = False
    awaiting_push_reason: str = ""

    @property
    def unknown(self) -> bool:
        """True when the status could not be determined at all."""
        return bool(self.unknown_reason)

    @property
    def failing(self) -> bool:
        """True when an unexempted red run, or an expired exemption, blocks."""
        return bool(self.red) or bool(self.expired_entries)

    @property
    def green(self) -> bool:
        """True only when every workflow has a verdict for the tip, and none is red."""
        return not (
            self.red
            or self.expired_entries
            or self.dark
            or self.unknown
            or self.superseded
            or self.pending
        )


def parse_baseline(text: str) -> list[BaselineEntry]:
    """Parse the baseline file; raise ValueError on a malformed entry.

    Strict by design — a line that cannot be parsed is an error, not a silent
    skip, so a typo cannot quietly disable the gate.
    """
    entries: list[BaselineEntry] = []
    for lineno, raw in enumerate(text.splitlines(), start=1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        head, _, tail = line.partition("|")
        workflow = head.strip()
        if not workflow.startswith("workflow="):
            raise ValueError(
                f"{BASELINE_FILE}:{lineno}: expected 'workflow=<name>', got {workflow!r}"
            )
        fields: dict[str, str] = {"workflow": workflow.split("=", 1)[1].strip()}
        for part in tail.split("|"):
            part = part.strip()
            if not part:
                continue
            match = _META_FIELD_RE.match(part)
            if match:
                fields[match.group(1)] = match.group(2).strip()
            else:
                fields["reason"] = (fields.get("reason", "") + " " + part).strip()
        missing = [k for k in ("owner", "card", "expiry") if not fields.get(k)]
        if missing:
            raise ValueError(
                f"{BASELINE_FILE}:{lineno}: missing {', '.join(missing)}; "
                f"format is {_BASELINE_FORMAT}"
            )
        expiry = _iso_date(fields["expiry"])
        if expiry is None:
            raise ValueError(
                f"{BASELINE_FILE}:{lineno}: expiry must be YYYY-MM-DD, "
                f"got {fields['expiry']!r}"
            )
        entries.append(
            BaselineEntry(
                workflow=fields["workflow"],
                owner=fields["owner"],
                card=fields["card"],
                expiry=expiry,
                reason=fields.get("reason", ""),
                lineno=lineno,
            )
        )
    return entries


def newest_per_workflow(runs: list[dict]) -> list[WorkflowStatus]:
    """Collapse a run list into one status per workflow.

    The verdict is the newest COMPLETED, non-cancelled run.  A cancelled run is
    skipped: it carries no verdict, and the run that superseded it is the one that
    counts.  Because a superseded run QUEUES here rather than being cancelled, the
    newest run of ANY status is also recorded — that is how "a run for the tip has
    not completed yet" is told apart from "no run was ever asked for".
    """
    newest_completed: dict[str, WorkflowStatus] = {}
    newest_any: dict[str, tuple[datetime | None, str, str]] = {}
    for run in runs:
        workflow = run.get("workflowName") or "<unnamed workflow>"
        created = _parse_ts(run.get("createdAt") or "")
        status = run.get("status") or ""
        sha = run.get("headSha") or ""
        current_any = newest_any.get(workflow)
        if current_any is None or (
            created is not None
            and current_any[0] is not None
            and created > current_any[0]
        ):
            newest_any[workflow] = (created, status, sha)
        if status != "completed":
            continue
        conclusion = run.get("conclusion") or ""
        if conclusion == "cancelled":
            continue
        current = newest_completed.get(workflow)
        if (
            current is not None
            and current.created_at is not None
            and created is not None
            and created <= current.created_at
        ):
            continue
        newest_completed[workflow] = WorkflowStatus(
            workflow=workflow,
            conclusion=conclusion,
            head_sha=sha,
            created_at=created,
            url=run.get("url") or "",
        )

    statuses: list[WorkflowStatus] = []
    for workflow in sorted(newest_any):
        any_created, any_status, any_sha = newest_any[workflow]
        pending = bool(any_status) and any_status != "completed"
        verdict = newest_completed.get(workflow)
        if verdict is None:
            statuses.append(
                WorkflowStatus(
                    workflow=workflow,
                    conclusion="",
                    head_sha="",
                    created_at=None,
                    url="",
                    pending=pending,
                    pending_sha=any_sha if pending else "",
                )
            )
            continue
        statuses.append(
            replace(
                verdict,
                pending=pending,
                pending_sha=any_sha if pending else "",
            )
        )
    return statuses


def evaluate(
    runs: list[dict],
    entries: list[BaselineEntry],
    *,
    branch: str,
    tip_sha: str,
    tip_committed_at: datetime | None,
    newest_push_run_at: datetime | None,
    grace_minutes: int,
    local_sha: str = "",
    awaiting_push_reason: str = "",
) -> Report:
    """Build the verdict from a run list and the baseline.

    ``tip_sha``/``tip_committed_at`` are the PUSHED tip and its committer time —
    the commit CI can have run for.  ``local_sha`` and ``awaiting_push_reason``
    describe the checkout when it is ahead of that tip; awaiting-push is its own
    reported state and is never red, dark or failing.
    """
    report = Report(
        branch=branch,
        tip_sha=tip_sha,
        newest_push_run_at=newest_push_run_at,
        tip_committed_at=tip_committed_at,
        checked_at=datetime.now(UTC),
        local_sha=local_sha,
        awaiting_push=bool(awaiting_push_reason),
        awaiting_push_reason=awaiting_push_reason,
    )
    for status in newest_per_workflow(runs):
        # No completed verdict at all for this workflow.
        if not status.head_sha:
            if status.pending:
                report.pending.append(status)
            continue
        # A verdict for a DIFFERENT commit is not this head's verdict.  With no
        # `concurrency:` in ci.yml a superseded run queues rather than cancels, so
        # the newest completed run is routinely the PREVIOUS commit's — reading its
        # green as current is the trap this branch exists to close.
        if tip_sha and status.head_sha != tip_sha:
            if status.pending:
                report.pending.append(status)
            else:
                report.superseded.append(status)
            continue
        if not status.red:
            continue
        exemption = next(
            (e for e in entries if e.workflow == status.workflow and not e.expired),
            None,
        )
        if exemption is None:
            report.red.append(status)
        else:
            report.exempted.append((status, exemption))
    report.expired_entries = [e for e in entries if e.expired]

    # DARK: a commit on the branch with no run after it.  Counted against
    # PUSH-TRIGGERED runs only (event == "push"); a scheduled nightly says nothing
    # about whether a push produced a run.  The grace window keeps a run that is
    # merely still starting from reading as dark.
    if tip_committed_at is not None:
        if newest_push_run_at is None:
            report.dark = True
            report.dark_reason = "no push-triggered run found on the branch at all"
        else:
            lag_minutes = (tip_committed_at - newest_push_run_at).total_seconds() / 60
            if lag_minutes > grace_minutes:
                report.dark = True
                report.dark_reason = (
                    f"HEAD landed {lag_minutes:.0f} min after the newest "
                    f"push-triggered run (grace {grace_minutes} min) — CI did not "
                    f"start for it"
                )
    return report


def _push_run_stamps(runs: list[dict]) -> list[datetime]:
    """The created-at stamps of runs a PUSH produced.

    Read from the API's own ``event`` field rather than a hardcoded workflow list:
    a list would have to be updated the day a second push-triggered workflow is
    added, and nothing would fail until DARK was judged wrongly.
    """
    stamps = []
    for run in runs:
        if (run.get("event") or "") != "push":
            continue
        stamp = _parse_ts(run.get("createdAt") or "")
        if stamp is not None:
            stamps.append(stamp)
    return stamps


class CiStatusUnknown(RuntimeError):
    """Raised when GitHub's verdict cannot be obtained."""


def _gh_json(args: list[str], *, timeout: int) -> object:
    """Call ``gh`` and return its parsed JSON, raising CiStatusUnknown."""
    cmd = ["gh", *args]
    logger.debug("running: %s", " ".join(cmd))
    try:
        proc = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout, check=False
        )
    except (OSError, subprocess.SubprocessError) as exc:
        logger.debug("gh invocation failed", exc_info=True)
        raise CiStatusUnknown(f"cannot execute gh: {exc}") from exc
    if proc.returncode != 0:
        stderr = (proc.stderr or "").strip().splitlines()
        detail = stderr[-1] if stderr else f"exit {proc.returncode}"
        raise CiStatusUnknown(f"gh exited {proc.returncode}: {detail}")
    try:
        return json.loads(proc.stdout or "null")
    except json.JSONDecodeError as exc:
        logger.debug("gh returned non-JSON", exc_info=True)
        raise CiStatusUnknown(f"gh returned unparseable JSON: {exc}") from exc


def _run_gh(args: list[str], *, timeout: int) -> list[dict]:
    """Call ``gh`` and return parsed JSON rows, raising CiStatusUnknown."""
    parsed = _gh_json(args, timeout=timeout)
    if not isinstance(parsed, list):
        raise CiStatusUnknown("gh returned a non-list for --json runs")
    return parsed


def repo_slug() -> str:
    """Resolve ``owner/name`` from the origin remote without an API call."""
    proc = subprocess.run(
        ["git", "remote", "get-url", "origin"],
        cwd=REPO_DIR,
        capture_output=True,
        text=True,
        check=False,
        timeout=30,
    )
    if proc.returncode != 0:
        raise CiStatusUnknown("no git origin remote to derive owner/name from")
    url = (proc.stdout or "").strip()
    tail = url.rsplit(":", 1)[-1] if url.startswith("git@") else url
    tail = tail.removesuffix(".git").rstrip("/")
    parts = [p for p in tail.split("/") if p]
    if len(parts) < 2:
        raise CiStatusUnknown(f"cannot parse owner/name from origin url {url!r}")
    return f"{parts[-2]}/{parts[-1]}"


def local_head() -> tuple[str, datetime | None]:
    """Return (HEAD sha, HEAD committer time) for the current checkout."""
    proc = subprocess.run(
        ["git", "log", "-1", "--format=%H%x00%cI", "--no-merges"],
        cwd=REPO_DIR,
        capture_output=True,
        text=True,
        check=False,
        timeout=30,
    )
    if proc.returncode != 0:
        raise CiStatusUnknown("cannot read HEAD from git")
    sha, _, ts = (proc.stdout or "").strip().partition("\x00")
    return sha, _parse_ts(ts)


def pushed_tip(slug: str, branch: str, *, timeout: int = 60) -> tuple[str, datetime | None]:
    """Return (sha, committer time) of the branch tip AS THE REMOTE HAS IT.

    DARK asks whether CI was asked to run for the tip and did not.  The local
    checkout answers a different question: a commit that has landed locally but not
    been pushed has no run because nobody pushed it, and reading that as dark would
    refuse unrelated commits for a push that has not happened yet.
    """
    payload = _gh_json(["api", f"repos/{slug}/commits/{branch}"], timeout=timeout)
    if not isinstance(payload, dict):
        raise CiStatusUnknown(f"gh returned a non-object commit payload for {slug}/{branch}")
    sha = str(payload.get("sha") or "")
    commit = payload.get("commit")
    committer = commit.get("committer") if isinstance(commit, dict) else None
    stamp = committer.get("date") if isinstance(committer, dict) else None
    return sha, _parse_ts(stamp or "")


def _write_cache(report: Report) -> None:
    """Record the last successful probe so a later offline run is informed.

    ``newest_push_run_at`` is the load-bearing field for stale-feed detection: it is
    the high-water mark a later probe must not go backwards from.
    """
    payload = {
        "checked_at": (report.checked_at or datetime.now(UTC)).isoformat(),
        "branch": report.branch,
        "tip_sha": report.tip_sha,
        "red": [s.workflow for s in report.red],
        "exempted": [s.workflow for s, _ in report.exempted],
        "dark": report.dark,
        "dark_reason": report.dark_reason,
        "newest_push_run_at": (
            report.newest_push_run_at.isoformat()
            if report.newest_push_run_at is not None
            else None
        ),
        "local_sha": report.local_sha,
        "awaiting_push_reason": report.awaiting_push_reason,
    }
    try:
        CACHE_FILE.parent.mkdir(parents=True, exist_ok=True)
        CACHE_FILE.write_text(json.dumps(payload, indent=2) + "\n")
    except OSError:
        logger.debug("could not write CI status cache", exc_info=True)


def _read_cache_payload() -> dict | None:
    """The last recorded probe at ANY age, or None when there is not one.

    Used for the newest-run high-water mark, which stays meaningful long after the
    verdict itself is too old to reuse.
    """
    try:
        payload = json.loads(CACHE_FILE.read_text())
    except (OSError, json.JSONDecodeError):
        logger.debug("no usable CI status cache", exc_info=True)
        return None
    return payload if isinstance(payload, dict) else None


def _read_cache(ttl_seconds: int, payload: dict | None = None) -> dict | None:
    """Return the cached probe when it is still within the TTL, else None."""
    if payload is None:
        payload = _read_cache_payload()
    if payload is None:
        return None
    checked = payload.get("checked_at")
    ts = _parse_ts(checked) if isinstance(checked, str) else None
    if ts is None:
        return None
    age = (datetime.now(UTC) - ts).total_seconds()
    if age > ttl_seconds:
        logger.debug("CI status cache is stale (%.0fs > %ds)", age, ttl_seconds)
        return None
    return payload


def _feed_went_backwards(
    newest_run_at: datetime | None, watermark: datetime | None
) -> bool:
    """True when a probe reports a newest run OLDER than one already observed.

    The runs feed is monotonic in time, so a response whose newest run predates a
    run already seen cannot describe the current branch state — it is stale or
    partial, and NOT evidence about whether main is red.  The investigator measured
    exactly this on 2026-09-23: two probes seconds apart disagreed, one of them
    weeks stale, and the stale one reported three red workflows plus DARK.
    """
    return newest_run_at is not None and watermark is not None and newest_run_at < watermark


def _print_report(report: Report) -> None:
    """Render the verdict for a human."""
    tip = report.tip_sha[:12] if report.tip_sha else "<unknown>"
    print(f"CI status gate — {report.branch} @ {tip}")
    if report.local_sha and report.local_sha != report.tip_sha:
        print(f"  local HEAD      : {report.local_sha[:12]}")
    if report.checked_at is not None:
        print(f"  checked at      : {report.checked_at.isoformat()}")
    if report.newest_push_run_at is not None:
        print(f"  newest push run : {report.newest_push_run_at.isoformat()}")
    for status in report.red:
        print(f"  RED             : {status.workflow} — {status.conclusion}  {status.url}")
    for status, entry in report.exempted:
        print(
            f"  red (exempt)    : {status.workflow} — {status.conclusion}"
            f"  [owner={entry.owner} card={entry.card} expiry={entry.expiry}]"
        )
    for entry in report.expired_entries:
        print(
            f"  EXPIRED EXEMPT  : {entry.workflow} (expired "
            f"{entry.expiry.isoformat()}, owner={entry.owner}, card={entry.card})"
            f" — re-review or delete"
        )
    for status in report.superseded:
        print(
            f"  no verdict yet  : {status.workflow} — newest completed run is "
            f"{status.head_sha[:12]} ({status.conclusion}), not the pushed tip"
        )
    for status in report.pending:
        print(
            f"  no verdict yet  : {status.workflow} — the newest run for "
            f"{status.pending_sha[:12]} has not completed"
        )
    if report.dark:
        print(f"  DARK            : {report.dark_reason}")
    if report.awaiting_push:
        print(f"  awaiting push   : {report.awaiting_push_reason}")
    if report.unknown:
        print(f"  UNKNOWN         : {report.unknown_reason}")
    if report.green:
        if report.awaiting_push:
            print("  OK              : no unexempted red; local HEAD awaits a push")
        else:
            print("  OK              : every workflow has a verdict for the pushed tip")
    elif not report.red and not report.expired_entries and not report.unknown:
        print("  NOT GREEN       : no red, but not every workflow has a verdict for the tip")


def _to_json(report: Report) -> str:
    """Render the verdict for the machine-side reader."""
    return json.dumps(
        {
            "branch": report.branch,
            "tip_sha": report.tip_sha,
            "local_sha": report.local_sha,
            "red": [
                {"workflow": s.workflow, "conclusion": s.conclusion, "url": s.url}
                for s in report.red
            ],
            "exempted": [
                {"workflow": s.workflow, "card": e.card, "expiry": e.expiry.isoformat()}
                for s, e in report.exempted
            ],
            "expired_exemptions": [
                {"workflow": e.workflow, "expired": e.expiry.isoformat(), "card": e.card}
                for e in report.expired_entries
            ],
            "no_verdict_yet": [
                {"workflow": s.workflow, "reason": "superseded", "sha": s.head_sha}
                for s in report.superseded
            ]
            + [
                {"workflow": s.workflow, "reason": "pending", "sha": s.pending_sha}
                for s in report.pending
            ],
            "dark": report.dark,
            "dark_reason": report.dark_reason,
            "awaiting_push": report.awaiting_push,
            "awaiting_push_reason": report.awaiting_push_reason,
            "unknown": report.unknown,
            "unknown_reason": report.unknown_reason,
            "failing": report.failing,
            "green": report.green,
            "checked_at": report.checked_at.isoformat() if report.checked_at else None,
        },
        indent=2,
    )


def main(argv: list[str] | None = None) -> int:
    """Entry point. Exit 0 clean, 1 red/expired, 2 unknown (with --strict-unknown)."""
    parser = argparse.ArgumentParser(description=_SUMMARY)
    parser.add_argument("--branch", default="main", help="branch to inspect (default: main)")
    parser.add_argument("--limit", type=int, default=30, help="runs to fetch (default: 30)")
    parser.add_argument(
        "--grace-minutes",
        type=int,
        default=20,
        help="tolerate a HEAD this much newer than the newest run before calling it dark",
    )
    parser.add_argument(
        "--cache-ttl",
        type=int,
        default=600,
        help="reuse a probe this many seconds old instead of calling GitHub",
    )
    parser.add_argument("--fail", action="store_true", help="exit 1 on an unexempted red run")
    parser.add_argument("--json", action="store_true", help="emit JSON instead of prose")
    parser.add_argument(
        "--strict-unknown",
        action="store_true",
        help="exit 2 when GitHub cannot be reached (default: warn and pass)",
    )
    parser.add_argument(
        "--print-baseline",
        action="store_true",
        help="print the exemption format and any current entries, then exit",
    )
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.WARNING, format="%(levelname)s %(name)s: %(message)s")

    if args.print_baseline:
        print(f"# {BASELINE_FILE.name} — format: {_BASELINE_FORMAT}")
        if BASELINE_FILE.exists():
            print(BASELINE_FILE.read_text().rstrip())
        return 0

    entries: list[BaselineEntry] = []
    if BASELINE_FILE.exists():
        try:
            entries = parse_baseline(BASELINE_FILE.read_text())
        except ValueError as exc:
            print(f"CI status gate: malformed baseline — {exc}", file=sys.stderr)
            return 1

    # The verdict is reusable only within the TTL, but the newest-run high-water
    # mark stays meaningful at any age — that is what detects a stale feed below.
    cached_payload = _read_cache_payload()
    cached = _read_cache(args.cache_ttl, cached_payload)
    if cached is not None:
        awaiting_push_reason = cached.get("awaiting_push_reason", "")
        report = Report(
            branch=cached.get("branch", args.branch),
            tip_sha=cached.get("tip_sha", ""),
            local_sha=cached.get("local_sha", ""),
            awaiting_push=bool(awaiting_push_reason),
            awaiting_push_reason=awaiting_push_reason,
            dark=bool(cached.get("dark")),
            dark_reason=cached.get("dark_reason", ""),
            checked_at=_parse_ts(cached.get("checked_at", "")),
        )
        # A cached red is filtered through the baseline exactly as the live path
        # does: rebuilding it from the cache alone would hide a governed exemption
        # for the whole TTL, so a commit could be refused by a red the baseline
        # already parks.
        for name in cached.get("red", []):
            status = WorkflowStatus(name, "failure", "", None, "")
            exemption = next(
                (e for e in entries if e.workflow == name and not e.expired), None
            )
            if exemption is None:
                report.red.append(status)
            else:
                report.exempted.append((status, exemption))
        report.expired_entries = [e for e in entries if e.expired]
        if args.json:
            print(_to_json(report))
        else:
            _print_report(report)
            print(f"  (cached, <{args.cache_ttl}s old)")
        return 1 if (args.fail and report.failing) else 0

    # The high-water mark is a pure read of the cache, so it is computed before the
    # fetch: the retry below consults it, and it defines "this window went backwards".
    watermark = _parse_ts((cached_payload or {}).get("newest_push_run_at") or "")

    try:
        slug = repo_slug()
        head_sha, _head_time = local_head()
        # DARK asks about the PUSHED tip: a commit that is only local has no run
        # because nobody pushed it, so its committer time must not drive the dark
        # math.  A failure here is UNKNOWN, not a silent pass.
        tip_sha, tip_time = pushed_tip(slug, args.branch)
        # A single invocation intermittently returns a stale window (measured in the
        # investigator repo: two probes seconds apart disagreed), so retry ONCE.  A
        # fresh invocation almost always gets a fresh window; if BOTH attempts are
        # stale, the backwards check below still refuses to conclude — the fail-closed
        # path, which this retry must not weaken.
        for attempt in (1, 2):
            runs = _run_gh(
                [
                    "run",
                    "list",
                    "--repo",
                    slug,
                    "--branch",
                    args.branch,
                    "--limit",
                    str(args.limit),
                    "--json",
                    _RUN_FIELDS,
                ],
                timeout=60,
            )
            _known = _push_run_stamps(runs)
            if watermark is None or not _known or not _feed_went_backwards(max(_known), watermark):
                break
            logger.warning(
                "stale run window on attempt %d (%d run(s), newest=%s) — retrying once",
                attempt,
                len(runs),
                max(_known).isoformat(),
            )
    except CiStatusUnknown as exc:
        msg = (
            f"CI status UNKNOWN: {exc}.  This is NOT a pass — the branch state was "
            "not observed.  Run `gh auth status` / check connectivity, or pass "
            "--strict-unknown to make this fatal."
        )
        if args.json:
            print(json.dumps({"unknown": True, "unknown_reason": str(exc)}, indent=2))
        else:
            print(f"WARNING: {msg}", file=sys.stderr)
        return 2 if args.strict_unknown else 0

    push_stamps = _push_run_stamps(runs)
    newest_push_run_at = max(push_stamps) if push_stamps else None

    # A feed that moved BACKWARDS cannot describe the current branch, so this is a
    # stale/partial response — not a red branch and not a dark one.  Refuse to
    # conclude anything from it, and do NOT lower the high-water mark by caching it.
    if (
        newest_push_run_at is not None
        and watermark is not None
        and _feed_went_backwards(newest_push_run_at, watermark)
    ):
        reason = (
            f"stale run feed: newest push run reported "
            f"{newest_push_run_at.isoformat()} but a previous probe already saw "
            f"{watermark.isoformat()} — a monotonic feed cannot go backwards, so this "
            f"response is stale or partial (window: {len(runs)} run(s))"
        )
        if args.json:
            print(json.dumps({"unknown": True, "unknown_reason": reason}, indent=2))
        else:
            print(
                f"WARNING: CI status UNKNOWN: {reason}.  This is NOT a pass and NOT a "
                "red branch — the gate declined to conclude from it.",
                file=sys.stderr,
            )
        return 2 if args.strict_unknown else 0

    awaiting_push_reason = ""
    if head_sha and tip_sha and head_sha != tip_sha:
        awaiting_push_reason = (
            f"local HEAD {head_sha[:12]} is not the pushed tip {tip_sha[:12]} — commits "
            "are awaiting push, so no run for them is expected yet"
        )

    report = evaluate(
        runs,
        entries,
        branch=args.branch,
        tip_sha=tip_sha,
        tip_committed_at=tip_time,
        newest_push_run_at=newest_push_run_at,
        grace_minutes=args.grace_minutes,
        local_sha=head_sha,
        awaiting_push_reason=awaiting_push_reason,
    )
    _write_cache(report)
    if args.json:
        print(_to_json(report))
    else:
        _print_report(report)
    if report.failing and args.fail:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
