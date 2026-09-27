#!/usr/bin/env python3
"""Long-context retrieval fidelity as a function of KV-cache quantization.

WHY THIS EXISTS (card KVCACHE-QUANT-VALIDATE-001).  Our workload is legal-evidence RAG
assessed with a verdict contract, so a long-context retrieval failure is a WRONG VERDICT,
not a slower reply.  We ship q8_0 for both K and V on every lane
(``LLAMA_CACHE_TYPE_K``/``_V`` in ``scripts/01-constants.sh``), and q4_0 is reachable
through ``LLM_AUTOTUNE_KV_QUANTS`` (``env.sh``) where the autotune sweep selects on
throughput and fit — never on retrieval quality.  Nothing measures retrieval fidelity as a
function of cache precision, and the audit doc is explicit that quantization loss is NOT
uniform: vLLM's FP8 measurement collapsed a needle-in-a-haystack score from 91% to 13%.
That figure is FP8 on vLLM and must NOT be generalised to q8_0 on llama.cpp — the only
way to know OUR number is to measure OUR workload.

WHAT IT MEASURES.  A needle (a unique fact) is planted at several DEPTHS in a long
context, the server is asked for it, and recall is scored **per depth**, never only as an
aggregate — the cliff the article warns about is precisely what an average hides.

WHAT IT DOES NOT DO.  It does not set the KV type.  The server is already running with
whatever ``--cache-type-k``/``-v`` it was started with, so ``--kv-type`` is a LABEL the
probe records alongside the result: it refuses to run without one, because a measurement
whose precision is unknown is not a measurement.

RUNNING IT:
    # one lane, both precisions, recorded then compared (a lane restart between them)
    .venv/bin/python3 scripts/kv-recall-probe.py --base-url http://127.0.0.1:18083 \\
        --kv-type q8_0 --model llama32-3b --record config/kv-recall-baseline.tsv
    .venv/bin/python3 scripts/kv-recall-probe.py --base-url http://127.0.0.1:18083 \\
        --kv-type q4_0 --model llama32-3b --check  config/kv-recall-baseline.tsv

    # no server needed: build the prompt and report the plan
    .venv/bin/python3 scripts/kv-recall-probe.py --dry-run

EXIT: 0 measured or check passed, 2 usage/--dry-run, 3 the server did not answer,
      4 a --check found a regression.

REF: "The KV Cache Tax: Why Inference Servers Run Out of Memory Before Compute"
     (Ibrahim, TDS, 2026-09-16)
     https://towardsdatascience.com/the-kv-cache-tax-why-inference-servers-run-out-of-memory-before-compute/
"""

from __future__ import annotations

import argparse
import json
import logging
import random
import re
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any

logger = logging.getLogger("kv-recall-probe")

# Bumping this invalidates nothing, but it IS recorded: a baseline measured by an older
# probe is not comparable to a newer one, and the version is what makes that visible.
PROBE_VERSION = 1

DEFAULT_DEPTHS = (0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9)
BASELINE_DEFAULT = Path("config/kv-recall-baseline.tsv")
BASELINE_HEADER = "#model\tkv_type\tdepth\tctx_tokens\trecall\ttrials\tprobe_version"

# The needle and the questions asked about it.  Deliberately a FACT with an exact answer,
# so scoring is exact rather than a judgement call: the question is "did the long-context
# read survive", not "was the answer good".
NEEDLE_TEMPLATE = (
    "Note for the case file: the maintenance access code for {tag} is {code}."
)
QUESTION = (
    "Using only the document above, what is the maintenance access code for {tag}? "
    "Reply with the code alone on the last line."
)

# Filler sentences.  They exist to occupy context, and they are deliberately about the
# SAME domain as the needle so a model cannot score by noticing that the one relevant
# sentence is the only non-templated one.
FILLERS = (
    "The parties filed their statements of case and the tribunal acknowledged receipt.",
    "Schedules of loss were exchanged and the respondent reserved its position on quantum.",
    "The witness list was revised after the second case management conference.",
    "Correspondence between the representatives continued over the following weeks.",
    "The bundle index was updated to reflect the additional documents.",
)


@dataclass(frozen=True)
class ProbePlan:
    """One (model, kv_type) measurement: the depths to test at, and the context size."""

    model: str
    kv_type: str
    ctx_tokens: int
    depths: tuple[float, ...]
    seed: int


@dataclass
class DepthResult:
    """What one depth produced.  ``prompt_tokens`` is the server's own count when it
    reported one, else None — never a guess dressed as a measurement."""

    depth: float
    hit: bool
    prompt_tokens: int | None
    answer: str


def validate_depths(depths: tuple[float, ...]) -> tuple[float, ...]:
    """Depths are positions inside the context: (0, 1) exclusive, and non-empty."""
    if not depths:
        raise ValueError("at least one depth is required")
    for d in depths:
        if not 0.0 < d < 1.0:
            raise ValueError(f"depth {d} is outside (0, 1) — it is a position, not a count")
    return depths


def build_haystack(
    plan: ProbePlan, depth: float, needle: str
) -> tuple[str, int]:
    """Plant ``needle`` at ``depth`` of a context of about ``plan.ctx_tokens``.

    Returns the document and the needle's 1-based position among its lines, so a test can
    assert placement without re-deriving it.  The size is built in WORDS: the probe's
    own estimate is returned for display, and the server's reported prompt_tokens is what
    the record carries — see DepthResult.prompt_tokens.
    """
    rng = random.Random((plan.seed, depth, plan.model, plan.kv_type).__hash__())
    # ~1.3 words per token for this kind of prose; the estimate is labelled as such.
    target_words = max(64, int(plan.ctx_tokens / 1.3))
    lines: list[str] = []
    needle_at = max(1, int(round(target_words * depth)))
    while len(lines) < target_words:
        if len(lines) + 1 == needle_at:
            lines.append(needle)
            continue
        lines.append(rng.choice(FILLERS))
    if needle not in lines:
        lines.insert(min(needle_at, len(lines)) - 1, needle)
    return "\n".join(lines), lines.index(needle) + 1


def extract_answer(text: str) -> str:
    """The code from the reply: the last non-empty line, stripped of punctuation.

    The models are told to put the code alone on the last line; taking the LAST line
    means a model that reasons first and answers last still scores, and one that never
    answers does not score by accident.
    """
    for line in reversed(text.splitlines()):
        cleaned = line.strip().strip(".,;:!\"'`*_ ")
        if cleaned:
            return cleaned
    return ""


def score_answer(answer: str, code: str) -> bool:
    """A HIT when the code is a whole token of the reply's LAST non-empty line.

    Why not strict equality: the code is not guessable, so a reply that contains it
    retrieved it — scoring "The code is 7394." as a miss would UNDER-report recall and
    make a healthy precision look dangerous. Why the last line and not the whole reply: a
    model that reasons, names the code, and then hedges has not committed to an answer,
    and scoring that as a hit would OVER-report recall, which is the direction that could
    hide a real cliff. Whole-token, so a longer number containing the code cannot score.
    """
    last = extract_answer(answer).lower()
    tokens = [t for t in re.split(r"[^a-z0-9]+", last) if t]
    return code.strip().lower() in tokens


def ask_server(base_url: str, prompt: str, timeout: float) -> tuple[str, int | None]:
    """One chat completion.  Returns (text, prompt_tokens) — the token count is the
    server's, and None when it did not report one."""
    url = base_url.rstrip("/") + "/v1/chat/completions"
    body = json.dumps(
        {
            "messages": [{"role": "user", "content": prompt}],
            "temperature": 0.0,
            "max_tokens": 64,
        }
    ).encode()
    req = urllib.request.Request(
        url, data=body, headers={"Content-Type": "application/json"}, method="POST"
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310 - operator-supplied loopback URL
        data = json.loads(resp.read().decode())
    text = data["choices"][0]["message"]["content"]
    usage = data.get("usage") or {}
    prompt_tokens = usage.get("prompt_tokens")
    return text, (int(prompt_tokens) if isinstance(prompt_tokens, int) else None)


def run_plan(plan: ProbePlan, base_url: str, code: str, timeout: float) -> list[DepthResult]:
    """Query every depth in the plan, in order, against a server already running at
    ``plan.kv_type``."""
    results: list[DepthResult] = []
    for depth in plan.depths:
        needle = NEEDLE_TEMPLATE.format(tag="the A-17 bundle", code=code)
        document, position = build_haystack(plan, depth, needle)
        prompt = f"{document}\n\n{QUESTION.format(tag='the A-17 bundle')}"
        logger.debug(
            "depth %.2f -> needle at line %d of %d", depth, position, document.count("\n") + 1
        )
        text, prompt_tokens = ask_server(base_url, prompt, timeout)
        results.append(
            DepthResult(
                depth=depth,
                hit=score_answer(text, code),
                prompt_tokens=prompt_tokens,
                answer=extract_answer(text),
            )
        )
    return results


def recall_by_depth(results: list[DepthResult]) -> list[tuple[float, bool, int | None]]:
    return [(r.depth, r.hit, r.prompt_tokens) for r in results]


def summarise(results: list[DepthResult]) -> dict[str, float | int]:
    """Per-depth results plus an aggregate that is REPORTED AS A TRAP.

    The card's whole point is that the cliff hides in the average, so the aggregate is
    labelled ``aggregate_hides_the_cliff`` rather than presented as the result.
    """
    hits = sum(1 for r in results if r.hit)
    return {
        "depths": len(results),
        "hits": hits,
        "aggregate_hides_the_cliff": round(hits / len(results), 4) if results else 0.0,
    }


def _row(plan: ProbePlan, result: DepthResult) -> str:
    return "\t".join(
        [
            plan.model,
            plan.kv_type,
            f"{result.depth:.2f}",
            str(result.prompt_tokens if result.prompt_tokens is not None else plan.ctx_tokens),
            "1" if result.hit else "0",
            "1",
            str(PROBE_VERSION),
        ]
    )


def load_baseline(path: Path) -> dict[tuple[str, str, str], str]:
    """(model, kv_type, depth) -> recall, from the recorded TSV."""
    recorded: dict[tuple[str, str, str], str] = {}
    if not path.exists():
        return recorded
    for line in path.read_text().splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) < 5:
            continue
        recorded[(parts[0], parts[1], parts[2])] = parts[4]
    return recorded


def record_baseline(path: Path, plan: ProbePlan, results: list[DepthResult]) -> None:
    """Merge this run's rows into the TSV, replacing same-key rows from the same probe
    version and appending a new header when the file does not exist yet."""
    existing: dict[tuple[str, str, str], str] = {}
    if path.exists():
        for line in path.read_text().splitlines():
            if not line.strip() or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) >= 3:
                existing[(parts[0], parts[1], parts[2])] = line
    for result in results:
        key = (plan.model, plan.kv_type, f"{result.depth:.2f}")
        existing[key] = _row(plan, result)
    path.parent.mkdir(parents=True, exist_ok=True)
    body = [BASELINE_HEADER] + [existing[k] for k in sorted(existing)]
    path.write_text("\n".join(body) + "\n")


def check_baseline(
    path: Path, plan: ProbePlan, results: list[DepthResult], tolerance: float
) -> list[str]:
    """Compare this run against the record for the same (model, kv_type, depth).

    A depth with no recorded row is reported as unrecorded and never as a pass: silence
    is not evidence.  Returns the failures, so the caller decides the exit code.
    """
    recorded = load_baseline(path)
    failures: list[str] = []
    for result in results:
        key = (plan.model, plan.kv_type, f"{result.depth:.2f}")
        if key not in recorded:
            failures.append(
                f"{plan.model}/{plan.kv_type} depth {result.depth:.2f}: no recorded recall"
                " — unrecorded is not passing"
            )
            continue
        want = float(recorded[key])
        got = 1.0 if result.hit else 0.0
        if got < want - tolerance:
            failures.append(
                f"{plan.model}/{plan.kv_type} depth {result.depth:.2f}: recall {got:.2f}"
                f" < recorded {want:.2f} (tolerance {tolerance:.2f})"
            )
    return failures


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    # An explicit description rather than __doc__: __doc__ is Optional[str], so a module
    # that ever lost its docstring would crash here rather than print help.
    parser = argparse.ArgumentParser(
        description="Measure long-context retrieval recall per KV-cache precision"
    )
    parser.add_argument("--base-url", default="http://127.0.0.1:18083",
                        help="a llama.cpp server ALREADY running at --kv-type")
    parser.add_argument("--model", default="", help="label for the record (required to record)")
    parser.add_argument("--kv-type", default="",
                        help="the server's --cache-type-k/v, e.g. q8_0 or q4_0 (required to run)")
    parser.add_argument("--ctx-tokens", type=int, default=4096,
                        help="target context size (words are estimated; the record carries"
                             " the server's own prompt_tokens when it reports one)")
    parser.add_argument("--depths", default=",".join(f"{d}" for d in DEFAULT_DEPTHS),
                        help="comma-separated positions in (0,1)")
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--code", default="7394", help="the needle's exact answer")
    parser.add_argument("--timeout", type=float, default=120.0)
    parser.add_argument("--record", type=Path, default=None,
                        help="merge this run into a baseline TSV")
    parser.add_argument("--check", type=Path, default=None,
                        help="fail when any depth's recall is below the recorded one")
    parser.add_argument("--tolerance", type=float, default=0.0,
                        help="allowed drop against the recorded recall (default: none)")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--dry-run", action="store_true",
                        help="build the prompt and report the plan; never contact a server")
    args = parser.parse_args(argv)
    args.depths = tuple(float(d) for d in str(args.depths).split(",") if d.strip())
    return args


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        depths = validate_depths(args.depths)
    except ValueError as exc:
        print(f"kv-recall-probe: {exc}", file=sys.stderr)
        return 2

    if not args.dry_run and not args.kv_type:
        print(
            "kv-recall-probe: --kv-type is required when measuring — it is the label of"
            " the precision the SERVER is running, and a result without it is unusable",
            file=sys.stderr,
        )
        return 2
    if (args.record or args.check) and not args.model:
        print("kv-recall-probe: --model is required to record or check a baseline",
              file=sys.stderr)
        return 2

    plan = ProbePlan(
        model=args.model or "unlabelled",
        kv_type=args.kv_type or "unlabelled",
        ctx_tokens=args.ctx_tokens,
        depths=depths,
        seed=args.seed,
    )

    if args.dry_run:
        needle = NEEDLE_TEMPLATE.format(tag="the A-17 bundle", code=args.code)
        document, position = build_haystack(plan, depths[0], needle)
        print(f"plan: model={plan.model} kv_type={plan.kv_type} ctx~{plan.ctx_tokens} tokens"
              f" depths={list(depths)}")
        print(f"needle at line {position} of {document.count(chr(10)) + 1}"
              f" (first depth {depths[0]:.2f})")
        print(f"estimated prompt words: {len(document.split())} (server count is what"
              " the record carries)")
        return 2

    code = args.code
    try:
        results = run_plan(plan, args.base_url, code, args.timeout)
    except (urllib.error.URLError, TimeoutError, OSError, KeyError, json.JSONDecodeError) as exc:
        print(f"kv-recall-probe: the server did not answer usefully: {exc}", file=sys.stderr)
        return 3

    report: dict[str, Any] = {
        "probe_version": PROBE_VERSION,
        "plan": {
            "model": plan.model,
            "kv_type": plan.kv_type,
            "ctx_tokens": plan.ctx_tokens,
            "depths": list(plan.depths),
            "seed": plan.seed,
        },
        "per_depth": [
            {"depth": r.depth, "hit": r.hit, "prompt_tokens": r.prompt_tokens,
             "answer": r.answer}
            for r in results
        ],
        **summarise(results),
    }

    failures: list[str] = []
    if args.check:
        failures = check_baseline(args.check, plan, results, args.tolerance)
    if args.record:
        record_baseline(args.record, plan, results)
        report["recorded"] = str(args.record)

    if args.json:
        report["failures"] = failures
        print(json.dumps(report, indent=2))
    else:
        print(f"KV recall — model={plan.model} kv_type={plan.kv_type}"
              f" ctx~{plan.ctx_tokens}")
        for r in results:
            print(f"  depth {r.depth:.2f}  {'HIT ' if r.hit else 'MISS'}"
                  f"  prompt_tokens={r.prompt_tokens if r.prompt_tokens is not None else '?'}")
        print(f"  {summarise(results)['hits']}/{len(results)} depths recalled"
              "  (the aggregate is NOT the result — the cliff hides in the average)")
        for failure in failures:
            print(f"  REGRESSION: {failure}", file=sys.stderr)

    if failures:
        print("kv-recall-probe: a recorded recall was not reproduced", file=sys.stderr)
        return 4
    return 0


if __name__ == "__main__":
    sys.exit(main())
