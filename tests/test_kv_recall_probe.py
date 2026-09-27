"""Tests for the KV-cache recall probe's verifiable core (card KVCACHE-QUANT-VALIDATE-001).

The probe's MEASUREMENT needs a running llama.cpp server at a chosen ``--cache-type-k/v``,
and that is deliberately not something a unit test starts.  What a unit test CAN pin is
everything that decides whether a measurement means anything: where the needle lands, that
scoring is exact, that "unrecorded" is never a pass, that a dry run contacts nothing, and
that a regression is reported rather than averaged away.

The module is a hyphenated script (this repo's ``scripts/*.py`` convention), so it is
loaded by path rather than imported by name.
"""

from __future__ import annotations

import importlib.util
import sys
import urllib.error
from pathlib import Path
from typing import Any

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent


def _load_probe() -> Any:
    """Import scripts/kv-recall-probe.py by path (its name is not a module name).

    Registered in ``sys.modules`` before execution on purpose: ``@dataclass`` resolves the
    defining module's namespace through ``sys.modules``, and on Python 3.14 a module that
    was only ``module_from_spec``-ed makes that lookup return None.
    """
    spec = importlib.util.spec_from_file_location(
        "kv_recall_probe", REPO_ROOT / "scripts" / "kv-recall-probe.py"
    )
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    try:
        spec.loader.exec_module(module)
    except BaseException:
        del sys.modules[spec.name]
        raise
    return module


probe = _load_probe()


def _plan(**over: Any) -> Any:
    kwargs = {
        "model": "llama32-3b",
        "kv_type": "q8_0",
        "ctx_tokens": 2000,
        "depths": (0.1, 0.5, 0.9),
        "seed": 1,
    }
    kwargs.update(over)
    return probe.ProbePlan(**kwargs)


def _needle(code: str = "7394") -> str:
    return probe.NEEDLE_TEMPLATE.format(tag="the A-17 bundle", code=code)


# --- depth handling ---------------------------------------------------------

def test_depths_are_positions_inside_the_context() -> None:
    assert probe.validate_depths((0.1, 0.9)) == (0.1, 0.9)
    for bad in ((0.0,), (1.0,), (-0.5,), (1.5,)):
        with pytest.raises(ValueError):
            probe.validate_depths(bad)
    with pytest.raises(ValueError):
        probe.validate_depths(())


def test_the_needle_lands_where_the_depth_says() -> None:
    plan = _plan()
    for depth in (0.1, 0.5, 0.9):
        document, position = probe.build_haystack(plan, depth, _needle())
        lines = document.splitlines()
        assert lines[position - 1] == _needle()
        # Placement is a fraction of the document; allow the rounding of one line.
        assert abs((position / len(lines)) - depth) <= 0.02


def test_the_same_plan_builds_the_same_haystack() -> None:
    plan = _plan()
    first, _ = probe.build_haystack(plan, 0.5, _needle())
    again, _ = probe.build_haystack(plan, 0.5, _needle())
    assert first == again
    # A different seed is a different document — the point of seeding at all.
    other, _ = probe.build_haystack(_plan(seed=2), 0.5, _needle())
    assert other != first
    # And a different kv_type is its own document, so two precisions never share a run.
    other, _ = probe.build_haystack(_plan(kv_type="q4_0"), 0.5, _needle())
    assert other != first


# --- scoring ----------------------------------------------------------------

def test_scoring_is_exact_and_reads_the_last_line() -> None:
    assert probe.score_answer("7394", "7394")
    assert probe.score_answer("The code is 7394.", "7394")
    assert probe.score_answer("reasoning...\n\n7394\n", "7394")
    # A hedged answer still retrieved it: the code is not guessable, so a miss here would
    # under-report recall and make a healthy precision look dangerous.
    assert probe.score_answer("7394 I think.", "7394")
    # But a code inside a longer number is not the code...
    assert not probe.score_answer("17394", "7394")
    # ...and nothing on the last line is not an answer, however good the reasoning was.
    assert not probe.score_answer("7394\nI am not certain.", "7394")
    assert probe.extract_answer("\n\n") == ""


# --- recording and checking -------------------------------------------------

def _results(hits: list[bool]) -> list[Any]:
    return [
        probe.DepthResult(depth=d, hit=h, prompt_tokens=1234, answer="7394" if h else "?")
        for d, h in zip((0.1, 0.5, 0.9), hits, strict=True)
    ]


def test_record_then_check_round_trip(tmp_path: Path) -> None:
    path = tmp_path / "kv-recall-baseline.tsv"
    plan = _plan()
    probe.record_baseline(path, plan, _results([True, True, True]))

    assert probe.check_baseline(path, plan, _results([True, True, True]), 0.0) == []
    # The server's own prompt_tokens is what the record carries.
    assert "1234" in path.read_text()
    assert path.read_text().splitlines()[0].startswith("#model")


def test_a_lower_recall_is_a_regression() -> None:
    import tempfile

    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "baseline.tsv"
        plan = _plan()
        probe.record_baseline(path, plan, _results([True, True, True]))
        failures = probe.check_baseline(path, plan, _results([True, False, True]), 0.0)
        assert len(failures) == 1
        assert "depth 0.50" in failures[0]
        # The tolerance is the only thing that softens it, and it is explicit.
        assert probe.check_baseline(path, plan, _results([True, False, True]), 1.0) == []


def test_an_unrecorded_depth_is_not_a_pass(tmp_path: Path) -> None:
    path = tmp_path / "absent.tsv"
    failures = probe.check_baseline(path, _plan(), _results([True, True, True]), 0.0)
    assert len(failures) == 3
    assert all("unrecorded is not passing" in f for f in failures)


def test_the_aggregate_is_labelled_as_the_trap_it_is() -> None:
    summary = probe.summarise(_results([True, True, False]))
    # 2/3 sounds healthy; the per-depth rows are the result, and the key says so.
    assert summary["aggregate_hides_the_cliff"] == pytest.approx(0.6667, abs=1e-4)
    assert summary["hits"] == 2
    assert "aggregate" in "".join(summary) and "cliff" in "".join(summary)


# --- the command line -------------------------------------------------------

def test_dry_run_builds_a_plan_and_contacts_nothing(monkeypatch: pytest.MonkeyPatch,
                                                   capsys: pytest.CaptureFixture[str]) -> None:
    def _explode(*_a: Any, **_k: Any) -> Any:
        raise AssertionError("--dry-run must not contact a server")

    monkeypatch.setattr(probe, "ask_server", _explode)
    assert probe.main(["--dry-run"]) == 2
    out = capsys.readouterr().out
    assert "needle at line" in out and "plan:" in out


def test_measuring_without_a_kv_type_is_refused(capsys: pytest.CaptureFixture[str]) -> None:
    # A result whose precision is unknown is not a measurement, so it is refused up front
    # rather than recorded as if it were one.
    assert probe.main(["--model", "llama32-3b"]) == 2
    assert "--kv-type" in capsys.readouterr().err


def test_a_server_that_does_not_answer_is_exit_3(monkeypatch: pytest.MonkeyPatch,
                                                 capsys: pytest.CaptureFixture[str]) -> None:
    def _refuse(*_a: Any, **_k: Any) -> Any:
        raise urllib.error.URLError("connection refused")

    monkeypatch.setattr(probe, "ask_server", _refuse)
    rc = probe.main(["--model", "m", "--kv-type", "q8_0", "--ctx-tokens", "128"])
    assert rc == 3
    assert "did not answer" in capsys.readouterr().err


def test_a_check_that_regresses_is_exit_4(monkeypatch: pytest.MonkeyPatch,
                                          tmp_path: Path) -> None:
    path = tmp_path / "baseline.tsv"
    plan = _plan()
    probe.record_baseline(path, plan, _results([True, True, True]))

    def _miss(*_a: Any, **_k: Any) -> tuple[str, int]:
        return "no idea", 99

    monkeypatch.setattr(probe, "ask_server", _miss)
    rc = probe.main([
        "--model", plan.model, "--kv-type", plan.kv_type,
        "--ctx-tokens", str(plan.ctx_tokens), "--check", str(path),
    ])
    assert rc == 4
