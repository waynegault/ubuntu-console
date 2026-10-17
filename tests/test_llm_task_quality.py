"""Contract-gate tests, including the article's fenced-JSON failure mode.

# REF: "Jev Your Engines: Seven Open Decision Models vs. a Generative LLM"
# (Lambert Leong, TDS, 2026-10-15) —
# https://towardsdatascience.com/jev-your-engines-seven-open-decision-models-vs-a-generative-llm/
# 9.0% of the article's JSON-generation baseline responses failed its contract and
# every one of them was valid JSON wrapped in markdown fences, so "fenced" must be
# its own counted code and the tolerant policy its own reported configuration.
"""

import json

import pytest

from tools.llm_task_quality import (
    CODE_BAD_ARGUMENTS,
    CODE_EMPTY,
    CODE_FENCED_JSON,
    CODE_FENCED_JSON_PROSE,
    CODE_OK,
    CODE_RAW_SYNTAX,
    CODE_UNSUPPORTED_TOOL,
    CODE_WRONG_SHAPE,
    POLICY_FENCE_TOLERATED,
    POLICY_STRICT,
    check_response,
    validate_response,
)

_CALLS = [
    {"tool": "search_corpus", "arguments": {"query": "annual leave policy"}},
    {"tool": "fetch_document", "arguments": {"id": "doc-1"}},
    {"tool": "summarize", "arguments": {"text": "document text"}},
]


def _response(content: str) -> dict[str, object]:
    return {"choices": [{"message": {"content": content}}]}


def test_legal_contract_requires_one_of_the_prompt_verdict_labels():
    assert (
        validate_response(
            "legal", _response("Finding: VALIDATED — the evidence supports it.")
        )
        is None
    )
    assert (
        validate_response("legal", _response("The claim is not supported.")) is not None
    )


def test_agentic_contract_accepts_declared_tools_and_arguments():
    assert validate_response("agentic", _response(json.dumps(_CALLS))) is None


@pytest.mark.parametrize(
    "content",
    [
        "not json",
        "{}",
        "[]",
        '[{"tool":"delete_file","arguments":{"id":"1"}}]',
        '[{"tool":[],"arguments":{}}]',
        '[{"tool":"fetch_document","arguments":{"query":"wrong key"}}]',
        '[{"tool":"search_corpus","arguments":{"query":"  "}}]',
        '[{"name":"search_corpus","arguments":{"query":"x"}}]',
    ],
)
def test_agentic_contract_rejects_invalid_call_shapes(content: str):
    assert validate_response("agentic", _response(content)) is not None


def test_contract_rejects_malformed_or_empty_chat_responses():
    assert validate_response("legal", {"choices": []}) is not None
    assert validate_response("legal", _response("  ")) is not None
    assert validate_response("agentic", _response("")) is not None


def test_every_violation_carries_a_typed_code_not_just_prose():
    cases = {
        CODE_RAW_SYNTAX: "not json",
        CODE_WRONG_SHAPE: "{}",
        CODE_UNSUPPORTED_TOOL: '[{"tool":"delete_file","arguments":{"id":"1"}}]',
        CODE_BAD_ARGUMENTS: '[{"tool":"fetch_document","arguments":{"query":"wrong key"}}]',
    }
    for expected, content in cases.items():
        verdict = check_response("agentic", _response(content))
        assert verdict.code == expected, content
        assert not verdict.ok
        assert verdict.policy == POLICY_STRICT
        assert verdict.detail

    assert check_response("agentic", _response(json.dumps(_CALLS))).code == CODE_OK
    assert check_response("agentic", _response("  ")).code == CODE_EMPTY


def test_fenced_valid_json_is_its_own_code_and_fails_the_strict_policy():
    fenced = "```json\n" + json.dumps(_CALLS) + "\n```"
    verdict = check_response("agentic", _response(fenced))
    assert verdict.code == CODE_FENCED_JSON
    assert not verdict.ok
    assert verdict.policy == POLICY_STRICT
    # The strict verdict is unchanged by the tolerant policy existing.
    assert validate_response("agentic", _response(fenced)) is not None


def test_fence_tolerance_is_a_separate_configuration_that_still_counts_the_fence():
    fenced = "```json\n" + json.dumps(_CALLS) + "\n```"
    tolerated = check_response("agentic", _response(fenced), tolerate_fence=True)
    assert tolerated.ok
    assert tolerated.tolerated
    assert tolerated.code == CODE_FENCED_JSON
    assert tolerated.policy == POLICY_FENCE_TOLERATED


def test_a_bare_surrounding_fence_needs_no_language_tag():
    fenced = "```\n" + json.dumps(_CALLS) + "\n```"
    assert check_response("agentic", _response(fenced)).code == CODE_FENCED_JSON


def test_a_fence_around_non_json_is_reported_as_a_fence_finding():
    verdict = check_response("agentic", _response("```\nnot json at all\n```"))
    assert verdict.code == CODE_FENCED_JSON
    assert not verdict.ok


def test_fence_tolerance_does_not_excuse_a_bad_body():
    fenced = "```json\n[]\n```"
    verdict = check_response("agentic", _response(fenced), tolerate_fence=True)
    assert not verdict.ok
    assert verdict.code == CODE_FENCED_JSON


def test_prose_before_or_after_the_fence_is_not_tolerated():
    prose_then_fence = "Sure! Here you go:\n```json\n" + json.dumps(_CALLS) + "\n```"
    strict = check_response("agentic", _response(prose_then_fence))
    assert strict.code == CODE_FENCED_JSON_PROSE
    assert not strict.ok
    tolerated = check_response(
        "agentic", _response(prose_then_fence), tolerate_fence=True
    )
    assert not tolerated.ok
    assert tolerated.code == CODE_FENCED_JSON_PROSE
    assert tolerated.policy == POLICY_FENCE_TOLERATED


def test_fence_and_prose_codes_are_distinct_so_they_never_pool():
    surrounding = "```json\n" + json.dumps(_CALLS) + "\n```"
    with_prose = "Here is the plan:\n```json\n" + json.dumps(_CALLS) + "\n```"
    assert (
        check_response("agentic", _response(surrounding)).code
        != check_response("agentic", _response(with_prose)).code
    )
