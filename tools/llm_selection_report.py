#!/usr/bin/env python3
"""One selection artefact: throughput, contract failures and correctness TOGETHER.

The console measures the three dimensions in three places — `tools/llm_benchmark.py`
(TTFT, decode/prefill rates), `tools/llm_task_quality.py` (response contract, typed
codes) and `tools/llm_outcome_cases.py` (right answers).  Each says something the
others do not, and none of them says "this model is the best one to use".  A reader
had to hold three outputs in their head and reconcile them, which is how a fast
model with wrong answers keeps winning: the number that would have disqualified it
never appeared on the same page as the number that qualified it.

This tool is that page.  It joins the registry's certified figures to whatever
measured outcomes exist and prints ONE table, then states what it could not cover.

It cannot invent a dimension.  A model with no correctness observation is printed
with `quality = no observation` and is listed again under "coverage", and if NO
model has one the report says in the header that the selection is quality-blind —
recording the trade-off instead of leaving it as an unstated default.

# REF: "Jev Your Engines: Seven Open Decision Models vs. a Generative LLM"
# (Lambert Leong, TDS, 2026-10-15) —
# https://towardsdatascience.com/jev-your-engines-seven-open-decision-models-vs-a-generative-llm/
# The article's recipe for a comparison: "Give them the same requests and menus.
# Measure correct routes, invalid outputs, latency and abstentions together."  The
# load-bearing word is TOGETHER — a comparison that reports throughput in one tool and
# a format check in another has not measured the thing the choice turns on.  It also
# separates DOCUMENTED capability from a MEASURED number; every column below is a
# number read from a file, and an absent one is printed as absent.

Usage:
    python tools/llm_selection_report.py                       # markdown to stdout
    python tools/llm_selection_report.py --json
    python tools/llm_selection_report.py --recommended 7 \
        --outcomes ~/.llm/outcomes/latest.json --out ~/.llm/selection.md
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from dataclasses import dataclass, field
from typing import Any

# Registry columns (schema v6 + the 2b measurement columns), 1-based as documented
# in docs/llm.md.  Named here rather than used as bare indexes so a schema move
# breaks one line instead of every reader.
COL_NUM = 0
COL_NAME = 1
COL_FILE = 2
COL_SIZE = 3
COL_TPS = 16
COL_WORKLOAD = 32
COL_TTFT = 33
COL_MEAS_STATE = 43
REGISTRY_COLUMNS = 44

# Outcomes, in the order a reader should care about them.
OUTCOME_COLUMNS = ("correct", "incorrect", "abstain", "invalid")


def _norm_key(text: str) -> str:
    """Normalise a model identifier to a join key: basename, no .gguf, casefolded."""
    base = os.path.basename(text.strip()).casefold()
    return base[:-5] if base.endswith(".gguf") else base


@dataclass
class RegistryRow:
    """One model's certified figures, as the registry recorded them."""

    num: str
    name: str
    size_gb: str
    tps: str
    workload: str
    ttft_ms: str
    meas_state: str
    file: str = ""

    @property
    def key(self) -> str:
        """Join key from the display name."""
        return _norm_key(self.name)

    @property
    def file_key(self) -> str:
        """Join key from the artifact FILENAME, which is what a server reports."""
        return _norm_key(self.file) if self.file.strip() else ""

    def matches(self, key: str) -> bool:
        """True when `key` names this model by display name OR by artifact filename.

        Both are needed: the registry calls model #12 "Nexus Legal" but launches
        `Nexus-Legal-Q4_K_M.gguf`, and the server reports whichever one it was told
        to.  Matching only one of them would silently drop a measured model from the
        report, which reads exactly like "no observation".
        """
        return key in {self.key, self.file_key} - {""}

    @property
    def certified(self) -> bool:
        return self.meas_state.strip().casefold() == "certified"

    @property
    def tps_number(self) -> float | None:
        raw = self.tps.strip().split()
        if not raw:
            return None
        try:
            return float(raw[0])
        except ValueError:
            return None


@dataclass
class Dimension:
    """What one measurement file actually covered."""

    source: str
    present: bool = False
    detail: str = ""
    models: list[str] = field(default_factory=list)


def parse_registry(path: str) -> list[RegistryRow]:
    """Read the pipe-delimited registry, padding legacy short rows.

    A row shorter than the current schema is padded rather than skipped: an old
    20-column registry is still a valid input and its rows simply carry no
    `workload` / `meas_state`, which the report then prints as absent.
    """
    rows: list[RegistryRow] = []
    if not path or not os.path.exists(path):
        return rows
    with open(path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            stripped = line.rstrip("\n")
            if not stripped.strip() or stripped.lstrip().startswith("#"):
                continue
            fields = stripped.split("|")
            if len(fields) < 5:
                continue
            fields += [""] * (REGISTRY_COLUMNS - len(fields))
            rows.append(
                RegistryRow(
                    num=fields[COL_NUM].strip(),
                    name=fields[COL_NAME].strip(),
                    size_gb=fields[COL_SIZE].strip(),
                    tps=fields[COL_TPS].strip(),
                    workload=fields[COL_WORKLOAD].strip() or "-",
                    ttft_ms=fields[COL_TTFT].strip() or "-",
                    meas_state=fields[COL_MEAS_STATE].strip() or "-",
                    file=fields[COL_FILE].strip(),
                )
            )
    return rows


def outcome_for(row: RegistryRow, outcomes: dict[str, dict[str, Any]]) -> dict[str, Any] | None:
    """Return this row's outcome entry, matched on display name or filename."""
    if row.key in outcomes:
        return outcomes[row.key]
    if row.file_key and row.file_key in outcomes:
        return outcomes[row.file_key]
    return None


def _outcome_files(path: str) -> list[str]:
    """Every outcomes artefact at `path`: a single file, or every *.json in a directory.

    A DIRECTORY is the normal case, because correctness is measured per model: one
    artefact per model accumulates under ~/.llm/outcomes/ and the report compares
    across them.  A single file still works for a one-model check.
    """
    if os.path.isdir(path):
        return sorted(
            os.path.join(path, name)
            for name in os.listdir(path)
            if name.endswith(".json")
        )
    return [path]


def load_outcomes(path: str) -> tuple[dict[str, dict[str, Any]], Dimension]:
    """Read `llm_outcome_cases --write` artefacts, keyed by normalised model name."""
    dimension = Dimension(source="correctness (tools/llm_outcome_cases.py)")
    if not path:
        dimension.detail = "not supplied (--outcomes)"
        return {}, dimension
    if not os.path.exists(path):
        dimension.detail = f"not found: {path}"
        return {}, dimension

    outcomes: dict[str, dict[str, Any]] = {}
    scored = 0
    for file_path in _outcome_files(path):
        with open(file_path, encoding="utf-8") as handle:
            artefact = json.load(handle)
        if not isinstance(artefact, dict):
            continue
        summary = artefact.get("summary") or {}
        model = str(artefact.get("model") or "").strip()
        results = artefact.get("results") or []
        key = _norm_key(model)
        if not key or not results:
            continue
        per_workload: dict[str, dict[str, int]] = {}
        for result in results:
            workload = str(result.get("workload") or "-")
            bucket = per_workload.setdefault(workload, {name: 0 for name in OUTCOME_COLUMNS})
            outcome = str(result.get("outcome") or "invalid")
            bucket[outcome] = bucket.get(outcome, 0) + 1
        outcomes[key] = {
            "model": model,
            "accuracy": summary.get("accuracy"),
            "by_workload": per_workload,
            "cases_total": summary.get("cases", len(results)),
            "limits": artefact.get("limits") or [],
            "results": results,
            "source": file_path,
        }
        scored += len(results)

    dimension.present = bool(outcomes)
    dimension.models = [entry["model"] for entry in outcomes.values()]
    if not outcomes:
        dimension.detail = f"no scored cases found at {path}"
    else:
        names = ", ".join(dimension.models)
        dimension.detail = f"{scored} case(s) across {len(outcomes)} model(s): {names}"
    return outcomes, dimension


def load_format(path: str) -> tuple[dict[str, Any], Dimension]:
    """Read a `llm_task_quality.py --json` result."""
    dimension = Dimension(source="format contract (tools/llm_task_quality.py)")
    if not path:
        dimension.detail = "not supplied (--format)"
        return {}, dimension
    if not os.path.exists(path):
        dimension.detail = f"file not found: {path}"
        return {}, dimension
    with open(path, encoding="utf-8") as handle:
        payload = json.load(handle)
    if not isinstance(payload, dict):
        dimension.detail = "not a single JSON object"
        return {}, dimension
    dimension.present = bool(payload.get("probes"))
    dimension.detail = (
        f"workload={payload.get('workload')} probes={payload.get('probes')} "
        f"policy={payload.get('policy')} counts={payload.get('counts')}"
    )
    return payload, dimension


def _coverage_note(rows: list[RegistryRow], outcomes: dict[str, dict[str, Any]]) -> list[str]:
    """Name the models that have no correctness observation, so coverage is visible."""
    missing = [row for row in rows if outcome_for(row, outcomes) is None]
    if not missing:
        return []
    names = ", ".join(f"#{row.num}" for row in missing[:12])
    more = "" if len(missing) <= 12 else f" (+{len(missing) - 12} more)"
    return [f"no correctness observation for {len(missing)} model(s): {names}{more}"]


def best_measured(
    outcomes: dict[str, dict[str, Any]], rows: list[RegistryRow], workload: str | None = None
) -> tuple[str, dict[str, int]] | None:
    """Return the model with the best measured outcome, and its counts.

    Ranked on CORRECT first (the only column that says an answer was right), then on
    fewest invalid, then on fewest incorrect, then on certified TPS.  A model with
    no observation is never "best" — absent evidence cannot win an ordering.
    """
    candidates: list[tuple[tuple[int, int, int, float], str, dict[str, int]]] = []
    tps_by_key: dict[str, float] = {}
    for row in rows:
        for candidate in (row.key, row.file_key):
            if candidate:
                tps_by_key[candidate] = row.tps_number or 0.0
    for key, entry in outcomes.items():
        by_workload: dict[str, dict[str, int]] = {
            str(name): {col: int(bucket.get(col, 0) or 0) for col in OUTCOME_COLUMNS}
            for name, bucket in (entry.get("by_workload") or {}).items()
        }
        counts = {name: 0 for name in OUTCOME_COLUMNS}
        if workload and workload in by_workload:
            counts = dict(by_workload[workload])
        elif not workload:
            for bucket in by_workload.values():
                for name in OUTCOME_COLUMNS:
                    counts[name] += bucket[name]
        if not any(counts.values()):
            continue
        rank = (
            -counts["correct"],
            counts["invalid"],
            counts["incorrect"],
            -tps_by_key.get(key, 0.0),
        )
        candidates.append((rank, str(entry.get("model") or key), counts))
    if not candidates:
        return None
    candidates.sort(key=lambda item: item[0])
    return candidates[0][1], candidates[0][2]


def agreement(
    recommended: str,
    outcomes: dict[str, dict[str, Any]],
    rows: list[RegistryRow],
) -> dict[str, Any]:
    """Was the recommended model the one with the best measured task outcome?

    This is the recommender's own quality as a number.  `available=False` with a
    reason is the honest answer when nothing was measured — a recommendation is not
    "correct" because no counter-evidence exists.
    """
    if not recommended:
        return {"available": False, "reason": "no recommendation supplied (--recommended)"}
    if not outcomes:
        return {"available": False, "reason": "no correctness observations"}
    match: RegistryRow | None = None
    wanted = recommended.strip()
    for row in rows:
        if row.num == wanted or row.matches(_norm_key(wanted)):
            match = row
            break
    if match is None:
        return {"available": False, "reason": f"model {recommended!r} is not in the registry"}
    best = best_measured(outcomes, rows, match.workload if match.workload != "-" else None)
    if best is None:
        return {"available": False, "reason": "no scored cases for this workload"}
    best_name, best_counts = best
    return {
        "available": True,
        "recommended": match.name,
        "recommended_num": match.num,
        "workload": match.workload,
        "best_measured": best_name,
        "best_counts": best_counts,
        "agree": match.matches(_norm_key(best_name)),
    }


def render_markdown(
    rows: list[RegistryRow],
    outcomes: dict[str, dict[str, Any]],
    fmt: dict[str, Any],
    dims: list[Dimension],
    agreement_result: dict[str, Any],
) -> str:
    lines: list[str] = []
    lines.append("# Model selection report")
    lines.append("")
    quality_blind = not outcomes
    if quality_blind:
        lines.append(
            "**QUALITY-BLIND**: no correctness observation is available, so this report "
            "ranks on throughput and contract shape only. The recommended model is "
            "therefore the fastest one that did not break the tool contract — a faster "
            "model with worse answers cannot lose under this evidence."
        )
    else:
        lines.append(
            "All three dimensions appear below. `correct/incorrect/abstain/invalid` come "
            "from the held-out outcome cases; a model with no observation says so rather "
            "than inheriting a neighbour's figure."
        )
    lines.append("")
    header = (
        "| # | model | workload | tps | ttft ms | meas | "
        "correct | incorrect | abstain | invalid |"
    )
    lines.append(header)
    lines.append("|---|-------|----------|-----|---------|------|" + "---|" * 4)
    for row in rows:
        entry = outcome_for(row, outcomes)
        if entry:
            counts = {name: 0 for name in OUTCOME_COLUMNS}
            for bucket in (entry.get("by_workload") or {}).values():
                for name in OUTCOME_COLUMNS:
                    counts[name] += int(bucket.get(name, 0))
            quality = " | ".join(str(counts[name]) for name in OUTCOME_COLUMNS)
        else:
            quality = "no observation | | | "
        tps = row.tps or "-"
        lines.append(
            f"| {row.num} | {row.name} | {row.workload} | {tps} | {row.ttft_ms} | "
            f"{row.meas_state} | {quality} |"
        )
    lines.append("")
    if fmt:
        lines.append(
            f"Format contract: workload={fmt.get('workload')} probes={fmt.get('probes')} "
            f"policy={fmt.get('policy')} counts={json.dumps(fmt.get('counts'))}"
        )
        lines.append("")
    if agreement_result.get("available"):
        verdict = "AGREES" if agreement_result.get("agree") else "DISAGREES"
        lines.append(
            f"Recommendation check: recommended `{agreement_result['recommended']}` "
            f"(#{agreement_result['recommended_num']}, workload "
            f"{agreement_result['workload']}); best measured `"
            f"{agreement_result['best_measured']}` {agreement_result['best_counts']} — "
            f"{verdict}."
        )
    else:
        lines.append(f"Recommendation check: not available — {agreement_result.get('reason')}.")
    lines.append("")
    lines.append("## Coverage and limits")
    lines.append("")
    for dimension in dims:
        state = "present" if dimension.present else "ABSENT"
        lines.append(f"- {dimension.source}: **{state}** — {dimension.detail}")
    for note in _coverage_note(rows, outcomes):
        lines.append(f"- {note}")
    limits: list[str] = []
    for entry in outcomes.values():
        limits.extend(entry.get("limits") or [])
    for limit in dict.fromkeys(limits):
        lines.append(f"- {limit}")
    if quality_blind:
        lines.append(
            "- A throughput winner is not a quality winner. Run "
            "`tools/llm_outcome_cases.py --run --write` to give the next report a "
            "quality axis."
        )
    return "\n".join(lines).rstrip() + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--registry",
        default=os.environ.get("LLM_REGISTRY") or os.path.expanduser("~/.llm/models.conf"),
        help="pipe-delimited model registry (default: $LLM_REGISTRY)",
    )
    parser.add_argument(
        "--outcomes",
        help=(
            "correctness artefact from tools/llm_outcome_cases.py --write, or a "
            "DIRECTORY of them (one per model) so models can be compared"
        ),
    )
    parser.add_argument("--format", dest="format_path", help="JSON from tools/llm_task_quality.py --json")
    parser.add_argument(
        "--recommended",
        default="",
        help="the model number (or artifact name) the recommender chose, for the agreement check",
    )
    parser.add_argument("--json", action="store_true", help="emit the report as JSON")
    parser.add_argument("--out", help="also write the markdown report to this path")
    args = parser.parse_args()

    rows = parse_registry(args.registry)
    if not rows:
        print(f"selection report: no registry rows read from {args.registry}", file=sys.stderr)
        return 1
    outcomes, outcomes_dim = load_outcomes(args.outcomes)
    fmt, format_dim = load_format(args.format_path)
    agreement_result = agreement(args.recommended, outcomes, rows)
    markdown = render_markdown(rows, outcomes, fmt, [outcomes_dim, format_dim], agreement_result)

    if args.json:
        artefact = {
            "tool": "llm_selection_report",
            "registry": args.registry,
            "models": [
                {
                    "num": row.num,
                    "name": row.name,
                    "size_gb": row.size_gb,
                    "tps": row.tps,
                    "ttft_ms": row.ttft_ms,
                    "workload": row.workload,
                    "meas_state": row.meas_state,
                    "certified": row.certified,
                    "outcomes": (outcome_for(row, outcomes) or {}).get("by_workload"),
                }
                for row in rows
            ],
            "format": fmt,
            "recommendation": agreement_result,
            "quality_blind": not outcomes,
            "coverage_notes": _coverage_note(rows, outcomes),
        }
        printed = json.dumps(artefact)
    else:
        printed = markdown

    if args.out:
        directory = os.path.dirname(os.path.abspath(args.out))
        if directory:
            os.makedirs(directory, exist_ok=True)
        with open(args.out, "w", encoding="utf-8") as handle:
            handle.write(markdown)

    print(printed)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
