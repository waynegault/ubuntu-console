#!/usr/bin/env python3
"""Deterministic task-output contract checks for selected autotune winners.

These checks validate explicit response formats, not factual correctness. They
are deliberately separate from throughput samples and require no judge model.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from typing import Any


_TOOL_ARGUMENTS = {
    "search_corpus": "query",
    "fetch_document": "id",
    "summarize": "text",
}
_VERDICT_LABEL = re.compile(r"\b(?:VALIDATED|CONTRADICTED|UNVERIFIED)\b")


def validate_response(workload: str, response: Any) -> str | None:
    """Return a contract violation, or None when a response meets its task shape."""
    if workload not in {"legal", "agentic"}:
        return f"unsupported quality workload: {workload}"
    if not isinstance(response, dict):
        return "response must be a JSON object"

    choices = response.get("choices")
    if not isinstance(choices, list) or not choices or not isinstance(choices[0], dict):
        return "response must contain a first choice"
    message = choices[0].get("message")
    if not isinstance(message, dict) or not isinstance(message.get("content"), str):
        return "first choice must contain assistant text"
    content = message["content"].strip()
    if not content:
        return "assistant text is empty"

    if workload == "legal":
        if not _VERDICT_LABEL.search(content):
            return "legal response lacks a requested VALIDATED, CONTRADICTED, or UNVERIFIED label"
        return None

    try:
        calls = json.loads(content)
    except json.JSONDecodeError:
        return "agentic response is not a JSON array"
    if not isinstance(calls, list) or not calls:
        return "agentic response must be a non-empty JSON array"
    for index, call in enumerate(calls):
        if not isinstance(call, dict) or set(call) != {"tool", "arguments"}:
            return f"agentic call {index} must contain only tool and arguments"
        tool = call["tool"]
        if not isinstance(tool, str) or tool not in _TOOL_ARGUMENTS:
            return f"agentic call {index} names an unsupported tool"
        arguments = call["arguments"]
        argument_name = _TOOL_ARGUMENTS[tool]
        if (
            not isinstance(arguments, dict)
            or set(arguments) != {argument_name}
            or not isinstance(arguments[argument_name], str)
            or not arguments[argument_name].strip()
        ):
            return f"agentic call {index} has invalid arguments for {tool}"
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workload", choices=("legal", "agentic"), required=True)
    args = parser.parse_args()
    try:
        response = json.load(sys.stdin)
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        print(f"task-quality gate failed: invalid response JSON: {exc}", file=sys.stderr)
        return 1

    error = validate_response(args.workload, response)
    if error:
        print(f"task-quality gate failed: {error}", file=sys.stderr)
        return 1
    print(f"task-quality gate passed: {args.workload} response contract")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
