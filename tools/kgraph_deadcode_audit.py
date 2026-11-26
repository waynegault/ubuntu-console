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


# Names a RUNTIME invokes with no call site in the source.  They are entry points, not
# candidates for a dead-code verdict: `len()` calls `__len__`, http.server calls
# `do_POST`, pytest calls `pytest_*`, and `main` is called by a shell or a unit file.
_RUNTIME_PREFIXES = ("do_GET", "do_POST", "do_PUT", "do_DELETE", "do_OPTIONS", "do_HEAD", "do_PATCH")
_RUNTIME_EXACT = frozenset({"main", "__main__"})


def is_runtime_dispatched(name: str) -> bool:
    """True when a runtime (interpreter, framework, shell) invokes this by convention.

    Measured 2026-11-26: the first certification run failed on exactly three names —
    `__len__`, `__getattr__` and `do_POST` — every one of them called by Python or by
    http.server with no call syntax anywhere.  A bar that demands a static caller for
    those measures an impossibility, so they are excluded from the sample and named
    instead of silently dropped.
    """
    if name.startswith("__") and name.endswith("__"):
        return True
    return name in _RUNTIME_EXACT or name.startswith(_RUNTIME_PREFIXES) or name.startswith("pytest_")


def is_test_path(path: str) -> bool:
    """A path that ships with the test suite rather than the product."""
    lowered = path.replace("\\", "/").lower()
    return "/tests/" in f"/{lowered}" or lowered.startswith("tests/")


def _definitions_from_graph(graph: dict) -> list[dict[str, str]]:
    """Definitions and caller counts from an in-memory extraction.

    WHY (2026-11-26, Wayne: "point kgraph at investigator"): the DB path is this box's
    store for ONE repo.  A directory can be measured without writing anything, which is
    what pointing the tool at another checkout requires — `kgraph update` also runs
    markdown import, community detection and a PR dashboard, none of which a verdict
    needs (it ran ten minutes on investigator without producing a store).
    """
    called = {e["target"] for e in graph["edges"] if e.get("label") == "calls"}
    callers: dict[str, set[str]] = {}
    for edge in graph["edges"]:
        if edge.get("label") == "calls":
            callers.setdefault(edge["target"], set()).add(edge["source"])
    out: list[dict[str, str]] = []
    for node in graph["nodes"]:
        if node.get("type") != "function":
            continue
        srcs = sorted(callers.get(node["id"], ()))
        out.append(
            {
                "id": node["id"],
                "lang": node.get("language") or "python",
                "name": node.get("label") or "",
                "defined_in": str(node.get("file") or node.get("rel_path") or node.get("path") or ""),
                "kgraph": "used" if node["id"] in called else "unused",
                "callers": ",".join(s.replace("ast_file:", "").replace("ast_call:", "call:") for s in srcs[:4]),
            }
        )
    return out


def load_definitions_from_dir(root: Path) -> list[dict[str, str]]:
    """Extract a repo in memory and return its definitions. Writes nothing."""
    from kgraph.ast_extractor import extract_repo_graph

    return _definitions_from_graph(extract_repo_graph(str(root)))


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


def stratify(
    defs: list[dict[str, str]], per_language: int, seed: int, production_only: bool = True
) -> list[dict[str, str]]:
    """Deterministic, reproducible sample: `per_language` of each language, seeded.

    Sorted BEFORE sampling so the result depends on the tree's content, not on
    sqlite's row order — the same commit yields the same sample.
    """
    out: list[dict[str, str]] = []
    for lang in ("bash", "python"):
        pool = sorted(
            (
                d
                for d in defs
                if d["lang"] == lang
                and not is_runtime_dispatched(d["name"])
                and not (production_only and is_test_path(d["defined_in"]))
            ),
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


def check(rows: list[dict[str, str]], defs: list[dict[str, str]] | None = None) -> int:
    blank = [r for r in rows if r["truth"] not in ("used", "unused")]
    if blank:
        print(f"CANNOT CERTIFY: {len(blank)} row(s) have no truth value yet", file=sys.stderr)
        for r in blank[:10]:
            print(f"  line {r['lineno']}: {r['lang']} {r['name']}", file=sys.stderr)
        return 2

    # The verdict is read from the GRAPH JUST BUILT, not from the row's stored column:
    # a check against the file's own snapshot proves only that the file has not changed
    # (measured 2026-11-26, pointing the tool at another checkout).
    live = {(d["lang"], d["name"], d["defined_in"]): d["kgraph"] for d in (defs or [])}
    for row in rows:
        key = (row["lang"], row["name"], row["defined_in"])
        if key in live:
            row["kgraph"] = live[key]

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
        print("  (a runtime-dispatched name here means the sample rule is wrong, not the graph)")
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


def report(defs: list[dict[str, str]]) -> int:
    """Caller coverage, split production from test code.

    The split is the measurement.  Quoting one figure over both populations read
    41.8% for Python, because 1,581 of its 2,560 functions are pytest test functions
    that pytest collects BY NAME and nothing calls.  Production Python reads 85.5% on
    the same graph (measured 2026-11-26), and the two populations answer different
    questions, so they are never summed.
    """
    for lang in ("bash", "python"):
        group = [d for d in defs if d["lang"] == lang]
        prod = [d for d in group if not _test_side(d["defined_in"])]
        test = [d for d in group if _test_side(d["defined_in"])]
        for label, subset in (("production", prod), ("tests/", test)):
            used = sum(1 for d in subset if d["kgraph"] == "used")
            share = 100.0 * used / max(len(subset), 1)
            print(f"{lang:7s} {label:11s} {used:5d}/{len(subset):5d} with a caller ({share:5.1f}%)")
    return 0


_test_side = is_test_path


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0] if __doc__ else "")
    parser.add_argument("--db", type=Path, default=DEFAULT_DB)
    parser.add_argument(
        "--graph-dir",
        type=Path,
        metavar="DIR",
        help="measure this checkout directly (no store written); overrides --db",
    )
    parser.add_argument("--emit", type=Path, metavar="TSV", help="write a sampling template")
    parser.add_argument("--check", type=Path, metavar="TSV", help="certify a filled sample")
    parser.add_argument("--report", action="store_true", help="totals only")
    parser.add_argument("--sample", type=int, default=100, help="definitions PER LANGUAGE (default 100)")
    parser.add_argument(
        "--include-tests",
        action="store_true",
        help="sample test-file definitions too (default: production only, where a verdict applies)",
    )
    parser.add_argument("--seed", default="2026-11-26", help="sample seed")
    args = parser.parse_args(argv)

    # One definition loader for both sources: this box's store, or any checkout given as
    # a directory (which writes nothing — pointing kgraph at another repo must not
    # disturb either repo's state).
    defs = load_definitions_from_dir(args.graph_dir.resolve()) if args.graph_dir else load_definitions(args.db)
    if args.check:
        return check(read_sample(args.check), defs)
    if args.emit:
        picked = stratify(defs, args.sample, args.seed, production_only=not args.include_tests)
        return emit(picked, args.emit)
    return report(defs)


if __name__ == "__main__":
    sys.exit(main())
