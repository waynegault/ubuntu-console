"""Correctness-axis tests: a right answer, a wrong answer, an abstention, a shape failure.

The tool exists because throughput and format checks together still cannot say
whether a model answered correctly.  These cases pin the four outcomes apart,
because pooling them is the aggregation error that makes a fast, wrong model win:

  * `incorrect` must never be reported as `invalid` (or a bad model looks broken),
  * `invalid` must never be reported as `incorrect` (or a prompt bug looks like a
    model bug), and
  * `abstain` must stay its own outcome, because declining is neither.
"""

import json

import pytest

from tools import llm_outcome_cases
from tools.llm_outcome_cases import (
    CASES,
    OUTCOME_ABSTAIN,
    OUTCOME_CORRECT,
    OUTCOME_INCORRECT,
    OUTCOME_INVALID,
    score_response,
    summarise,
)


def _envelope(content: str) -> dict[str, object]:
    return {"choices": [{"message": {"content": content}}]}


def _case(case_id: str):
    for case in CASES:
        if case.id == case_id:
            return case
    raise AssertionError(f"case {case_id} is missing from the held-out set")


# ── the case set itself ────────────────────────────────────────────────────────
def test_every_case_has_a_checkable_expectation():
    assert CASES, "the held-out case set must not be empty"
    for case in CASES:
        assert case.id, "every case needs a stable id"
        assert case.prompt.strip(), f"{case.id} has no prompt"
        assert case.expect, f"{case.id} has no expected answer"
        assert case.workload in {"chat", "legal", "agentic", "mix"}, case.id


def test_case_ids_are_unique_and_cover_all_four_workloads():
    ids = [case.id for case in CASES]
    assert len(ids) == len(set(ids)), "duplicate case id"
    assert {case.workload for case in CASES} == {"chat", "legal", "agentic", "mix"}


def test_tool_call_cases_name_the_tool_and_the_argument():
    for case in CASES:
        if case.kind != "tool_call":
            continue
        assert case.tool, f"{case.id} is a tool_call case with no expected tool"
        assert case.argument_name, f"{case.id} does not score its argument"
        assert case.argument_expect, f"{case.id} does not score an argument value"


# ── the four outcomes ──────────────────────────────────────────────────────────
def test_expected_token_scores_correct():
    result = score_response(_case("chat-arithmetic"), _envelope("ANSWER: 6"))
    assert result.outcome == OUTCOME_CORRECT
    assert result.code == "ok"


def test_wrong_token_is_incorrect_not_invalid():
    result = score_response(_case("chat-arithmetic"), _envelope("ANSWER: 9"))
    assert result.outcome == OUTCOME_INCORRECT
    assert result.code == "wrong-answer"


def test_empty_response_is_invalid_not_incorrect():
    result = score_response(_case("mix-two-step"), _envelope("   "))
    assert result.outcome == OUTCOME_INVALID
    assert result.code == "empty"


def test_unlabelled_prose_is_invalid_because_it_cannot_be_scored():
    result = score_response(_case("chat-instruction-follow"), _envelope("The answer is ALPHA"))
    assert result.outcome == OUTCOME_INVALID
    assert result.code == "outcome-no-answer-marker"


def test_declining_in_its_own_words_is_abstain():
    result = score_response(_case("chat-order"), _envelope("I cannot determine the order."))
    assert result.outcome == OUTCOME_ABSTAIN
    assert result.code == "abstain-lexical"


def test_abstaining_on_an_answerable_case_is_not_correct():
    result = score_response(_case("mix-unit"), _envelope("ANSWER: ABSTAIN"))
    assert result.outcome == OUTCOME_ABSTAIN


def test_abstaining_where_the_evidence_is_silent_is_correct():
    result = score_response(_case("legal-abstain"), _envelope("ANSWER: UNVERIFIED"))
    assert result.outcome == OUTCOME_CORRECT


def test_wrongly_answering_an_unanswerable_case_is_incorrect():
    result = score_response(_case("legal-abstain"), _envelope("ANSWER: VALIDATED"))
    assert result.outcome == OUTCOME_INCORRECT


# ── the agentic workload scores its REAL contract ──────────────────────────────
def test_right_tool_and_argument_scores_correct():
    result = score_response(
        _case("agentic-fetch"),
        _envelope('[{"tool": "fetch_document", "arguments": {"id": "doc-17"}}]'),
    )
    assert result.outcome == OUTCOME_CORRECT


def test_right_tool_with_wrong_argument_is_incorrect():
    result = score_response(
        _case("agentic-fetch"),
        _envelope('[{"tool": "fetch_document", "arguments": {"id": "doc-99"}}]'),
    )
    assert result.outcome == OUTCOME_INCORRECT
    assert result.code == "wrong-argument"


def test_wrong_tool_is_incorrect():
    result = score_response(
        _case("agentic-search"),
        _envelope('[{"tool": "summarize", "arguments": {"text": "leave"}}]'),
    )
    assert result.outcome == OUTCOME_INCORRECT
    assert result.code == "wrong-tool"


def test_a_fenced_but_valid_tool_call_is_the_CONTRACT_code_not_a_wrong_answer():
    """JEV-OPEN-101's fenced failure mode, scored on the correctness axis.

    The answer inside the fence is correct.  Under the strict policy it is still a
    contract failure, so the outcome is `invalid` and it carries the format code —
    which is why the two dimensions are reported together and never merged.
    """
    fenced = '```json\n[{"tool": "search_corpus", "arguments": {"query": "annual leave"}}]\n```'
    result = score_response(_case("agentic-search"), _envelope(fenced))
    assert result.outcome == OUTCOME_INVALID
    assert result.code == "fenced-json"
    assert result.policy == "strict"


def test_off_menu_case_answered_with_a_tool_call_is_incorrect_not_unreadable():
    """The article's off-menu probe: the interface exists, the choice does not."""
    result = score_response(
        _case("mix-no-tool"),
        _envelope('[{"tool": "search_corpus", "arguments": {"query": "2+2"}}]'),
    )
    assert result.outcome == OUTCOME_INCORRECT
    assert result.code == "wrong-tool"


# ── the arithmetic must not flatter a model ───────────────────────────────────
def test_accuracy_counts_invalid_and_abstain_in_the_denominator():
    results = [
        score_response(_case("chat-arithmetic"), _envelope("ANSWER: 6")),  # correct
        score_response(_case("chat-order"), _envelope("nonsense")),  # invalid
        score_response(_case("mix-unit"), _envelope("ANSWER: ABSTAIN")),  # abstain
        score_response(_case("mix-two-step"), _envelope("ANSWER: 3")),  # incorrect
    ]
    summary = summarise(results)
    assert summary["cases"] == 4
    assert summary["counts"][OUTCOME_CORRECT] == 1
    # Dropping invalid and abstain would report 50%; the honest figure is 25%.
    assert summary["accuracy"] == pytest.approx(0.25)


def test_summary_is_per_workload_as_well_as_per_outcome():
    results = [
        score_response(_case("legal-contradiction"), _envelope("ANSWER: CONTRADICTED")),
        score_response(_case("legal-abstain"), _envelope("ANSWER: UNVERIFIED")),
    ]
    summary = summarise(results)
    assert summary["by_workload"]["legal"]["cases"] == 2
    assert summary["by_workload"]["legal"][OUTCOME_CORRECT] == 2


def test_scoring_is_deterministic():
    case = _case("mix-not-stated")
    first = score_response(case, _envelope("ANSWER: 400")).as_dict()
    second = score_response(case, _envelope("ANSWER: 400")).as_dict()
    assert first == second


# ── safety and I/O edges ─────────────────────────────────────────────────────
def test_a_remote_base_url_is_refused_before_any_request_is_sent():
    with pytest.raises(SystemExit) as excinfo:
        llm_outcome_cases._post_chat("https://api.example.com/v1", "m", "prompt", 1.0)
    assert "non-loopback" in str(excinfo.value)


def test_a_response_log_without_a_case_id_is_rejected(tmp_path):
    log = tmp_path / "bad.jsonl"
    log.write_text(json.dumps({"response": {"choices": []}}) + "\n", encoding="utf-8")
    with pytest.raises(SystemExit) as excinfo:
        llm_outcome_cases._load_response_log(str(log))
    assert "case" in str(excinfo.value)
