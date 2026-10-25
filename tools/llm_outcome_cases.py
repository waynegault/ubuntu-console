#!/usr/bin/env python3
"""Held-out correctness cases: score a model on RIGHT ANSWERS, not just shape.

`tools/llm_benchmark.py` measures throughput. `tools/llm_task_quality.py` measures
the response CONTRACT and says outright that it does not measure factual
correctness.  Neither produces a number for "was the answer right", so a
selection that reads only those two has no quality axis: the fastest model that
did not break the tool-call shape wins, and a faster model with worse answers
cannot lose.

This tool is that missing axis.  It ships a small held-out case set — a handful
per workload, each with a known right answer that is determinable from the
prompt itself — and scores every response into exactly one of four outcomes:

    correct    the expected answer
    incorrect  a well-formed answer that is WRONG
    abstain    the model declined (its own abstention, not a parse failure)
    invalid    nothing scorable: empty text, no answer marker, or a response
               that fails its workload's format contract (that contract's code
               from `tools/llm_task_quality.py` is carried through)

`incorrect` and `invalid` are deliberately separate.  Pooling "answered wrongly"
with "answered in the wrong shape" is the aggregation error the source article
warns about: they have different fixes (a better model versus a better prompt or
a fence-tolerant policy), so a report that cannot tell them apart cannot guide a
choice.

The cases are HELD OUT in the specific sense that matters here: they are not the
autotune probe prompts (`PROMPTS_AGENTIC` / the legal probe), so a model cannot
score on a case it was already certified against by the contract gate.  There is
no judge model in this path — every expectation is a deterministic string, token
or numeric comparison, so the same response always scores the same way.

SCOPE (say what the number does not cover):
  * Abstention detection is lexical.  A model that says "I cannot determine this
    from the evidence" is classed `abstain`; one that signals the same thing in
    wording not in `_ABSTAIN_MARKERS` is classed `invalid`.  The marker list is
    short on purpose — it is a detector, not a judge.
  * Twelve cases across four workloads is a SMOKE-SIZED correctness signal, not
    a benchmark.  It is enough to catch a model that is fast and confidently
    wrong, and it is not enough to rank two good models apart.  `--cases` prints
    the full set so the size is never a surprise.
  * These cases are not factual or legal advice and do not test domain expertise;
    they test whether the model produces the right answer to a small, closed
    question asked in the same shape the console actually uses.

# REF: "Jev Your Engines: Seven Open Decision Models vs. a Generative LLM"
# (Lambert Leong, TDS, 2026-10-15) —
# https://towardsdatascience.com/jev-your-engines-seven-open-decision-models-vs-a-generative-llm/
# The article's recipe: "Give them the same requests and menus. Measure correct
# routes, invalid outputs, latency and abstentions together."  Four dimensions were
# named and three of them (correct, invalid, abstain) had no implementation anywhere in
# this repo, which is why a throughput winner could not be challenged on quality.

Usage:
    # score responses recorded earlier (no server, no GPU)
    python tools/llm_outcome_cases.py --responses responses.jsonl --json

    # ask a running llama-server, then save the artefact for the selection report
    python tools/llm_outcome_cases.py --run --write ~/.llm/outcomes/latest.json

    # see what the cases actually ask
    python tools/llm_outcome_cases.py --cases
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from typing import Any

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if REPO_ROOT not in sys.path:
    sys.path.insert(0, REPO_ROOT)

from tools.llm_task_quality import (  # noqa: E402 - repo root must be on sys.path first
    CODE_BAD_ARGUMENTS,
    CODE_EMPTY,
    CODE_OK,
    CODE_RAW_SYNTAX,
    CODE_WRONG_SHAPE,
    check_response,
)

# Outcomes.  One per response, never pooled in the report.
OUTCOME_CORRECT = "correct"
OUTCOME_INCORRECT = "incorrect"
OUTCOME_ABSTAIN = "abstain"
OUTCOME_INVALID = "invalid"

OUTCOMES = (OUTCOME_CORRECT, OUTCOME_INCORRECT, OUTCOME_ABSTAIN, OUTCOME_INVALID)

# Codes this tool adds to the ones llm_task_quality already owns.  Prefixed so a
# report can never confuse "the model abstained" with "the checker could not read
# the answer".
CODE_NO_ANSWER_MARKER = "outcome-no-answer-marker"
CODE_WRONG_TOOL = "wrong-tool"
CODE_WRONG_ARGUMENT = "wrong-argument"

# The exact answer marker asked for by every case prompt.  One regex, so the
# extraction is not re-derived per case.
_ANSWER_LINE = re.compile(r"^[ \t]*ANSWER:[ \t]*(?P<token>[^(\r\n]*)", re.MULTILINE | re.IGNORECASE)

# Lexical abstention detection for responses that carry no ANSWER line.  Short on
# purpose: an over-wide list would silently reclassify wrong answers as abstentions,
# which is the flattering direction.
_ABSTAIN_MARKERS = (
    "abstain",
    "cannot determine",
    "can't determine",
    "cannot be determined",
    "unable to determine",
    "insufficient information",
    "not enough information",
    "no information",
    "insufficient evidence",
)

# Workloads the contract gate covers.  `chat` and `mix` have no JSON contract in
# `llm_task_quality`, so their correctness is scored without a shape gate — stated
# here rather than left for a reader to infer from an absent code.
CONTRACT_WORKLOADS = ("legal", "agentic")


@dataclass(frozen=True)
class Case:
    """One held-out correctness case with a deterministic right answer.

    `expect` is compared with the ANSWER token (or, for `kind="tool_call"`, with
    the first parsed tool call).  `abstain` marks a case whose CORRECT answer is
    an abstention — the article's abstention dimension, asked directly.
    """

    id: str
    workload: str
    prompt: str
    expect: tuple[str, ...]
    kind: str = "token"
    abstain: bool = False
    note: str = ""
    # `kind="tool_call"` compares the FIRST parsed call instead of an ANSWER token:
    # the agentic workloads' real contract is a JSON array of tool calls, so scoring
    # them on a text token would measure a shape the console never asks for.
    tool: str = ""
    argument_name: str = ""
    argument_expect: str = ""
    argument_mode: str = "contains"


# ── the held-out case set ─────────────────────────────────────────────────────
# Kept in code, not in a fixture file, so a case cannot drift out of sync with the
# tool that scores it.  Every expected answer is derivable from its own prompt.
CASES: tuple[Case, ...] = (
    # ── chat ──────────────────────────────────────────────────────────────────
    Case(
        id="chat-arithmetic",
        workload="chat",
        prompt=(
            "A tank holds 12 litres. It is filled to 25% of capacity, then 3 more "
            "litres are added. Reply with exactly one line: ANSWER: <litres>"
        ),
        expect=("6", "6l", "6 litres", "6.0"),
        note="25% of 12 = 3, plus 3 = 6; wording-tolerant token match",
    ),
    Case(
        id="chat-instruction-follow",
        workload="chat",
        prompt=(
            "Reply with exactly one line and nothing else: ANSWER: ALPHA — "
            "do not add punctuation or explanation."
        ),
        expect=("ALPHA",),
        note="tests literal instruction following with no reasoning content at all",
    ),
    Case(
        id="chat-order",
        workload="chat",
        prompt=(
            "Sort these three numbers ascending and reply with exactly one line: "
            "ANSWER: n1,n2,n3 — numbers: 14, 3, 9"
        ),
        expect=("3,9,14", "3, 9, 14"),
        note="comma-form is part of the contract, so a missing comma is not correct",
    ),
    # ── legal ─────────────────────────────────────────────────────────────────
    Case(
        id="legal-contradiction",
        workload="legal",
        prompt=(
            "Clause A: 'The tenant shall give 30 days notice.' Clause B: 'The tenant "
            "shall give 7 days notice.' Do the clauses contradict each other? Reply "
            "with exactly one line: ANSWER: VALIDATED or ANSWER: CONTRADICTED or "
            "ANSWER: UNVERIFIED"
        ),
        expect=("CONTRADICTED",),
        note="the token set doubles as a legal contract label, so the shape gate applies",
    ),
    Case(
        id="legal-consistency",
        workload="legal",
        prompt=(
            "Clause A: 'The rent is payable monthly in advance.' Clause B: 'Payment "
            "falls due on the first day of each month.' Do the clauses contradict each "
            "other? Reply with exactly one line: ANSWER: VALIDATED or ANSWER: "
            "CONTRADICTED or ANSWER: UNVERIFIED"
        ),
        expect=("VALIDATED",),
        note="agreement between clauses, not the presence of a claim",
    ),
    Case(
        id="legal-abstain",
        workload="legal",
        prompt=(
            "Clause A: 'The tenant shall maintain the garden.' Is the monthly rent "
            "above or below the market rate? Reply with exactly one line: ANSWER: "
            "VALIDATED or ANSWER: CONTRADICTED or ANSWER: UNVERIFIED"
        ),
        expect=("UNVERIFIED",),
        abstain=True,
        note=(
            "the evidence does not address the question, so abstaining is the "
            "correct answer — the article's abstention dimension, made right-answerable"
        ),
    ),
    # ── agentic ───────────────────────────────────────────────────────────────
    # These three are `tool_call` cases: the prompt asks for the JSON array of tool
    # calls the agentic contract already requires, so the SHAPE gate and the
    # CORRECTNESS check score the same response instead of two different ones.
    Case(
        id="agentic-search",
        workload="agentic",
        prompt=(
            "You may call search_corpus(query), fetch_document(id) or summarize(text). "
            "Find the annual leave policy. Reply with a JSON array containing exactly "
            "one tool call, for example [{\"tool\": \"summarize\", \"arguments\": "
            "{\"text\": \"...\"}}]"
        ),
        expect=("search_corpus(query~leave)",),
        kind="tool_call",
        tool="search_corpus",
        argument_name="query",
        argument_expect="leave",
        note="the right tool AND an argument that actually asks for leave",
    ),
    Case(
        id="agentic-fetch",
        workload="agentic",
        prompt=(
            "You may call search_corpus(query), fetch_document(id) or summarize(text). "
            "The corpus search already returned document id doc-17 and you want its "
            "text. Reply with a JSON array containing exactly one tool call."
        ),
        expect=("fetch_document(id=doc-17)",),
        kind="tool_call",
        tool="fetch_document",
        argument_name="id",
        argument_expect="doc-17",
        argument_mode="equals",
        note="second-step routing: the search is done, so repeating it is wrong",
    ),
    Case(
        id="agentic-argument",
        workload="agentic",
        prompt=(
            "You may call search_corpus(query), fetch_document(id) or summarize(text). "
            "Summarise this text: 'The rent is due on the 1st of each month.' Reply "
            "with a JSON array containing exactly one tool call."
        ),
        expect=("summarize(text~rent)",),
        kind="tool_call",
        tool="summarize",
        argument_name="text",
        argument_expect="rent",
        note=(
            "right tool, wrong argument is the contract's bad-arguments failure — "
            "scored here as an answer error, not a shape error"
        ),
    ),
    # ── mix ───────────────────────────────────────────────────────────────────
    Case(
        id="mix-two-step",
        workload="mix",
        prompt=(
            "A document states: 'Retention is 6 years for payroll records and 3 years "
            "for marketing records.' Reply with exactly one line: ANSWER: <years> — "
            "the retention period for payroll records only."
        ),
        expect=("6", "6 years", "6y"),
        note="the distractor answer is present in the same sentence",
    ),
    Case(
        id="mix-unit",
        workload="mix",
        prompt=(
            "A model decodes 240 tokens in 8 seconds. Reply with exactly one line: "
            "ANSWER: <tokens per second>"
        ),
        expect=("30", "30 tps", "30 tokens per second", "30/s"),
        note="unit-bearing arithmetic; the number must not be inverted",
    ),
    Case(
        id="mix-no-tool",
        workload="mix",
        prompt=(
            "You may call search_corpus(query), fetch_document(id) or summarize(text). "
            "The user asks what 2 + 2 is; no tool is needed. Reply with exactly one "
            "line: ANSWER: NO_TOOL"
        ),
        expect=("NO_TOOL",),
        note=(
            "the article's off-menu case: a model that always emits a tool call has "
            "the interface and not the choice"
        ),
    ),
    Case(
        id="mix-not-stated",
        workload="mix",
        prompt=(
            "A document states: 'The licence fee is £400 per year.' Reply with exactly "
            "one line: ANSWER: <amount> — the licence fee per quarter, assuming even "
            "quarterly instalments. If the document does not permit the calculation, "
            "reply ANSWER: ABSTAIN"
        ),
        expect=("ABSTAIN", "100"),
        note=(
            "two defensible readings (abstain, or divide by four), so either is "
            "accepted and only a confident wrong number is incorrect"
        ),
    ),
)

_CASES_BY_ID: dict[str, Case] = {case.id: case for case in CASES}


@dataclass
class CaseResult:
    """One scored case: the outcome, its code, and what was actually seen."""

    case_id: str
    workload: str
    outcome: str
    code: str
    detail: str
    expected: tuple[str, ...] = ()
    observed: str = ""
    contract_code: str = ""
    policy: str = ""
    abstain_expected: bool = False
    extra: dict[str, Any] = field(default_factory=dict)

    def as_dict(self) -> dict[str, Any]:
        out: dict[str, Any] = {
            "case": self.case_id,
            "workload": self.workload,
            "outcome": self.outcome,
            "code": self.code,
            "detail": self.detail,
            "expected": list(self.expected),
            "observed": self.observed,
            "abstain_expected": self.abstain_expected,
        }
        if self.contract_code:
            out["contract_code"] = self.contract_code
            out["policy"] = self.policy
        out.update(self.extra)
        return out


def content_of(response: Any) -> str | None:
    """Return the assistant text of an OpenAI-style response, or of a raw string.

    A plain string is accepted so responses saved by an older caller (or pasted by
    hand) can still be scored; anything else with no readable text returns None,
    which the caller reports as invalid rather than guessing.
    """
    if isinstance(response, str):
        return response
    if isinstance(response, dict):
        choices = response.get("choices")
        if isinstance(choices, list) and choices and isinstance(choices[0], dict):
            message = choices[0].get("message")
            if isinstance(message, dict) and isinstance(message.get("content"), str):
                return message["content"]
    return None


def _normalise(token: str) -> str:
    """Collapse an ANSWER token to a comparable form: no markdown, no trailing stop."""
    cleaned = token.strip().strip("`*_\"'").strip()
    cleaned = cleaned.rstrip(".!;:")
    return re.sub(r"\s+", " ", cleaned).casefold()


def _looks_like_abstention(text: str) -> bool:
    lowered = text.casefold()
    return any(marker in lowered for marker in _ABSTAIN_MARKERS)


def _match_token(observed: str, expect: tuple[str, ...]) -> bool:
    return _normalise(observed) in {_normalise(want) for want in expect}


def _tool_calls_in(text: str) -> list[Any] | None:
    """Return the tool calls in a bare JSON array response, else None."""
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError:
        return None
    if (
        isinstance(parsed, list)
        and parsed
        and all(isinstance(call, dict) and "tool" in call for call in parsed)
    ):
        return parsed
    return None


def _score_tool_call(
    case: Case,
    stripped: str,
    contract_code: str,
    contract_ok: bool,
    policy: str,
) -> CaseResult:
    """Score the FIRST parsed tool call: right tool, right argument value.

    A wrong tool or a wrong argument is `incorrect` (a well-formed call that is
    wrong), not `invalid`: the shape was met.  That distinction is the whole point
    of scoring this workload on its real contract rather than on a text token.
    """

    def result(outcome: str, code: str, detail: str, observed: str = "") -> CaseResult:
        return CaseResult(
            case_id=case.id,
            workload=case.workload,
            outcome=outcome,
            code=code,
            detail=detail,
            expected=case.expect,
            observed=observed,
            contract_code=contract_code,
            policy=policy,
            abstain_expected=case.abstain,
        )

    if not contract_ok:
        return result(
            OUTCOME_INVALID,
            contract_code,
            "response failed the agentic tool-call contract",
            stripped[:120],
        )
    try:
        calls = json.loads(stripped)
    except json.JSONDecodeError as exc:
        return result(OUTCOME_INVALID, CODE_RAW_SYNTAX, f"not JSON: {exc.msg}", stripped[:120])
    if not isinstance(calls, list) or not calls or not isinstance(calls[0], dict):
        return result(OUTCOME_INVALID, CODE_WRONG_SHAPE, "no first tool call", stripped[:120])
    call = calls[0]
    tool = call.get("tool")
    if tool != case.tool:
        return result(
            OUTCOME_INCORRECT,
            CODE_WRONG_TOOL,
            f"chose {tool!r}; the case needs {case.tool!r}",
            str(tool),
        )
    arguments = call.get("arguments")
    if not isinstance(arguments, dict):
        return result(OUTCOME_INVALID, CODE_BAD_ARGUMENTS, "arguments is not an object", "")
    value = arguments.get(case.argument_name)
    if not isinstance(value, str) or not value.strip():
        return result(
            OUTCOME_INCORRECT,
            CODE_WRONG_ARGUMENT,
            f"{case.tool} was called without a usable {case.argument_name}",
            "",
        )
    observed = value.strip()
    if case.argument_mode == "equals":
        matched = observed.casefold() == case.argument_expect.casefold()
    else:
        matched = case.argument_expect.casefold() in observed.casefold()
    if not matched:
        return result(
            OUTCOME_INCORRECT,
            CODE_WRONG_ARGUMENT,
            f"{case.argument_name}={observed!r} does not match {case.argument_expect!r}",
            observed,
        )
    return result(OUTCOME_CORRECT, CODE_OK, "expected tool call", observed)


def score_response(case: Case, response: Any) -> CaseResult:
    """Score one response against one case. Pure: no I/O, no clock, no judge."""
    text = content_of(response)
    contract_code = ""
    contract_ok = True
    policy = ""
    if isinstance(response, dict) and case.workload in CONTRACT_WORKLOADS:
        verdict = check_response(case.workload, response)
        contract_code = verdict.code
        policy = verdict.policy
        contract_ok = verdict.ok

    if text is None:
        return CaseResult(
            case_id=case.id,
            workload=case.workload,
            outcome=OUTCOME_INVALID,
            code="response-not-readable",
            detail="response carried no assistant content",
            expected=case.expect,
            abstain_expected=case.abstain,
        )

    stripped = text.strip()
    if not stripped:
        return CaseResult(
            case_id=case.id,
            workload=case.workload,
            outcome=OUTCOME_INVALID,
            code=CODE_EMPTY,
            detail="assistant text is empty",
            expected=case.expect,
            contract_code=contract_code,
            policy=policy,
            abstain_expected=case.abstain,
        )

    if case.kind == "tool_call":
        return _score_tool_call(case, stripped, contract_code, contract_ok, policy)

    match = _ANSWER_LINE.search(stripped)
    if match is None:
        emitted = _tool_calls_in(stripped)
        if emitted is not None and case.expect and _normalise(case.expect[0]) in {"no_tool", "no tool"}:
            # The off-menu case answered with a tool call: it has the interface and
            # not the choice, which is a WRONG ANSWER, not an unreadable one.
            return CaseResult(
                case_id=case.id,
                workload=case.workload,
                outcome=OUTCOME_INCORRECT,
                code=CODE_WRONG_TOOL,
                detail="emitted a tool call where the case needs no tool",
                expected=case.expect,
                observed=stripped[:120],
                contract_code=contract_code,
                policy=policy,
                abstain_expected=case.abstain,
            )
        if _looks_like_abstention(stripped):
            outcome = OUTCOME_ABSTAIN
            detail = "declined without an ANSWER marker"
            code = "abstain-lexical"
        else:
            outcome = OUTCOME_INVALID
            detail = "no ANSWER: line, so the response cannot be scored"
            code = CODE_NO_ANSWER_MARKER
        return CaseResult(
            case_id=case.id,
            workload=case.workload,
            outcome=outcome,
            code=code,
            detail=detail,
            expected=case.expect,
            observed=stripped[:120],
            contract_code=contract_code,
            policy=policy,
            abstain_expected=case.abstain,
        )

    observed = match.group("token")
    if not contract_ok:
        # A shape failure is reported as invalid with the CONTRACT's own code, so
        # the format dimension stays countable here instead of being re-invented.
        return CaseResult(
            case_id=case.id,
            workload=case.workload,
            outcome=OUTCOME_INVALID,
            code=contract_code,
            detail="response failed the workload's format contract",
            expected=case.expect,
            observed=observed,
            contract_code=contract_code,
            policy=policy,
            abstain_expected=case.abstain,
        )

    if _normalise(observed) in {"abstain", "unverified"} and case.abstain:
        return CaseResult(
            case_id=case.id,
            workload=case.workload,
            outcome=OUTCOME_CORRECT,
            code=CODE_OK,
            detail="abstained where the evidence did not support an answer",
            expected=case.expect,
            observed=observed,
            contract_code=contract_code,
            policy=policy,
            abstain_expected=True,
        )

    if _match_token(observed, case.expect):
        return CaseResult(
            case_id=case.id,
            workload=case.workload,
            outcome=OUTCOME_CORRECT,
            code=CODE_OK,
            detail="expected answer",
            expected=case.expect,
            observed=observed,
            contract_code=contract_code,
            policy=policy,
            abstain_expected=case.abstain,
        )

    if _looks_like_abstention(observed) or _normalise(observed) in {"abstain", "unverified"}:
        return CaseResult(
            case_id=case.id,
            workload=case.workload,
            outcome=OUTCOME_ABSTAIN,
            code="abstain",
            detail="declined a question that has a defensible answer",
            expected=case.expect,
            observed=observed,
            contract_code=contract_code,
            policy=policy,
            abstain_expected=case.abstain,
        )

    return CaseResult(
        case_id=case.id,
        workload=case.workload,
        outcome=OUTCOME_INCORRECT,
        code="wrong-answer",
        detail="well-formed answer that does not match the expected token",
        expected=case.expect,
        observed=observed,
        contract_code=contract_code,
        policy=policy,
        abstain_expected=case.abstain,
    )


def summarise(results: list[CaseResult]) -> dict[str, Any]:
    """Aggregate results into per-outcome and per-workload counts.

    `correct / cases` is reported as `accuracy` and never as a percentage of
    `correct + incorrect` alone: dropping invalid and abstain would flatter the
    figure, which is exactly the aggregation error this tool exists to avoid.
    """
    counts = {outcome: 0 for outcome in OUTCOMES}
    code_counts: dict[str, int] = {}
    by_workload: dict[str, dict[str, Any]] = {}
    for result in results:
        counts[result.outcome] = counts.get(result.outcome, 0) + 1
        if result.outcome != OUTCOME_CORRECT:
            code_counts[result.code] = code_counts.get(result.code, 0) + 1
        bucket = by_workload.setdefault(
            result.workload, {"cases": 0, **{outcome: 0 for outcome in OUTCOMES}}
        )
        bucket["cases"] += 1
        bucket[result.outcome] += 1
    total = len(results)
    return {
        "cases": total,
        "counts": counts,
        "code_counts": dict(sorted(code_counts.items())),
        "by_workload": by_workload,
        "accuracy": (counts[OUTCOME_CORRECT] / total) if total else None,
        "abstained": counts[OUTCOME_ABSTAIN],
    }


def _response_from_stdin(raw: str) -> Any:
    """Parse one recorded response: JSON if it parses, else the text itself."""
    text = raw.strip()
    if not text:
        return ""
    if text[0] in "{[":
        try:
            return json.loads(text)
        except json.JSONDecodeError:
            return raw
    return raw


def _load_response_log(path: str) -> list[tuple[str, Any]]:
    """Read a JSONL log of `{"case": <id>, "response": <obj|text>}` records."""
    records: list[tuple[str, Any]] = []
    with open(path, encoding="utf-8") as handle:
        for lineno, line in enumerate(handle, start=1):
            if not line.strip():
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError as exc:
                raise SystemExit(f"{path}:{lineno}: invalid JSON: {exc.msg}") from exc
            if not isinstance(record, dict) or "case" not in record:
                raise SystemExit(f"{path}:{lineno}: record must carry a 'case' id")
            records.append((str(record["case"]), record.get("response", "")))
    return records


def _post_chat(base_url: str, model: str, prompt: str, timeout: float) -> Any:
    """Ask a running llama-server one question at temperature 0.

    Loopback only: a correctness probe sends the case prompts, and those must not
    travel to a remote host from a tool that was asked to measure a local model.
    """
    host = urllib.parse.urlsplit(base_url).hostname or ""
    if host not in {"127.0.0.1", "localhost", "::1"}:
        raise SystemExit(
            f"refusing to send case prompts to a non-loopback URL: {base_url}"
        )
    body = json.dumps(
        {
            "model": model,
            "messages": [{"role": "user", "content": prompt}],
            "temperature": 0,
            "max_tokens": 256,
            "stream": False,
        }
    ).encode()
    request = urllib.request.Request(
        f"{base_url.rstrip('/')}/chat/completions",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode())


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cases", action="store_true", help="list the held-out cases")
    parser.add_argument(
        "--responses",
        metavar="PATH",
        help='score recorded responses from a JSONL log of {"case": id, "response": ...}',
    )
    parser.add_argument(
        "--run",
        action="store_true",
        help="ask a running llama-server every case instead of scoring a log",
    )
    parser.add_argument(
        "--base-url",
        default=os.environ.get("LLM_SERVER_BASE_URL", "http://127.0.0.1:18081/v1"),
        help="loopback base URL for --run",
    )
    parser.add_argument(
        "--model",
        default=os.environ.get("LLM_OUTCOME_MODEL", "local"),
        help="model name to request in --run mode",
    )
    parser.add_argument("--timeout", type=float, default=120.0, help="per-request timeout for --run")
    parser.add_argument("--json", action="store_true", help="emit the scored result as JSON")
    parser.add_argument(
        "--write",
        metavar="PATH",
        help="also write the JSON artefact here (for tools/llm_selection_report.py)",
    )
    parser.add_argument(
        "--workload",
        choices=sorted({case.workload for case in CASES}),
        help="restrict scoring to one workload",
    )
    args = parser.parse_args()

    selected = [case for case in CASES if not args.workload or case.workload == args.workload]

    if args.cases:
        for case in selected:
            print(f"{case.id:<24} {case.workload:<8} expect={'|'.join(case.expect)}")
            print(f"  {case.prompt}")
            if case.note:
                print(f"  note: {case.note}")
        print(f"\n{len(selected)} case(s); {len({c.workload for c in selected})} workload(s).")
        return 0

    if bool(args.run) == bool(args.responses):
        parser.error("choose exactly one of --run or --responses")
    if args.run and not args.workload:
        print(
            "note: --run scores every workload; pass --workload to ask fewer questions",
            file=sys.stderr,
        )

    results: list[CaseResult] = []
    if args.responses:
        for case_id, response in _load_response_log(args.responses):
            resolved = _CASES_BY_ID.get(case_id)
            if resolved is None:
                raise SystemExit(f"unknown case id in {args.responses}: {case_id}")
            if args.workload and resolved.workload != args.workload:
                continue
            results.append(score_response(resolved, response))
    else:
        for case in selected:
            try:
                response = _post_chat(args.base_url, args.model, case.prompt, args.timeout)
            except (urllib.error.URLError, TimeoutError, OSError) as exc:
                results.append(
                    CaseResult(
                        case_id=case.id,
                        workload=case.workload,
                        outcome=OUTCOME_INVALID,
                        code="no-response",
                        detail=f"request failed: {exc}",
                        expected=case.expect,
                        abstain_expected=case.abstain,
                    )
                )
                continue
            results.append(score_response(case, response))

    summary = summarise(results)
    artefact = {
        "tool": "llm_outcome_cases",
        "model": args.model if args.run else os.environ.get("LLM_OUTCOME_MODEL", ""),
        "base_url": args.base_url if args.run else "",
        "cases_file": args.responses or "",
        "summary": summary,
        "results": [result.as_dict() for result in results],
        "limits": [
            "12 held-out cases; smoke-sized correctness signal, not a benchmark",
            "abstention detection is lexical (short marker list), not a judge",
            "no factual or legal-correctness claim beyond these closed questions",
        ],
    }

    if args.write:
        directory = os.path.dirname(os.path.abspath(args.write))
        if directory:
            os.makedirs(directory, exist_ok=True)
        with open(args.write, "w", encoding="utf-8") as handle:
            json.dump(artefact, handle, indent=2, sort_keys=False)
            handle.write("\n")

    if args.json:
        print(json.dumps(artefact))
    else:
        counts = summary["counts"]
        accuracy = summary["accuracy"]
        head = (
            f"outcome cases: {summary['cases']} scored — "
            f"correct={counts[OUTCOME_CORRECT]} incorrect={counts[OUTCOME_INCORRECT]} "
            f"abstain={counts[OUTCOME_ABSTAIN]} invalid={counts[OUTCOME_INVALID]}"
        )
        print(head)
        if accuracy is not None:
            print(f"accuracy over ALL cases: {accuracy:.1%} (invalid and abstain count against it)")
        for workload, bucket in sorted(summary["by_workload"].items()):
            print(
                f"  {workload:<8} cases={bucket['cases']} correct={bucket[OUTCOME_CORRECT]} "
                f"incorrect={bucket[OUTCOME_INCORRECT]} abstain={bucket[OUTCOME_ABSTAIN]} "
                f"invalid={bucket[OUTCOME_INVALID]}"
            )
        if summary["code_counts"]:
            breakdown = ", ".join(
                f"{code}={count}" for code, count in summary["code_counts"].items()
            )
            print(f"  non-correct codes: {breakdown}")
        for result in results:
            if result.outcome != OUTCOME_CORRECT:
                print(f"    {result.case_id}: [{result.outcome}/{result.code}] {result.detail}")
        if args.write:
            print(f"artefact written: {args.write}")

    return 0 if summary["counts"][OUTCOME_CORRECT] == summary["cases"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
