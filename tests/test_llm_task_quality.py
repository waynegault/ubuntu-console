import json

import pytest

from tools.llm_task_quality import validate_response


def _response(content: str) -> dict[str, object]:
    return {"choices": [{"message": {"content": content}}]}


def test_legal_contract_requires_one_of_the_prompt_verdict_labels():
    assert validate_response("legal", _response("Finding: VALIDATED — the evidence supports it.")) is None
    assert validate_response("legal", _response("The claim is not supported.")) is not None


def test_agentic_contract_accepts_declared_tools_and_arguments():
    content = json.dumps([
        {"tool": "search_corpus", "arguments": {"query": "annual leave policy"}},
        {"tool": "fetch_document", "arguments": {"id": "doc-1"}},
        {"tool": "summarize", "arguments": {"text": "document text"}},
    ])
    assert validate_response("agentic", _response(content)) is None


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
