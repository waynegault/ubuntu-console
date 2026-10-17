"""Selection-report tests: the dimensions are joined, and absent evidence never wins.

The report exists to stop a throughput winner from passing as a quality winner.  So
the load-bearing properties are:

  * a dimension that was not measured is printed as ABSENT, never as zero and never
    silently omitted,
  * a model with no correctness observation says so instead of inheriting a figure,
  * the recommendation check can only say "agrees" when there was measured evidence
    to agree WITH, and
  * `best_measured` never picks a model that has no observation.

# REF: "Jev Your Engines: Seven Open Decision Models vs. a Generative LLM"
# (Lambert Leong, TDS, 2026-10-15) —
# https://towardsdatascience.com/jev-your-engines-seven-open-decision-models-vs-a-generative-llm/
# "Measure correct routes, invalid outputs, latency and abstentions together" — the
# requirement this report implements, and the reason a missing dimension is printed
# ABSENT instead of being quietly left out.
"""

import json

from tools.llm_selection_report import (
    OUTCOME_COLUMNS,
    agreement,
    best_measured,
    load_outcomes,
    parse_registry,
    render_markdown,
    Dimension,
)

_REGISTRY = "\n".join(
    [
        "#|name|file|size_gb|quant_cache|arch|gpu_layers|ctx|threads|batch|ubatch|parallel|"
        "fit_target_mb|backend|mmap_mode|flash_attn|tps|autotuned|is_default|in_vram|prefill_tps|"
        "p2_ctx|p2_batch|p2_ubatch|p2_tps|p2_prefill|spec_type|spec_draft_model|spec_draft_n_max|"
        "spec_draft_ngl|spec_draft_device|spec_accept_len|workload|ttft_ms|bench_ctx|"
        "bench_max_chunks|bench_avg_prompt_tokens|repeat_penalty|repeat_last_n|meas_load|"
        "meas_n|meas_spread|meas_drift|meas_state",
        # a full 44-column certified row
        "1|Alpha Coder|alpha.gguf|2.3G|Q4|phi3|999|24064|6|512|128|1|256|native|auto|on|"
        "41.5|yes|no|no|137.3|21504|1024|256|12.6|851.0|ngram||4|||0|"
        "chat|1200|8192|4|700|1.1|256|1.0|3|0.1|0.0|certified",
        # the same shape, indicative
        "2|Beta|beta.gguf|3.1G|Q4|llama|999|12288|6|1024|128|1|256|native|auto|on|"
        "12.0|yes|no|no|99.0|12288|1024|128|11.0|700.0|||||||"
        "chat|2000|8192|4|700|1.1|256|1.0|3|0.1|0.0|indicative",
        # a LEGACY 20-column row: no workload, no meas_state
        "3|Gamma|gamma.gguf|1.1G|Q4|qwen|999|4096|4|256|64|1|128|native|auto|on|5.0|yes|no|no",
    ]
)


def _write_registry(tmp_path) -> str:
    path = tmp_path / "models.conf"
    path.write_text(_REGISTRY + "\n", encoding="utf-8")
    return str(path)


def _artefact(path, model, results, limits=None):
    artefact = {
        "tool": "llm_outcome_cases",
        "model": model,
        "summary": {"cases": len(results)},
        "results": results,
        "limits": limits or [],
    }
    path.write_text(json.dumps(artefact), encoding="utf-8")
    return str(path)


def _result(workload: str, outcome: str) -> dict[str, str]:
    return {"case": f"{workload}-x", "workload": workload, "outcome": outcome}


def test_registry_rows_are_parsed_and_a_legacy_row_is_padded_not_dropped(tmp_path):
    rows = parse_registry(_write_registry(tmp_path))
    assert [row.num for row in rows] == ["1", "2", "3"]
    assert rows[0].workload == "chat"
    assert rows[0].meas_state == "certified"
    assert rows[0].certified is True
    # the legacy row survives, with its unrecorded columns visible as absent
    assert rows[2].workload == "-"
    assert rows[2].meas_state == "-"
    assert rows[2].certified is False


def test_a_row_is_joinable_by_display_name_or_by_artifact_filename(tmp_path):
    rows = parse_registry(_write_registry(tmp_path))
    # the registry carries both, and a server may report either
    assert rows[0].key == "alpha coder"
    assert rows[0].file_key == "alpha"
    assert rows[0].matches("alpha") is True
    assert rows[0].matches("alpha coder") is True
    assert rows[0].matches("beta") is False


def test_a_filename_keyed_artefact_still_joins(tmp_path):
    """A server reports the GGUF it launched; the registry stores both names."""
    rows = parse_registry(_write_registry(tmp_path))
    outcomes, _ = load_outcomes(_artefact(tmp_path / "a.json", "alpha.gguf", [_result("chat", "correct")]))
    markdown = render_markdown(
        rows, outcomes, {}, [Dimension(source="correctness", detail="1 model")], agreement("", {}, rows)
    )
    row = next(line for line in markdown.splitlines() if line.startswith("| 1 |"))
    assert "| 1 |" in row
    assert "no observation" not in row


def test_report_is_explicitly_quality_blind_with_no_outcomes(tmp_path):
    rows = parse_registry(_write_registry(tmp_path))
    markdown = render_markdown(
        rows,
        {},
        {},
        [Dimension(source="correctness", detail="not supplied"), Dimension(source="format", detail="n/a")],
        agreement("", {}, rows),
    )
    assert "QUALITY-BLIND" in markdown
    assert "no observation" in markdown
    assert "a faster model with worse answers cannot lose" in markdown


def test_a_model_without_an_observation_is_named_in_coverage(tmp_path):
    rows = parse_registry(_write_registry(tmp_path))
    outcomes, _ = load_outcomes(_artefact(tmp_path / "a.json", "Alpha Coder", [_result("chat", "correct")]))
    markdown = render_markdown(
        rows, outcomes, {}, [Dimension(source="correctness", detail="1 model")], agreement("", {}, rows)
    )
    assert "no correctness observation for 2 model(s)" in markdown
    assert "QUALITY-BLIND" not in markdown


def test_both_dimensions_appear_together_in_one_table(tmp_path):
    rows = parse_registry(_write_registry(tmp_path))
    outcomes, _ = load_outcomes(
        _artefact(
            tmp_path / "a.json",
            "Alpha Coder",
            [
                _result("chat", "correct"),
                _result("chat", "incorrect"),
                _result("chat", "invalid"),
            ],
        )
    )
    fmt = {"workload": "agentic", "probes": 3, "policy": "strict", "counts": {"ok": 3}}
    markdown = render_markdown(
        rows,
        outcomes,
        fmt,
        [Dimension(source="correctness", detail=""), Dimension(source="format", detail="")],
        agreement("", {}, rows),
    )
    # one row of the table carries throughput AND the four outcome columns
    row = next(line for line in markdown.splitlines() if line.startswith("| 1 |"))
    assert "41.5" in row
    for column in OUTCOME_COLUMNS:
        assert column in markdown
    assert "policy=strict" in markdown


def test_an_absent_dimension_is_reported_ABSENT_not_zero(tmp_path):
    rows = parse_registry(_write_registry(tmp_path))
    markdown = render_markdown(
        rows,
        {},
        {},
        [Dimension(source="correctness", detail="x"), Dimension(source="format", detail="not supplied")],
        agreement("", {}, rows),
    )
    assert "**ABSENT**" in markdown


def test_a_directory_of_artefacts_is_read_per_model(tmp_path):
    directory = tmp_path / "outcomes"
    directory.mkdir()
    _artefact(directory / "a.json", "Alpha Coder", [_result("chat", "correct")])
    _artefact(directory / "b.json", "Beta", [_result("chat", "invalid")])
    outcomes, dimension = load_outcomes(str(directory))
    assert set(outcomes) == {"alpha coder", "beta"}
    assert dimension.present is True
    assert "2 model(s)" in dimension.detail


def test_best_measured_ranks_on_correct_first_then_fewest_invalid(tmp_path):
    outcomes, _ = load_outcomes(str(tmp_path))
    rows = parse_registry(_write_registry(tmp_path))
    better = _artefact(
        tmp_path / "better.json",
        "Alpha Coder",
        [_result("chat", "correct"), _result("chat", "correct")],
    )
    worse = _artefact(
        tmp_path / "worse.json",
        "Beta",
        [_result("chat", "correct"), _result("chat", "invalid")],
    )
    outcomes, _ = load_outcomes(str(tmp_path))
    best = best_measured(outcomes, rows)
    assert best is not None
    assert best[0] == "Alpha Coder"
    assert worse and better


def test_best_measured_ignores_a_model_with_no_observation(tmp_path):
    rows = parse_registry(_write_registry(tmp_path))
    outcomes, _ = load_outcomes(_artefact(tmp_path / "a.json", "Alpha Coder", [_result("chat", "invalid")]))
    best = best_measured(outcomes, rows)
    assert best is not None
    assert best[0] == "Alpha Coder"  # the only measured model, even though it failed
    assert "Beta" not in [best[0]]


def test_the_recommendation_check_says_agrees_only_when_it_did(tmp_path):
    rows = parse_registry(_write_registry(tmp_path))
    directory = tmp_path / "outcomes"
    directory.mkdir()
    _artefact(directory / "alpha.json", "Alpha Coder", [_result("chat", "correct")])
    _artefact(directory / "beta.json", "Beta", [_result("chat", "invalid")])
    outcomes, _ = load_outcomes(str(directory))

    agrees = agreement("1", outcomes, rows)
    assert agrees["available"] is True
    assert agrees["agree"] is True
    assert agrees["best_measured"] == "Alpha Coder"

    disagrees = agreement("2", outcomes, rows)
    assert disagrees["available"] is True
    assert disagrees["agree"] is False


def test_the_recommendation_check_admits_when_it_has_no_evidence(tmp_path):
    rows = parse_registry(_write_registry(tmp_path))
    missing = agreement("1", {}, rows)
    assert missing["available"] is False
    assert "no correctness observations" in missing["reason"]

    outcomes, _ = load_outcomes(_artefact(tmp_path / "a.json", "Alpha Coder", [_result("chat", "correct")]))
    unknown = agreement("99", outcomes, rows)
    assert unknown["available"] is False
    assert "not in the registry" in unknown["reason"]
