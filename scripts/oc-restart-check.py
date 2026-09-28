#!/usr/bin/env python3
"""Is it safe to restart WSL right now? (restart-safety)

A restart tears down this whole VM, and the things it kills do not fail as "the box went
away" - they fail as the *victim's* bug.  Measured cases on this machine: a self-hosted
runner job cut mid-flight reads as a cancellation in that repo's CI history, and another
session's benchmark pytest dies with an unexplained error.  So the question "can I
restart?" needs an answer that names what would be interrupted, not a yes.

WHAT IT CHECKS, and why each probe is shaped the way it is:

  * GitHub Actions workers - by argv[0], never by matching the command line.  A
    `pgrep -f 'Runner.Worker'` matches its own invoking command and reports a busy box
    when there is none (measured 2026-09-28), and `pgrep` without -f silently matches
    nothing for a name over 15 characters.  argv[0] can be forged by neither.

  * Other work in flight - a pytest/bench/autotune/training process, with its cwd, so the
    report can name WHICH repo is running.  A finished CI run is not an idle box and an
    empty job list is not proof of absence.

  * The CUDA card - every compute app, split into "a systemd-managed lane" (it
    self-heals: the watchdog restarts it) and "a foreign holder" (another session's run,
    which does not).  The systemd-parent test is the same criterion the stop path uses to
    decide what it may not kill.

Exit codes: 0 safe, 1 NOT safe, 2 could not measure (reported, never a silent pass -
a probe that cannot see is not a probe that says "fine").
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from dataclasses import dataclass, field

SELF = os.getpid()

#: Work that a restart would interrupt, matched on the COMMAND LINE here because there is
#: no single artefact to key on - and this list is checked against real processes, so it
#: is a finding when one matches, never a claim of absence.
WORK_MARKERS = (
    "pytest",
    "autotune-model.sh",
    "run-autotune-batch",
    "bench-rows",
    "train-timeout-runner",
    "model_selection_bench",
    "llama-bench",
)


@dataclass
class Finding:
    """One reason the answer is "not yet"."""

    kind: str
    detail: str


@dataclass
class Report:
    """What the probes saw, and the verdict they support."""

    workers: list[str] = field(default_factory=list)
    work: list[str] = field(default_factory=list)
    lanes: list[str] = field(default_factory=list)
    foreign_gpu: list[str] = field(default_factory=list)
    unreadable: list[str] = field(default_factory=list)

    def blockers(self) -> list[Finding]:
        """Everything that makes a restart unsafe, in the order a reader wants them."""
        out = [Finding("ci-worker", w) for w in self.workers]
        out += [Finding("in-flight-work", w) for w in self.work]
        out += [Finding("foreign-gpu", g) for g in self.foreign_gpu]
        return out

    @property
    def safe(self) -> bool:
        """True only when nothing was found AND every probe ran."""
        return not self.blockers() and not self.unreadable


def _argv(pid: int) -> list[str]:
    """The process's argv, or [] when it has exited or is not readable."""
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as fh:
            raw = fh.read()
    except OSError:
        return []
    return [a for a in raw.decode("utf-8", "replace").split("\0") if a]


def _cwd(pid: int) -> str:
    """The process's working directory, or '?' - which is itself worth printing."""
    try:
        return os.readlink(f"/proc/{pid}/cwd")
    except OSError:
        return "?"


def _ppid(pid: int) -> int:
    """The parent pid, or 0 when unreadable."""
    try:
        with open(f"/proc/{pid}/status", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if line.startswith("PPid:"):
                    return int(line.split()[1])
    except (OSError, ValueError, IndexError):
        return 0
    return 0


def _parent_is_systemd(parent: int) -> bool:
    """Is this pid the service manager?  exe first, then comm.

    The fallback is load-bearing, not tidiness: the USER systemd manager's
    /proc/PID/exe is EACCES for an ordinary reader (measured 2026-09-28 - pid 568,
    errno 13), and that manager is the parent every lane has.  Answering False there
    reports our own self-healing lanes as a foreign GPU holder, which inverts the whole
    verdict - so the unreadable case must fall through to comm, which is readable and
    says "systemd".
    """
    try:
        exe = os.readlink(f"/proc/{parent}/exe")
    except OSError:
        exe = ""
    if os.path.basename(exe) == "systemd":
        return True
    try:
        with open(f"/proc/{parent}/comm", encoding="utf-8", errors="replace") as fh:
            return fh.read().strip() == "systemd"
    except OSError:
        return False


def _is_systemd_managed(pid: int) -> bool:
    """A lane is a backend the service manager owns, so a restart is not destructive."""
    parent = _ppid(pid)
    if parent <= 0:
        return False
    return _parent_is_systemd(parent)


def _pids() -> list[int]:
    """Every numeric entry in /proc."""
    out = []
    for name in os.listdir("/proc"):
        if name.isdigit():
            out.append(int(name))
    return sorted(out)


def scan_workers(report: Report) -> None:
    """CI workers, by argv[0] - see the module docstring for why not the command line."""
    for pid in _pids():
        if pid == SELF:
            continue
        argv = _argv(pid)
        if argv and os.path.basename(argv[0]) == "Runner.Worker":
            report.workers.append(f"pid={pid} cwd={_cwd(pid)} {argv[0]}")


def scan_work(report: Report) -> None:
    """Test/bench/training work in flight, with the repo it belongs to."""
    for pid in _pids():
        if pid == SELF:
            continue
        argv = _argv(pid)
        if not argv:
            continue
        cmdline = " ".join(argv)
        if not any(marker in cmdline for marker in WORK_MARKERS):
            continue
        # This probe's own command line mentions every marker above; a python process
        # running THIS file is the probe, not the work it is looking for.
        if os.path.basename(argv[0]).startswith("python") and any(
            a.endswith("restart-safety.py") for a in argv
        ):
            continue
        report.work.append(f"pid={pid} cwd={_cwd(pid)}: {cmdline[:120]}")


def scan_gpu(report: Report) -> None:
    """Compute apps on the card: self-healing lanes vs another session's holder."""
    try:
        proc = subprocess.run(
            ["nvidia-smi", "--query-compute-apps=pid", "--format=csv,noheader"],
            capture_output=True,
            text=True,
            timeout=20,
            check=False,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        report.unreadable.append(f"nvidia-smi could not be run: {exc}")
        return
    if proc.returncode != 0:
        report.unreadable.append(
            f"nvidia-smi exited {proc.returncode}: {proc.stderr.strip()[:120]}"
        )
        return
    for line in proc.stdout.splitlines():
        pid_text = line.strip()
        if not pid_text.isdigit():
            continue
        pid = int(pid_text)
        argv = _argv(pid)
        where = " ".join(argv)[:100] if argv else "(cmdline unreadable)"
        if _is_systemd_managed(pid):
            report.lanes.append(f"pid={pid} {where}")
        else:
            report.foreign_gpu.append(f"pid={pid} {where}")


def gather() -> Report:
    """Run every probe and collect what they saw."""
    report = Report()
    scan_workers(report)
    scan_work(report)
    scan_gpu(report)
    return report


def render(report: Report) -> str:
    """The human answer: the verdict first, then the evidence."""
    lines: list[str] = []
    if report.safe:
        lines.append("SAFE to restart: nothing here would be interrupted.")
    elif report.unreadable:
        lines.append("CANNOT SAY: a probe could not run, so this is not a clearance.")
    else:
        lines.append("NOT SAFE to restart — these would be interrupted:")
        for finding in report.blockers():
            lines.append(f"  [{finding.kind}] {finding.detail}")
    lines.append("")
    lines.append(f"  CI workers    : {len(report.workers)}")
    lines.append(f"  in-flight work: {len(report.work)}")
    lines.append(f"  our lanes     : {len(report.lanes)} (self-healing; a restart is fine)")
    lines.append(f"  foreign GPU   : {len(report.foreign_gpu)}")
    for note in report.unreadable:
        lines.append(f"  UNMEASURED    : {note}")
    return "\n".join(lines)


def main(argv: list[str]) -> int:
    """Print the verdict; exit 0 safe, 1 not safe, 2 could not measure."""
    if "--help" in argv or "-h" in argv:
        print(__doc__)
        return 0
    report = gather()
    if "--json" in argv:
        print(
            json.dumps(
                {
                    "safe": report.safe,
                    "blockers": [{"kind": f.kind, "detail": f.detail} for f in report.blockers()],
                    "workers": report.workers,
                    "work": report.work,
                    "lanes": report.lanes,
                    "foreign_gpu": report.foreign_gpu,
                    "unreadable": report.unreadable,
                },
                indent=2,
            )
        )
    else:
        print(render(report))
    if report.unreadable:
        return 2
    return 0 if report.safe else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
