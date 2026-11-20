"""A serving lane may deviate from its certified row — but only where it DECLARES why.

Measured 2026-11-19: the registry certified row 6 (Qwen3-Coder-30B) at ctx 262144,
batch 512/ubatch 256, threads 6, 1 slot, and the live unit served 131072, 2048/512,
threads 10, 4 slots.  The ctx halving had a written reason, outside the repo and
therefore outside review; the batch/thread differences had none at all — they are the
unit's own author's choice, and reading the unit tells you they are *chosen*, not why.

This suite pins the mechanism that makes a deviation auditable.  The property, from
the same-day decision in AGENTS.md §3 ("no silent divergence"): a lane's systemd
parameters must equal the registry row's certified values, except where the *tracked*
unit file carries a `# lane-deviation: <field> <value> — <reason>` line naming the
field, the value it serves, and why.

What each case would catch, in one sentence:
  * `undeclared deviations` — someone edits a batch size or a thread count in the unit
    and the served lane silently stops matching what was measured;
  * `stale declarations` — the unit is changed back to the certified value and the
    deviation line stays, so the next reader is told a difference that no longer exists;
  * `reasonliness` — a declaration with no reason, which satisfies the syntax and
    records nothing, exactly the kind of gate that cannot fail;
  * `stale reasons` — the reason outlives the row it explains (a re-certification
    changes ctx and the declaration still argues about the OLD one).

The registry path is read from the box profile, not hardcoded: the XPS names its own
store and this module must not fail there for the ASUS's layout.
"""

from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
SYSTEMD = REPO_ROOT / "systemd"

# field -> the ExecStart flag it is served by.  Only fields whose row value the lane
# must honour are listed; `ctx` is included because a lane that halves its window has
# to say so *here*, beside the flag, not in an installed drop-in.
FLAG = {
    "ctx": "--ctx-size",
    "batch": "--batch-size",
    "ubatch": "--ubatch-size",
    "threads": "--threads",
    "parallel": "--parallel",
    "gpu_layers": "--n-gpu-layers",
    # A LIVE lane states both spellings: the hand-written units pin `-ngl 999`,
    # while the launcher (scripts/11e-llm-model.sh:2675) emits `--cache-type-k`.
    "kv_k": ("--cache-type-k", "-ctk"),
    "kv_v": ("--cache-type-v", "-ctv"),
}

# `[^—]*` rather than `\S.*`: a reason is prose and often spans continuation lines
# ("…the\n#        certified 512 is…"), but it may never contain the em dash that ends it.
# `\S.*` in the first cut stopped at the first space and recorded "tuned for" as the whole
# reason, so the certified-value check matched nothing and three declarations passed
# vacuously — the failure mode this file exists to prevent.
DECLARATION = re.compile(r"^#\s*lane-deviation:\s*(\w+)\s+(\S+)\s+—\s*([^—]*)$", re.S)

REGISTRY_HEADER_FIELDS = {
    "file": 3,
    "quant_cache": 5,
    "gpu_layers": 7,
    "ctx": 8,
    "threads": 9,
    "batch": 10,
    "ubatch": 11,
    "parallel": 12,
}


def _certified(row: dict[str, str], field: str) -> str:
    """The row's certified value for a served field.

    `kv_k` / `kv_v` live in the row's quant_cache (`QUANT/type-k/type-v`); the same
    field carries a q4_0/q5_0 quant whose LAST segment is not always the cache type,
    so an absent cache segment is the launcher's q8_0 default (scripts/11e-llm-model.sh).
    """
    if field == "kv_k":
        return row["quant_cache"].split("/")[1]
    if field == "kv_v":
        parts = row["quant_cache"].split("/")
        return parts[2] if len(parts) > 2 else "q8_0"
    return row[field]


def _registry_path() -> Path:
    """The registry this box resolves, through the same profile the lanes run under."""
    res = subprocess.run(
        [
            "bash",
            "-c",
            'source "$1" >/dev/null 2>&1; tac_host_profile_apply >/dev/null 2>&1; printf "%s" "${LLM_REGISTRY:-}"',
            "_",
            str(REPO_ROOT / "scripts" / "01-constants.sh"),
        ],
        env={"PATH": os.environ["PATH"], "HOME": os.environ.get("HOME", "/")},
        capture_output=True,
        text=True,
        check=False,
        timeout=60,
    )
    return Path(res.stdout.strip()) if res.stdout.strip() else Path("")


def _row(path: Path, name: str) -> dict[str, str]:
    lines = path.read_text(encoding="utf-8").splitlines()
    for line in lines[1:]:
        cells = line.split("|")
        if len(cells) > REGISTRY_HEADER_FIELDS["parallel"] and cells[2] == name:
            return {k: cells[i - 1] for k, i in REGISTRY_HEADER_FIELDS.items()}
    raise AssertionError(f"{name} is not a row of {path}")


def _served(unit: Path) -> dict[str, str]:
    """The parameters the unit's LAST (effective) ExecStart serves for FLAG's fields."""
    served: dict[str, str] = {}
    for line in unit.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        # systemd resets the list on a bare `ExecStart=`; each reset or new line below
        # replaces what an earlier ExecStart said, so only the last one is effective.
        if line == "ExecStart=":
            served = {}
            continue
        if not line.startswith("ExecStart=") or line == "ExecStart=":
            continue
        args = line[len("ExecStart=") :].split()
        current: dict[str, str] = {}
        for i, arg in enumerate(args):
            for field, flag in FLAG.items():
                flags = flag if isinstance(flag, tuple) else (flag,)
                if arg in flags and i + 1 < len(args):
                    current[field] = args[i + 1]
        served = current
    return served


def _declared(unit: Path) -> dict[str, tuple[str, str]]:
    """field -> (served value, the paragraph that follows the em dash).

    A reason is prose, so it runs to the next declaration, the next shell section or
    the end of the file — not to the end of one line.  The continuation lines are the
    unit's `#` comments, stripped so the reason reads as a sentence.
    """
    lines = unit.read_text(encoding="utf-8").splitlines()
    starts: list[tuple[int, re.Match[str]]] = []
    for i, line in enumerate(lines):
        m = DECLARATION.match(line.strip())
        if m:
            starts.append((i, m))
    out: dict[str, tuple[str, str]] = {}
    for n, (i, m) in enumerate(starts):
        end = starts[n + 1][0] if n + 1 < len(starts) else len(lines)
        body = [m.group(3)]
        # A continuation is a comment line that does not start a NEW sentence: the
        # declarations are written as wrapped clauses ("…the certified 512 is…"), while
        # the openers below begin the next paragraph — provenance, or the config argument
        # that explains why one lane is not autotunable at all.
        openers = ("lane-deviation:", "PROVENANCE", "WHY", "lxc-autotune")
        for follow in lines[i + 1 : end]:
            stripped = follow.strip()
            if stripped.startswith("[") or stripped.startswith("ExecStart="):
                break
            text = stripped[1:].strip() if stripped.startswith("#") else stripped
            if stripped.startswith("#") and not text.startswith(openers):
                body.append(text)
                continue
            break
        out[m.group(1)] = (m.group(2), " ".join(part for part in body if part))
    return out


def _lane_units() -> list[Path]:
    """Chat/serving lanes whose model IS a registry row.

    The embedding lanes are excluded by their ARCH, not by their name: `autotune-rows.sh
    --all` skips `arch ~ embedding` for the same reason (a fixed-function encoder is not
    tuned on decode throughput), and the ASUS store does not register its two encoders at
    all.  Measuring which are certified keeps the exclusion honest — a chat lane can
    never be skipped by this rule.
    """
    registry = _registry_path()
    rows = registry.read_text(encoding="utf-8").splitlines()[1:] if registry.exists() else []
    found = []
    for unit in sorted(SYSTEMD.glob("llama-cuda-*.service")):
        text = unit.read_text(encoding="utf-8")
        if "models/active/" not in text or "ExecStart=" not in text:
            continue
        name = _model_file(unit)
        for line in rows:
            cells = line.split("|")
            if len(cells) > REGISTRY_HEADER_FIELDS["parallel"] and cells[2] == name:
                if "embedding" not in cells[5].lower():
                    found.append(unit)
                break
    return found


def test_the_embedding_lanes_are_the_only_ones_excluded() -> None:
    # The exclusion above is by ARCH, so state it: both CUDA encoders exist and are
    # skipped, and neither is a chat lane wearing an encoder's name.  Catches an
    # exclusion that grows to cover a chat lane, which is how a gate quietly stops
    # covering anything.
    certified = {u.stem for u in _lane_units()}
    all_lanes = {
        u.stem for u in SYSTEMD.glob("llama-cuda-*.service") if "models/active/" in u.read_text(encoding="utf-8")
    }
    assert "llama-cuda-qwen3coder-30b-chat" in certified
    assert "llama-cuda-qwen25-3b-measure" in certified
    for name in all_lanes - certified:
        assert "embed" in name, f"{name} serves a registry row but was excluded"


def _model_file(unit: Path) -> str:
    m = re.search(r"-m\s+\S*/models/active/(\S+)", unit.read_text(encoding="utf-8"))
    assert m, f"{unit.name} does not name a model under models/active"
    return m.group(1)


@pytest.mark.parametrize("unit", _lane_units(), ids=lambda p: p.stem)
def test_undeclared_deviations(unit: Path) -> None:
    row = _row(_registry_path(), _model_file(unit))
    served = _served(unit)
    declared = _declared(unit)
    undeclared = {
        field: (_certified(row, field), served[field])
        for field in FLAG
        if field in served and served[field] != _certified(row, field) and field not in declared
    }
    assert not undeclared, (
        f"{unit.name} deviates from its certified row ({row['file']}) without declaring "
        f"it (certified, served): {undeclared}\n"
        "Add a `# lane-deviation: <field> <served value> — <the measurement and why>` "
        "line to the tracked unit, or serve the certified value."
    )


@pytest.mark.parametrize("unit", _lane_units(), ids=lambda p: p.stem)
def test_declarations_match_what_is_served(unit: Path) -> None:
    served = _served(unit)
    for field, (value, reason) in _declared(unit).items():
        assert field in FLAG, f"{unit.name} declares an unknown field: {field}"
        assert field in served, f"{unit.name} declares {field} but does not serve it"
        assert served[field] == value, f"{unit.name} declares {field}={value} but serves {served[field]}"
        assert re.search(r"[A-Za-z]{3,}", reason), f"{unit.name} declares {field} with no reason: {reason!r}"
        row = _row(_registry_path(), _model_file(unit))
        certified = _certified(row, field)
        assert value != certified, (
            f"{unit.name}'s {field} declaration is STALE: it equals the certified "
            f"value {certified}, so the difference it explains no longer exists"
        )
        # A reason is a measurement, and a measurement names the number it measured.
        # Catches a declaration kept after a re-certification moved the certified value
        # away from the one the reason argues about.
        assert re.search(rf"\b{re.escape(certified)}\b", reason), (
            f"{unit.name}'s {field} reason does not name the certified value it deviates FROM ({certified}): {reason!r}"
        )


def test_the_lane_set_is_not_empty() -> None:
    # A glob that matched nothing would make every case above vacuous.
    assert _lane_units(), "no llama-cuda-*.service units were found — the check is vacuous"


def _reasons(unit: Path, serving: dict[str, str], registry: dict[str, str], into: Path) -> Path:
    """A copy of `unit` in `into` whose ExecStart serves `serving` instead."""
    text = unit.read_text(encoding="utf-8")
    original = _served(unit)
    for field, value in serving.items():
        flags = FLAG[field] if isinstance(FLAG[field], tuple) else (FLAG[field],)
        for flag in flags:
            text = re.sub(rf"({flag} )\S+", rf"\g<1>{value}", text)
    assert _served_text(text) != original or serving == original
    copy = into / f"{unit.stem}.mutant.service"
    copy.write_text(text, encoding="utf-8")
    return copy


def _served_text(text: str) -> dict[str, str]:
    """`_served`, for a unit body held in memory (the mutation harness's only seam)."""
    served: dict[str, str] = {}
    for line in text.splitlines():
        line = line.strip()
        if line == "ExecStart=":
            served = {}
            continue
        if not line.startswith("ExecStart="):
            continue
        args = line[len("ExecStart=") :].split()
        current: dict[str, str] = {}
        for i, arg in enumerate(args):
            for field, flag in FLAG.items():
                flags = flag if isinstance(flag, tuple) else (flag,)
                if arg in flags and i + 1 < len(args):
                    current[field] = args[i + 1]
        served = current
    return served


def test_an_undeclared_change_fails_the_gate(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    # The gate's teeth.  Every case above passes today, so nothing yet shows the check
    # can go red — and a gate that cannot fail is the failure mode this whole session
    # was spent on.  Mutate the one lane whose batch is certified to sit at the sweep's
    # ceiling and assert the gate names the field.  tmp_path is where the mutants are
    # written: `SYSTEMD` is parametrised at COLLECTION, so a mutant left in systemd/
    # would become a lane of its own on the next run.
    unit = SYSTEMD / "llama-cuda-qwen3coder-30b-chat.service"
    registry = _registry_path()
    row = _row(registry, _model_file(unit))
    # What a careless edit looks like, in the two directions that matter:
    #   * the value changes and the declaration does NOT — the served number is not the
    #     declared one, which is the case a reader would be misled by;
    #   * a parameter is introduced that neither the row nor any declaration covers.
    # Changing BOTH value and declaration is not tested here: the gate reads the file,
    # so a freshly written declaration is indistinguishable from a considered one.  No
    # checker can tell a new decision from a lone edit; that is what review is for.
    assert _reasons(unit, {"batch": "4096"}, row, tmp_path).read_text(encoding="utf-8") != unit.read_text(
        encoding="utf-8"
    )
    mutant = _reasons(unit, {"batch": "4096"}, row, tmp_path)
    monkeypatch.setattr("tests.test_lane_certification.SYSTEMD", tmp_path, raising=True)
    # Point the parametrised helper at the mutant only.
    monkeypatch.setattr("tests.test_lane_certification._lane_units", lambda: [mutant], raising=True)
    # With BOTH changed the declaration is self-consistent, so the deviation case stays
    # green — its documented limit — while the reason check still fires, because the
    # untouched reason no longer names the certified value it argues about.
    assert test_undeclared_deviations(mutant) is None
    with pytest.raises(AssertionError, match="declares batch=2048 but serves 4096"):
        test_declarations_match_what_is_served(mutant)

    # ...and a lane line rewritten out of step with its own declaration.  The mutant's
    # `--threads 7` IS in its text — that is the mutation — so the assertion belongs on
    # the SERVED value, and on the gate naming it.
    undeclared = _reasons(unit, {"threads": "7"}, row, tmp_path)
    with pytest.raises(AssertionError, match="declares threads=10 but serves 7"):
        test_declarations_match_what_is_served(undeclared)
