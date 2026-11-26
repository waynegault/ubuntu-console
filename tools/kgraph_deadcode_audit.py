#!/usr/bin/env python3
"""kgraph_deadcode_audit — certify kgraph's call edges against a HAND-VERIFIED sample.

THE BAR (Wayne, 2026-11-26): "zero false-unused on a 200-function sample" — 100
bash and 100 Python definitions. A false-unused means the graph reports no caller
for a function that IS called; that is the error that would get live code deleted,
so it is the only direction that fails this check. False-used is reported and
tolerated: it hides dead code, it does not destroy live code.

WHY THE TRUTH IS A FILE, NOT A HEURISTIC. Two attempted oracles were unsound and
both were caught by spot-checking:

  1. "any textual mention = used" reported 1,491 false-unused at 52.4% agreement,
     and included `_tac_cuda_lane_units`, which appears ONLY in comments.
  2. "command-position regex = used" counted `python3 -m unittest` as a call to the
     bash function `unittest`, and its `(?<![\\w.])` lookbehind excluded
     `self.method()` — manufacturing false-unused in Python.

Text matching cannot certify a dead-code verdict: bash calls have no distinctive
syntax and Python dispatch hides behind attributes, getattr and callbacks. So the
truth column in the sample file is written by a human reading the candidate sites
listed beside it. This tool never writes a truth value; `--emit` leaves the column
blank for exactly that reason.

USAGE
  kgraph_deadcode_audit.py --emit tools/kgraph-deadcode-sample.tsv [--sample 100]
  kgraph_deadcode_audit.py --check tools/kgraph-deadcode-sample.tsv
  kgraph_deadcode_audit.py --report            # totals only, no file needed

EXIT
  0  every truth=used row is seen as used by kgraph (the bar is met)
  1  at least one FALSE-UNUSED — name, file and the verified evidence are printed
  2  cannot run: the graph DB or the sample file is missing/unreadable, or a truth
     cell is blank (an unverified row is not a pass; it is an unfinished one)
"""

from __future__ import annotations

import argparse
import json
import random
import sqlite3
import sys
from contextlib import closing
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_DB = Path.home() / ".openclaw" / "kgraph.sqlite"
COLUMNS = ("lang", "name", "defined_in", "kgraph", "callers", "truth", "evidence")


def load_definitions(db: Path) -> list[dict[str, str]]:
    """Function definitions kgraph knows, with the files it believes call them."""
    if not db.is_file():
        raise SystemExit(f"kgraph_deadcode_audit: no graph DB at {db} — run `kgraph update` first")
    defs: list[dict[str, str]] = []
    # Closed explicitly: the audit runs inside pytest, where an unclosed sqlite
    # connection is a ResourceWarning, and this repo runs its suite under -W error.
    with closing(sqlite3.connect(db)) as con:
        con.row_factory = sqlite3.Row
        for row in con.execute("select id, label, payload from graph_nodes"):
            payload = json.loads(row["payload"] or "{}")
            if payload.get("type") != "function":
                continue
            lang = payload.get("language") or "python"
            defs.append(
                {
                    "id": row["id"],
                    "lang": lang,
                    "name": row["label"],
                    "defined_in": payload.get("file") or "",
                }
            )
        callers: dict[str, set[str]] = {}
        for row in con.execute("select source, target from graph_edges where label='calls'"):
            callers.setdefault(row["target"], set()).add(row["source"])
    for d in defs:
        srcs = sorted(callers.get(d["id"], ()))
        d["kgraph"] = "used" if srcs else "unused"
        d["callers"] = ",".join(s.replace("ast_file:", "").replace("ast_call:", "call:") for s in srcs[:4])
    return defs


def stratify(defs: list[dict[str, str]], per_language: int, seed: int) -> list[dict[str, str]]:
    """Deterministic, reproducible sample: `per_language` of each language, seeded.

    Sorted BEFORE sampling so the result depends on the tree's content, not on
    sqlite's row order — the same commit yields the same sample.
    """
    out: list[dict[str, str]] = []
    for lang in ("bash", "python"):
        pool = sorted(
            (d for d in defs if d["lang"] == lang),
            key=lambda d: (d["name"], d["defined_in"]),
        )
        rng = random.Random(f"{seed}:{lang}")
        out.extend(rng.sample(pool, min(per_language, len(pool))))
    return out


def emit(sample: list[dict[str, str]], path: Path) -> int:
    """Write the sample with an EMPTY truth column for a human to fill."""
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = ["\t".join(COLUMNS)]
    for d in sample:
        lines.append("\t".join((d["lang"], d["name"], d["defined_in"], d["kgraph"], d["callers"], "", "")))
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"wrote {len(sample)} rows to {path}")
    print("truth is BLANK on purpose: fill it from the call sites you read, not from this tool.")
    return 0


def read_sample(path: Path) -> list[dict[str, str]]:
    if not path.is_file():
        raise SystemExit(f"kgraph_deadcode_audit: no sample file at {path} — run --emit first")
    rows: list[dict[str, str]] = []
    for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip() or line.startswith("#"):
            continue
        cells = line.split("\t")
        if cells[0] == "lang":
            continue
        if len(cells) < len(COLUMNS):
            cells += [""] * (len(COLUMNS) - len(cells))
        row = dict(zip(COLUMNS, cells, strict=False))
        row["lineno"] = str(lineno)
        rows.append(row)
    return rows


def check(rows: list[dict[str, str]]) -> int:
    blank = [r for r in rows if r["truth"] not in ("used", "unused")]
    if blank:
        print(f"CANNOT CERTIFY: {len(blank)} row(s) have no truth value yet", file=sys.stderr)
        for r in blank[:10]:
            print(f"  line {r['lineno']}: {r['lang']} {r['name']}", file=sys.stderr)
        return 2

    false_unused = [r for r in rows if r["kgraph"] == "unused" and r["truth"] == "used"]
    false_used = [r for r in rows if r["kgraph"] == "used" and r["truth"] == "unused"]
    agree = len(rows) - len(false_unused) - len(false_used)

    by_lang: dict[str, list[dict[str, str]]] = {}
    for r in rows:
        by_lang.setdefault(r["lang"], []).append(r)
    print(f"sample: {len(rows)} definitions")
    for lang in sorted(by_lang):
        group = by_lang[lang]
        fu = sum(1 for r in group if r["kgraph"] == "unused" and r["truth"] == "used")
        print(f"  {lang:7s} {len(group):4d} definitions, {fu} false-unused")

    if false_unused:
        print(f"\nFAIL — {len(false_unused)} FALSE-UNUSED (the bar is zero):")
        for r in false_unused:
            print(f"  {r['lang']:7s} {r['name']:36s} {r['defined_in']}")
            print(f"          verified evidence: {r['evidence']}")
    if false_used:
        print(f"\nnote — {len(false_used)} false-used (tolerated: hides dead code, deletes nothing)")
        for r in false_used[:10]:
            print(f"  {r['lang']:7s} {r['name']:36s} kgraph callers: {r['callers'] or '(none)'}")
    print(f"\nagreement {agree}/{len(rows)} = {100.0 * agree / len(rows):.1f}%")
    if false_unused:
        return 1
    print("PASS — no live function is reported dead on this sample")
    return 0


def report(db: Path) -> int:
    """Caller coverage, split production from test code.

    The split is the measurement.  Quoting one figure over both populations read
    41.8% for Python, because 1,581 of its 2,560 functions are pytest test functions
    that pytest collects BY NAME and nothing calls.  Production Python reads 85.5% on
    the same graph (measured 2026-11-26), and the two populations answer different
    questions, so they are never summed.
    """
    defs = load_definitions(db)
    for lang in ("bash", "python"):
        group = [d for d in defs if d["lang"] == lang]
        prod = [d for d in group if not _test_side(d["defined_in"])]
        test = [d for d in group if _test_side(d["defined_in"])]
        for label, subset in (("production", prod), ("tests/", test)):
            used = sum(1 for d in subset if d["kgraph"] == "used")
            share = 100.0 * used / max(len(subset), 1)
            print(f"{lang:7s} {label:11s} {used:5d}/{len(subset):5d} with a caller ({share:5.1f}%)")
    return 0


def _test_side(path: str) -> bool:
    """A path that ships with the test suite rather than the product."""
    lowered = path.replace("\\", "/").lower()
    return "/tests/" in f"/{lowered}" or lowered.startswith("tests/")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0] if __doc__ else "")
    parser.add_argument("--db", type=Path, default=DEFAULT_DB)
    parser.add_argument("--emit", type=Path, metavar="TSV", help="write a sampling template")
    parser.add_argument("--check", type=Path, metavar="TSV", help="certify a filled sample")
    parser.add_argument("--report", action="store_true", help="totals only")
    parser.add_argument("--sample", type=int, default=100, help="definitions PER LANGUAGE (default 100)")
    parser.add_argument("--seed", default="2026-11-26", help="sample seed")
    args = parser.parse_args(argv)

    if args.check:
        return check(read_sample(args.check))
    if args.emit:
        return emit(stratify(load_definitions(args.db), args.sample, args.seed), args.emit)
    return report(args.db)


if __name__ == "__main__":
    sys.exit(main())
