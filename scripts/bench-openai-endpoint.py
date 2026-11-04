#!/usr/bin/env python3
"""Bench an OpenAI-compatible chat endpoint: single-stream decode and concurrency.

Written for a cross-backend A/B (llama.cpp in WSL vs vLLM on Windows) where the
two servers share only one thing: the HTTP contract. So every number here is
derived from the response alone -- usage.completion_tokens and wall clock -- and
nothing is read out of a server log. A metric that needs a backend-specific log
is not a metric you can compare across backends.

What it reports:
  single     N repetitions of one fixed prompt, one request in flight; per-run
             tokens/s, median, min, max.
  concurrent C streams in flight for W rounds; aggregate tokens/s, per-request
             median and p90 latency.

The prompt text, max_tokens, temperature and seed are identical across backends,
because a harness that varies them is measuring itself.

Usage:
  bench-openai-endpoint.py --base-url http://127.0.0.1:8000/v1 --label vllm
  bench-openai-endpoint.py --base-url ... --only single --runs 5
  bench-openai-endpoint.py --base-url ... --concurrency 1,2,4,8,16 --json out.json

Exit: 0 measured; 1 the endpoint could not be used; 2 usage error.
"""
from __future__ import annotations

import argparse
import json
import statistics
import sys
import time
import urllib.error
import urllib.request
from datetime import UTC, datetime
from typing import Any

UA = "bench-openai-endpoint/1"

# One coding prompt and one prose prompt, deliberately short in prompt tokens so
# the measurement is dominated by DECODE, which is what this box is bound on.
# Both are fixed strings: any variation between backends invalidates the run.
PROMPTS = {
    "code": (
        "Write a Python function that merges two sorted lists into one sorted "
        "list without using sorted() or .sort(). Then explain the time "
        "complexity in two sentences."
    ),
    "prose": (
        "Explain why memory bandwidth, rather than raw compute, limits token "
        "generation speed for large language models on consumer hardware. "
        "Be specific about the arithmetic of reading weights."
    ),
}


def now() -> str:
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def post_json(url: str, body: dict, timeout: float) -> dict[str, Any]:
    data = json.dumps(body).encode()
    req = urllib.request.Request(
        url, data=data, headers={"Content-Type": "application/json", "User-Agent": UA}
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8", "replace"))


def get_json(url: str, timeout: float = 20) -> dict[str, Any]:
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8", "replace"))


def resolve_model(base_url: str, explicit: str | None) -> str:
    if explicit:
        return explicit
    try:
        data = get_json(base_url.rstrip("/") + "/models")
    except (urllib.error.URLError, TimeoutError, ValueError) as exc:
        raise SystemExit(f"cannot read {base_url}/models: {exc}") from exc
    items = data.get("data") or []
    if not items:
        raise SystemExit(f"{base_url}/models returned no models; pass --model")
    return items[0]["id"]


def one_request(base_url, model, prompt, max_tokens, temperature, seed, timeout):
    """Return (completion_tokens, prompt_tokens, seconds). Raises on failure."""
    body = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": temperature,
        "seed": seed,
        "stream": False,
    }
    started = time.perf_counter()
    payload = post_json(base_url.rstrip("/") + "/chat/completions", body, timeout)
    elapsed = time.perf_counter() - started
    usage = payload.get("usage") or {}
    ct = usage.get("completion_tokens")
    if not isinstance(ct, int) or ct <= 0:
        raise RuntimeError(f"no numeric completion_tokens (usage={usage!r})")
    return ct, usage.get("prompt_tokens"), elapsed


def bench_single(args, model):
    prompt = PROMPTS[args.prompt]
    runs = []
    total = args.runs + args.warmup
    for i in range(total):
        ct, pt, secs = one_request(
            args.base_url, model, prompt, args.max_tokens,
            args.temperature, args.seed, args.timeout,
        )
        tps = ct / secs
        runs.append({"run": i + 1, "tokens": ct, "prompt_tokens": pt,
                     "seconds": round(secs, 3), "tps": round(tps, 2)})
        tag = "warmup (discarded)" if i < args.warmup else "measured"
        print(f"  single {i + 1:>2}/{total}  {tag:<18} "
              f"{secs:6.2f}s  {ct:>4} tok  {tps:6.2f} tok/s", flush=True)
    measured = [r["tps"] for r in runs[args.warmup:]]
    return {
        "prompt": args.prompt,
        "runs": runs,
        "measured_count": len(measured),
        "median_tps": round(statistics.median(measured), 2),
        "min_tps": round(min(measured), 2),
        "max_tps": round(max(measured), 2),
    }


def bench_concurrent(args, model, concurrency: int):
    """W rounds of concurrent simultaneous requests; aggregate throughput."""
    import threading

    prompt = PROMPTS[args.prompt]
    rounds = args.rounds
    results: list[dict] = []
    lock = threading.Lock()

    def worker(idx: int) -> None:
        try:
            ct, _pt, secs = one_request(
                args.base_url, model, prompt, args.max_tokens,
                args.temperature, args.seed, args.timeout,
            )
            with lock:
                results.append({"i": idx, "tokens": ct, "seconds": secs, "ok": True})
        except Exception as exc:  # a failed request is a finding, not a zero
            with lock:
                results.append({"i": idx, "ok": False, "error": str(exc)[:200]})

    per_round = []
    for r in range(rounds):
        results.clear()
        threads = [threading.Thread(target=worker, args=(i,)) for i in range(concurrency)]
        started = time.perf_counter()
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        wall = time.perf_counter() - started
        ok = [x for x in results if x["ok"]]
        tokens = sum(x["tokens"] for x in ok)
        agg = tokens / wall if wall > 0 else 0.0
        lats = sorted(x["seconds"] for x in ok)
        p90 = lats[int(len(lats) * 0.9) - 1] if lats else None
        per_round.append({
            "round": r + 1, "wall_s": round(wall, 3), "completed": len(ok),
            "failed": len(results) - len(ok), "total_tokens": tokens,
            "aggregate_tps": round(agg, 2),
            "median_latency_s": round(statistics.median(lats), 3) if lats else None,
            "p90_latency_s": round(p90, 3) if p90 is not None else None,
        })
        print(f"  conc {concurrency:>2}  round {r + 1}/{rounds}  wall {wall:6.2f}s  "
              f"{tokens:>6} tok  {agg:7.2f} tok/s aggregate  "
              f"{len(ok)}/{concurrency} ok", flush=True)
    aggs = [x["aggregate_tps"] for x in per_round]
    return {
        "concurrency": concurrency,
        "rounds": per_round,
        "median_aggregate_tps": round(statistics.median(aggs), 2),
        "max_aggregate_tps": round(max(aggs), 2),
        "total_failed": sum(x["failed"] for x in per_round),
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-url", required=True, help="e.g. http://127.0.0.1:8000/v1")
    ap.add_argument("--model", default=None, help="default: first id from /v1/models")
    ap.add_argument("--label", default="endpoint")
    ap.add_argument("--prompt", choices=sorted(PROMPTS), default="code")
    ap.add_argument("--max-tokens", type=int, default=256)
    ap.add_argument("--temperature", type=float, default=0.0)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--warmup", type=int, default=1)
    ap.add_argument("--only", choices=["single", "concurrent", "both"], default="both")
    ap.add_argument("--concurrency", default="1,2,4,8,16")
    ap.add_argument("--rounds", type=int, default=2)
    ap.add_argument("--timeout", type=float, default=600)
    ap.add_argument("--json", default=None, help="write the full result as JSON here")
    args = ap.parse_args()

    if args.runs < 1:
        print("--runs must be >= 1", file=sys.stderr)
        return 2

    try:
        model = resolve_model(args.base_url, args.model)
    except SystemExit as exc:
        print(str(exc), file=sys.stderr)
        return 1

    print(f"bench: {args.label}")
    print(f"  endpoint {args.base_url}  model {model}")
    print(f"  prompt={args.prompt} max_tokens={args.max_tokens} "
          f"temperature={args.temperature} seed={args.seed}  as at {now()}")

    result: dict[str, Any] = {
        "label": args.label,
        "base_url": args.base_url,
        "model": model,
        "started_at": now(),
        "settings": {
            "prompt": args.prompt, "max_tokens": args.max_tokens,
            "temperature": args.temperature, "seed": args.seed,
            "runs": args.runs, "warmup": args.warmup, "rounds": args.rounds,
        },
    }

    # A pre-flight request proves the endpoint works before a long sweep starts,
    # and its failure is reported as a failure rather than as zero tokens.
    try:
        ct, pt, secs = one_request(
            args.base_url, model, PROMPTS[args.prompt], 16,
            args.temperature, args.seed, args.timeout,
        )
        print(f"  preflight ok: {ct} tok in {secs:.2f}s (prompt {pt} tok)")
    except Exception as exc:
        print(f"bench: PREFLIGHT FAILED - {type(exc).__name__}: {exc}", file=sys.stderr)
        return 1

    try:
        if args.only in ("single", "both"):
            print()
            print("-- single stream --")
            result["single"] = bench_single(args, model)
        if args.only in ("concurrent", "both"):
            print()
            print("-- concurrency sweep --")
            sweep = []
            for c in [int(x) for x in args.concurrency.split(",") if x.strip()]:
                sweep.append(bench_concurrent(args, model, c))
            result["concurrency"] = sweep
    except Exception as exc:
        print(f"bench: FAILED mid-run - {type(exc).__name__}: {exc}", file=sys.stderr)
        result["error"] = f"{type(exc).__name__}: {exc}"
        result["finished_at"] = now()
        if args.json:
            with open(args.json, "w", encoding="utf-8") as fh:
                json.dump(result, fh, indent=2)
        return 1

    result["finished_at"] = now()

    print()
    print("-- summary --")
    print(f"  {args.label}  ({model})")
    if "single" in result:
        s = result["single"]
        print(f"  single-stream median {s['median_tps']:.2f} tok/s "
              f"(min {s['min_tps']:.2f}, max {s['max_tps']:.2f}, n={s['measured_count']})")
    for row in result.get("concurrency", []):
        print(f"  c={row['concurrency']:<3} median aggregate "
              f"{row['median_aggregate_tps']:.2f} tok/s   "
              f"failed {row['total_failed']}")

    if args.json:
        with open(args.json, "w", encoding="utf-8") as fh:
            json.dump(result, fh, indent=2)
        print(f"  json -> {args.json}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
