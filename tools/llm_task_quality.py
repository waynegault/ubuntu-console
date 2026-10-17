#!/usr/bin/env python3
"""Deterministic task-output contract checks for selected autotune winners.

These checks validate explicit response formats, not factual correctness. They
are deliberately separate from throughput samples and require no judge model.

Every violation carries a typed CODE, not only prose.  The code is what makes a
failure countable and comparable across models: "the model cannot follow the
tool contract" and "the model wrapped a correct answer in ```json" are different
findings, and only the second one is fixable by wording the prompt.

# REF: "Jev Your Engines: Seven Open Decision Models vs. a Generative LLM"
# (Lambert Leong, TDS, 2026-10-15) —
# https://towardsdatascience.com/jev-your-engines-seven-open-decision-models-vs-a-generative-llm/
# The article measured 9.0% contract failures on its JSON-generation baseline and
# found that ALL of them were valid JSON objects wrapped in markdown fences.  Its
# rule: "A wrapper that strips fences would change the policy and should be
# measured as a separate configuration."  Hence `--tolerate-fence` here: the
# DEFAULT policy is strict (a fence is a failure, coded `fenced-json`), and the
# tolerant variant is an explicitly named, separately reported configuration —
# never a silent rescue inside the strict path.

SCOPE NOTE (the article's "say what the number does not cover" habit): the
autotune caller issues ONE probe per workload, so its result is a smoke test of
the contract, not a measured failure RATE.  A rate needs repeated samples; the
`--repeat` flag exists for that and prints the per-code counts it observed.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, field
from typing import Any


_TOOL_ARGUMENTS = {
    "search_corpus": "query",
    "fetch_document": "id",
    "summarize": "text",
}
_VERDICT_LABEL = re.compile(r"\b(?:VALIDATED|CONTRADICTED|UNVERIFIED)\b")
_FENCE = re.compile(
    r"\A```[A-Za-z0-9_+-]*[ \t]*\r?\n(?P<body>.*?)\r?\n?```\Z", re.DOTALL
)
_FENCE_ANY = re.compile(
    r"```[A-Za-z0-9_+-]*[ \t]*\r?\n(?P<body>.*?)\r?\n?```", re.DOTALL
)

# The two policies this checker can report.  They are DIFFERENT CONFIGURATIONS
# and must never be pooled into one pass rate.
POLICY_STRICT = "strict"
POLICY_FENCE_TOLERATED = "fence-tolerated"

# One code per distinguishable failure mode.  Keep these stable: they are the
# keys a report counts on.
CODE_OK = "ok"
CODE_UNSUPPORTED_WORKLOAD = "unsupported-workload"
CODE_WRONG_SHAPE = "wrong-shape"
CODE_EMPTY = "empty"
CODE_FENCED_JSON = "fenced-json"
CODE_FENCED_JSON_PROSE = "fenced-json-prose"
CODE_RAW_SYNTAX = "raw-syntax"
CODE_UNSUPPORTED_TOOL = "unsupported-tool"
CODE_BAD_ARGUMENTS = "bad-arguments"

CODES = (
    CODE_OK,
    CODE_UNSUPPORTED_WORKLOAD,
    CODE_WRONG_SHAPE,
    CODE_EMPTY,
    CODE_FENCED_JSON,
    CODE_FENCED_JSON_PROSE,
    CODE_RAW_SYNTAX,
    CODE_UNSUPPORTED_TOOL,
    CODE_BAD_ARGUMENTS,
)


@dataclass(frozen=True)
class Verdict:
    """One classified outcome for one response.

    `ok` is the verdict under the policy that produced it; `code` is always
    present so even a tolerated fence is countable, and `tolerated` records that
    this configuration accepted something the strict policy would reject.
    """

    code: str
    detail: str
    policy: str = POLICY_STRICT
    ok: bool = False
    tolerated: bool = False
    passes: int = field(default=1)

    def as_dict(self) -> dict[str, Any]:
        return {
            "ok": self.ok,
            "code": self.code,
            "detail": self.detail,
            "policy": self.policy,
            "tolerated": self.tolerated,
            "passes": self.passes,
        }


def _violation(code: str, detail: str, *, policy: str = POLICY_STRICT) -> Verdict:
    return Verdict(code=code, detail=detail, policy=policy, ok=False)


def _fence_body(content: str) -> str | None:
    """Return the body of a single surrounding markdown fence, else None."""
    match = _FENCE.match(content)
    return match.group("body") if match else None


def _fence_anywhere(content: str) -> str | None:
    """Return the body of the first markdown fence anywhere in the text, else None."""
    match = _FENCE_ANY.search(content)
    return match.group("body") if match else None


def check_response(
    workload: str,
    response: Any,
    *,
    tolerate_fence: bool = False,
) -> Verdict:
    """Classify one response against its workload contract.

    `tolerate_fence=True` selects the fence-tolerated configuration: a valid JSON
    payload wrapped in one markdown fence passes there, but is still reported
    with `code="fenced-json"` and `tolerated=True` so the two configurations stay
    separately countable.
    """
    policy = POLICY_FENCE_TOLERATED if tolerate_fence else POLICY_STRICT

    if workload not in {"legal", "agentic"}:
        return _violation(
            CODE_UNSUPPORTED_WORKLOAD,
            f"unsupported quality workload: {workload}",
            policy=policy,
        )
    if not isinstance(response, dict):
        return _violation(
            CODE_WRONG_SHAPE, "response must be a JSON object", policy=policy
        )

    choices = response.get("choices")
    if not isinstance(choices, list) or not choices or not isinstance(choices[0], dict):
        return _violation(
            CODE_WRONG_SHAPE, "response must contain a first choice", policy=policy
        )
    message = choices[0].get("message")
    if not isinstance(message, dict) or not isinstance(message.get("content"), str):
        return _violation(
            CODE_WRONG_SHAPE, "first choice must contain assistant text", policy=policy
        )
    content = message["content"].strip()
    if not content:
        return _violation(CODE_EMPTY, "assistant text is empty", policy=policy)

    if workload == "legal":
        if not _VERDICT_LABEL.search(content):
            return _violation(
                CODE_WRONG_SHAPE,
                "legal response lacks a requested VALIDATED, CONTRADICTED, or UNVERIFIED label",
                policy=policy,
            )
        return Verdict(
            code=CODE_OK, detail="legal response contract", policy=policy, ok=True
        )

    fenced = _fence_body(content)
    fence_code = CODE_FENCED_JSON if fenced is not None else None
    payload = fenced
    if fenced is None:
        # A fence wrapped in prose is a DIFFERENT failure mode from a single
        # surrounding fence: the message also carries text the contract never
        # allowed.  It gets its own code, and the tolerant configuration does not
        # accept it — tolerating both would be a third policy, itself unmeasured.
        inner = _fence_anywhere(content)
        if inner is not None:
            fenced, payload, fence_code = inner, inner, CODE_FENCED_JSON_PROSE
    if payload is None:
        payload = content
    try:
        calls = json.loads(payload)
    except json.JSONDecodeError as exc:
        if fence_code is not None:
            # A fence around something that is not JSON either: still a fence
            # finding, but say that the body failed to parse too.
            return _violation(
                fence_code,
                f"markdown fence around unparseable JSON body: {exc.msg}",
                policy=policy,
            )
        return _violation(
            CODE_RAW_SYNTAX,
            f"agentic response is not a JSON array: {exc.msg}",
            policy=policy,
        )

    shape = _check_calls(calls, policy=policy)
    if fence_code is not None:
        # Valid JSON, valid shape, but wrapped in a fence.  This is the article's
        # exact failure mode: classify it, then let the POLICY decide — never
        # silently strip inside the strict configuration.
        fence_note = (
            "valid JSON wrapped in a markdown fence"
            if fence_code == CODE_FENCED_JSON
            else "valid JSON in a markdown fence with surrounding prose"
        )
        if shape.code != CODE_OK:
            return _violation(
                fence_code,
                f"{fence_note}; body also failed the contract: {shape.detail}",
                policy=policy,
            )
        if tolerate_fence and fence_code == CODE_FENCED_JSON:
            return Verdict(
                code=fence_code,
                detail=fence_note,
                policy=policy,
                ok=True,
                tolerated=True,
            )
        return _violation(fence_code, fence_note, policy=policy)
    return shape


def _check_calls(calls: Any, *, policy: str) -> Verdict:
    if not isinstance(calls, list) or not calls:
        return _violation(
            CODE_WRONG_SHAPE,
            "agentic response must be a non-empty JSON array",
            policy=policy,
        )
    for index, call in enumerate(calls):
        if not isinstance(call, dict) or set(call) != {"tool", "arguments"}:
            return _violation(
                CODE_WRONG_SHAPE,
                f"agentic call {index} must contain only tool and arguments",
                policy=policy,
            )
        tool = call["tool"]
        if not isinstance(tool, str) or tool not in _TOOL_ARGUMENTS:
            return _violation(
                CODE_UNSUPPORTED_TOOL,
                f"agentic call {index} names an unsupported tool: {tool!r}",
                policy=policy,
            )
        arguments = call["arguments"]
        argument_name = _TOOL_ARGUMENTS[tool]
        if (
            not isinstance(arguments, dict)
            or set(arguments) != {argument_name}
            or not isinstance(arguments[argument_name], str)
            or not arguments[argument_name].strip()
        ):
            return _violation(
                CODE_BAD_ARGUMENTS,
                f"agentic call {index} has invalid arguments for {tool}",
                policy=policy,
            )
    return Verdict(
        code=CODE_OK, detail="agentic response contract", policy=policy, ok=True
    )


def validate_response(workload: str, response: Any) -> str | None:
    """Return a contract violation, or None when a response meets its task shape.

    Backwards-compatible string-returning wrapper over `check_response` under the
    strict policy; callers that need the CODE use `check_response` directly.
    """
    verdict = check_response(workload, response)
    return None if verdict.ok else verdict.detail


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workload", choices=("legal", "agentic"), required=True)
    parser.add_argument(
        "--tolerate-fence",
        action="store_true",
        help=(
            "select the fence-tolerated configuration (a valid JSON payload in one "
            "markdown fence passes); reported separately from the strict policy"
        ),
    )
    parser.add_argument(
        "--repeat",
        type=int,
        default=1,
        metavar="N",
        help=(
            "how many responses this invocation observes (stdin must then be one JSON "
            "response per line, or a JSON array of responses); prints per-code counts — "
            "a single response is a smoke test, not a rate"
        ),
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="emit the classified result as JSON on stdout",
    )
    args = parser.parse_args()

    raw = sys.stdin.read()
    if args.repeat > 1:
        responses = _read_many(raw)
        if responses is None:
            print(
                "task-quality gate failed: with --repeat>1 stdin must be one JSON "
                "response per line, or a JSON array of responses",
                file=sys.stderr,
            )
            return 1
    else:
        try:
            responses = [json.loads(raw)]
        except (json.JSONDecodeError, UnicodeDecodeError) as exc:
            print(
                f"task-quality gate failed: invalid response JSON: {exc}",
                file=sys.stderr,
            )
            return 1

    verdicts = [
        check_response(args.workload, response, tolerate_fence=args.tolerate_fence)
        for response in responses
    ]
    failed = [v for v in verdicts if not v.ok]
    counts: dict[str, int] = {}
    for verdict in verdicts:
        counts[verdict.code] = counts.get(verdict.code, 0) + 1

    if args.json:
        print(
            json.dumps(
                {
                    "workload": args.workload,
                    "policy": verdicts[0].policy,
                    "probes": len(verdicts),
                    "passed": len(verdicts) - len(failed),
                    "failed": len(failed),
                    "counts": counts,
                    "verdicts": [v.as_dict() for v in verdicts],
                }
            )
        )
    elif len(verdicts) == 1:
        verdict = verdicts[0]
        if verdict.ok:
            note = " [tolerated: markdown fence stripped]" if verdict.tolerated else ""
            print(
                f"task-quality gate passed: {args.workload} response contract "
                f"(policy={verdict.policy}){note}"
            )
        else:
            print(
                f"task-quality gate failed: [{verdict.code}] {verdict.detail} "
                f"(policy={verdict.policy})",
                file=sys.stderr,
            )
    else:
        # A measured RATE, not a smoke test: every code is reported so a format
        # regression cannot hide inside one aggregate percentage.
        summary = ", ".join(f"{code}={count}" for code, count in sorted(counts.items()))
        line = (
            f"task-quality probes: {len(verdicts)} responses, "
            f"{len(verdicts) - len(failed)} passed, {len(failed)} failed "
            f"(policy={verdicts[0].policy}); counts: {summary}"
        )
        print(line, file=sys.stderr if failed else sys.stdout)

    return 0 if not failed else 1


def _read_many(raw: str) -> list[Any] | None:
    text = raw.strip()
    if not text:
        return None
    if text.startswith("["):
        try:
            parsed = json.loads(text)
        except json.JSONDecodeError:
            return None
        return parsed if isinstance(parsed, list) else None
    out: list[Any] = []
    for line in text.splitlines():
        if not line.strip():
            continue
        try:
            out.append(json.loads(line))
        except json.JSONDecodeError:
            return None
    return out or None


if __name__ == "__main__":
    raise SystemExit(main())
