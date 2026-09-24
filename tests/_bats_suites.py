"""The canonical BATS suite table (tests/bats-suites.tsv), parsed in one place.

The suite list lives in that file so the two bridges cannot disagree about which
suites exist or what bounds them: tests/test_bats_bridge.py (pytest, one generated
test per BATS ``@test`` case) and tests/test_bats_unittest.py (stdlib unittest, one
case per suite file) both load it through here.  Same arrangement as
scripts/_module-list.sh keeps for the two shell loaders.

Deliberately neither a pytest test module nor a unittest one: the name does not match
``test*.py``, so both runners import it instead of collecting it as a suite.
"""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
SUITES_TSV = Path(__file__).resolve().parent / "bats-suites.tsv"
_COLUMNS = "pattern, marker, per_case_timeout_s, file_timeout_s"


@dataclass(frozen=True)
class BatsSuite:
    """One row of tests/bats-suites.tsv."""

    pattern: str
    marker: str
    per_case_timeout_s: int
    file_timeout_s: int


def load_suites() -> list[BatsSuite]:
    """Parse the table; a malformed line is an error, never a skipped row.

    A row that vanished silently would drop its whole suite from BOTH runners, and a
    mistyped timeout would surface only as a hang, so both are raised here, naming the
    file and the line.
    """
    suites: list[BatsSuite] = []
    for lineno, raw in enumerate(SUITES_TSV.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 4:
            raise ValueError(
                f"{SUITES_TSV.name}:{lineno}: expected 4 tab-separated fields "
                f"({_COLUMNS}); got {len(fields)}"
            )
        pattern, marker, per_case, whole_file = fields
        try:
            per_case_s, whole_file_s = int(per_case), int(whole_file)
        except ValueError as exc:
            raise ValueError(
                f"{SUITES_TSV.name}:{lineno}: the timeouts must be integers, got "
                f"{per_case!r} and {whole_file!r}"
            ) from exc
        suites.append(BatsSuite(pattern, marker, per_case_s, whole_file_s))
    if not suites:
        raise ValueError(f"{SUITES_TSV.name}: no suites listed")
    return suites


def suite_files(suites: list[BatsSuite] | None = None) -> list[tuple[BatsSuite, Path]]:
    """Every BATS file the table covers, as (suite, path), in a stable order.

    A file matched by two rows would get two different budgets, and each caller's
    stem-keyed lookup would silently keep whichever row it saw first, so an overlap is
    an error rather than a first-wins.
    """
    pairs: list[tuple[BatsSuite, Path]] = []
    seen: dict[Path, str] = {}
    for suite in load_suites() if suites is None else suites:
        paths = sorted(REPO_ROOT.glob(suite.pattern))
        if not paths:
            raise ValueError(
                f"{SUITES_TSV.name}: pattern {suite.pattern!r} matches no file — a suite "
                f"that silently covers nothing is not a suite"
            )
        for path in paths:
            previous = seen.get(path)
            if previous is not None:
                raise ValueError(
                    f"{SUITES_TSV.name}: {path.relative_to(REPO_ROOT)} is matched by both "
                    f"{previous!r} and {suite.pattern!r}; its cases would take the budget "
                    f"of whichever row a caller looked up first"
                )
            seen[path] = suite.pattern
            pairs.append((suite, path))
    return pairs
