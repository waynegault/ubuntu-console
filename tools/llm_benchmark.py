#!/usr/bin/env python3
"""Reproducible, opt-in benchmark runner for a local OpenAI-compatible LLM."""

from __future__ import annotations

import argparse
import hashlib
import ipaddress
import json
import math
import os
import platform
import statistics
import subprocess
import sys
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


SCHEMA_VERSION = 1
MIN_REPETITIONS = 3
COMPATIBILITY_FIELDS = (
    "model_sha256",
    "quantization",
    "runtime_version",
    "runtime_build",
    "platform",
    "cpu_model",
    "gpu_name",
    "gpu_driver",
    "gpu_index",
    "context_size",
    "max_tokens",
    "concurrency",
    "workloads",
)


class BenchmarkError(Exception):
    """A benchmark input, request, or artifact is invalid."""


def _run_git(*args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(Path(__file__).resolve().parents[1]), *args],
        check=True,
        capture_output=True,
        text=True,
        timeout=5,
    )
    return result.stdout.strip()


def _file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as source:
            while block := source.read(1024 * 1024):
                digest.update(block)
    except OSError as exc:
        raise BenchmarkError(f"cannot read model file {path}: {exc}") from exc
    return digest.hexdigest()


def _cpu_model() -> str | None:
    try:
        for line in Path("/proc/cpuinfo").read_text(encoding="utf-8").splitlines():
            if line.lower().startswith("model name"):
                return line.split(":", 1)[1].strip()
    except OSError:
        return platform.processor() or None
    return platform.processor() or None


def _gpu_metadata(gpu_index: int) -> tuple[str | None, str | None]:
    try:
        result = subprocess.run(
            [
                "nvidia-smi",
                "--id", str(gpu_index),
                "--query-gpu=name,driver_version",
                "--format=csv,noheader",
            ],
            check=True,
            capture_output=True,
            text=True,
            timeout=3,
        )
    except (OSError, subprocess.SubprocessError):
        return None, None
    first_line = result.stdout.splitlines()[0] if result.stdout.splitlines() else ""
    name, separator, driver = first_line.partition(",")
    return (name.strip() or None, driver.strip() or None) if separator else (None, None)


def _load_workloads(path: Path, default_max_tokens: int) -> list[dict[str, Any]]:
    workloads: list[dict[str, Any]] = []
    seen_ids: set[str] = set()
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        raise BenchmarkError(f"cannot read workload file {path}: {exc}") from exc

    for line_number, line in enumerate(lines, start=1):
        if not line.strip():
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError as exc:
            raise BenchmarkError(f"{path}:{line_number}: invalid JSON: {exc}") from exc
        if not isinstance(row, dict):
            raise BenchmarkError(f"{path}:{line_number}: each workload must be an object")
        unknown = set(row) - {"id", "prompt", "system", "max_tokens", "temperature"}
        if unknown:
            raise BenchmarkError(
                f"{path}:{line_number}: unknown field(s): {', '.join(sorted(unknown))}"
            )
        workload_id, prompt = row.get("id"), row.get("prompt")
        if not isinstance(workload_id, str) or not workload_id.strip():
            raise BenchmarkError(f"{path}:{line_number}: id must be a non-empty string")
        if workload_id in seen_ids:
            raise BenchmarkError(f"{path}:{line_number}: duplicate workload id {workload_id!r}")
        if not isinstance(prompt, str) or not prompt.strip():
            raise BenchmarkError(f"{path}:{line_number}: prompt must be a non-empty string")
        system = row.get("system", "")
        if not isinstance(system, str):
            raise BenchmarkError(f"{path}:{line_number}: system must be a string")
        max_tokens = row.get("max_tokens", default_max_tokens)
        if isinstance(max_tokens, bool) or not isinstance(max_tokens, int) or max_tokens < 1:
            raise BenchmarkError(f"{path}:{line_number}: max_tokens must be a positive integer")
        temperature = row.get("temperature", 0.0)
        if (
            isinstance(temperature, bool)
            or not isinstance(temperature, (int, float))
            or not math.isfinite(temperature)
            or temperature < 0
        ):
            raise BenchmarkError(f"{path}:{line_number}: temperature must be a finite number >= 0")

        seen_ids.add(workload_id)
        workloads.append({
            "id": workload_id,
            "prompt": prompt,
            "system": system,
            "max_tokens": max_tokens,
            "temperature": float(temperature),
        })

    if not workloads:
        raise BenchmarkError(f"{path}: at least one workload is required")
    return workloads


def _local_endpoint(endpoint: str) -> str:
    parsed = urllib.parse.urlsplit(endpoint)
    if (
        parsed.scheme != "http"
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
    ):
        raise BenchmarkError("endpoint must be a plain HTTP URL to a loopback host")
    host = parsed.hostname.lower()
    try:
        local = ipaddress.ip_address(host).is_loopback
    except ValueError:
        local = host == "localhost"
    if not local:
        raise BenchmarkError("refusing to transmit prompts to a non-loopback endpoint")
    base_path = parsed.path.rstrip("/")
    if base_path.endswith("/v1/chat/completions"):
        path = base_path
    else:
        path = f"{base_path}/v1/chat/completions"
    return urllib.parse.urlunsplit(("http", parsed.netloc, path, "", ""))


def _read_system_memory() -> tuple[int | None, int | None]:
    try:
        values: dict[str, int] = {}
        for line in Path("/proc/meminfo").read_text(encoding="ascii").splitlines():
            key, _, value = line.partition(":")
            if key in {"MemTotal", "MemAvailable"}:
                values[key] = int(value.split()[0]) * 1024
        total = values.get("MemTotal")
        available = values.get("MemAvailable")
        return (total - available, total) if total is not None and available is not None else (None, total)
    except (OSError, ValueError, IndexError):
        return None, None


def _read_cpu_counters() -> tuple[int, int] | None:
    try:
        fields = Path("/proc/stat").read_text(encoding="ascii").splitlines()[0].split()
        if fields[0] != "cpu":
            return None
        counters = [int(value) for value in fields[1:]]
        total = sum(counters)
        idle = counters[3] + (counters[4] if len(counters) > 4 else 0)
        return total, idle
    except (OSError, ValueError, IndexError):
        return None


def _read_gpu_sample(gpu_index: int) -> tuple[int | None, int | None]:
    try:
        result = subprocess.run(
            [
                "nvidia-smi",
                "--id", str(gpu_index),
                "--query-gpu=memory.used,utilization.gpu",
                "--format=csv,noheader,nounits",
            ],
            check=True,
            capture_output=True,
            text=True,
            timeout=2,
        )
    except (OSError, subprocess.SubprocessError):
        return None, None
    first_line = result.stdout.splitlines()[0] if result.stdout.splitlines() else ""
    fields = [part.strip() for part in first_line.split(",")]
    try:
        if len(fields) != 2 or not all(field.isdigit() for field in fields):
            return None, None
        return int(fields[0]), int(fields[1])
    except ValueError:
        return None, None


class _ResourceMonitor:
    """Sample host and NVIDIA device resource use while one request is running."""

    def __init__(self, gpu_index: int, interval: float = 1.0) -> None:
        self.gpu_index = gpu_index
        self.interval = interval
        self.stop_event = threading.Event()
        self.thread: threading.Thread | None = None
        self.peak_memory_bytes: int | None = None
        self.memory_total_bytes: int | None = None
        self.peak_gpu_memory_mib: int | None = None
        self.peak_gpu_utilization_pct: int | None = None
        self.peak_cpu_utilization_pct: float | None = None
        self._previous_cpu: tuple[int, int] | None = None

    def _sample(self) -> None:
        used, total = _read_system_memory()
        if used is not None:
            self.peak_memory_bytes = max(self.peak_memory_bytes or 0, used)
        if total is not None:
            self.memory_total_bytes = total
        cpu = _read_cpu_counters()
        if cpu is not None and self._previous_cpu is not None:
            total_delta = cpu[0] - self._previous_cpu[0]
            idle_delta = cpu[1] - self._previous_cpu[1]
            if total_delta > 0:
                current = max(0.0, min(100.0, 100 * (total_delta - idle_delta) / total_delta))
                self.peak_cpu_utilization_pct = max(
                    self.peak_cpu_utilization_pct or 0.0, current,
                )
        self._previous_cpu = cpu
        gpu_memory, gpu_util = _read_gpu_sample(self.gpu_index)
        if gpu_memory is not None:
            self.peak_gpu_memory_mib = max(self.peak_gpu_memory_mib or 0, gpu_memory)
        if gpu_util is not None:
            self.peak_gpu_utilization_pct = max(self.peak_gpu_utilization_pct or 0, gpu_util)

    def _run(self) -> None:
        while not self.stop_event.is_set():
            self._sample()
            self.stop_event.wait(self.interval)

    def __enter__(self) -> "_ResourceMonitor":
        self._sample()
        self.thread = threading.Thread(target=self._run, name="llm-benchmark-resources", daemon=True)
        self.thread.start()
        return self

    def __exit__(self, *_exc: object) -> None:
        self.stop_event.set()
        if self.thread is not None:
            self.thread.join(timeout=max(self.interval * 2, 2))
        self._sample()

    def result(self) -> dict[str, int | float | None]:
        return {
            "peak_system_memory_bytes": self.peak_memory_bytes,
            "system_memory_total_bytes": self.memory_total_bytes,
            "peak_system_cpu_utilization_pct": (
                round(self.peak_cpu_utilization_pct, 2)
                if self.peak_cpu_utilization_pct is not None
                else None
            ),
            "peak_gpu_memory_mib": self.peak_gpu_memory_mib,
            "peak_gpu_utilization_pct": self.peak_gpu_utilization_pct,
        }


def _request_stream(
    endpoint: str,
    workload: dict[str, Any],
    timeout_seconds: float,
    api_key: str | None,
) -> dict[str, Any]:
    messages = []
    if workload["system"]:
        messages.append({"role": "system", "content": workload["system"]})
    messages.append({"role": "user", "content": workload["prompt"]})
    request_data = json.dumps({
        "messages": messages,
        "max_tokens": workload["max_tokens"],
        "temperature": workload["temperature"],
        "stream": True,
        "stream_options": {"include_usage": True},
    }).encode("utf-8")
    headers = {"Content-Type": "application/json", "Accept": "text/event-stream"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    request = urllib.request.Request(endpoint, data=request_data, headers=headers, method="POST")
    start = time.perf_counter()
    first_token: float | None = None
    usage: dict[str, Any] | None = None
    server_error: str | None = None

    try:
        with urllib.request.urlopen(request, timeout=timeout_seconds) as response:
            for raw_line in response:
                line = raw_line.decode("utf-8", errors="strict").strip()
                if not line.startswith("data:"):
                    continue
                data = line[5:].strip()
                if data == "[DONE]":
                    continue
                try:
                    event = json.loads(data)
                except json.JSONDecodeError as exc:
                    raise BenchmarkError("server returned malformed SSE JSON") from exc
                if not isinstance(event, dict):
                    raise BenchmarkError("server returned a non-object SSE event")
                if "error" in event:
                    server_error = "inference server returned an error event"
                    break
                event_usage = event.get("usage")
                if isinstance(event_usage, dict):
                    usage = event_usage
                choices = event.get("choices")
                if isinstance(choices, list) and choices and isinstance(choices[0], dict):
                    delta = choices[0].get("delta")
                    content = delta.get("content") if isinstance(delta, dict) else None
                    if isinstance(content, str) and content and first_token is None:
                        first_token = time.perf_counter()
    except urllib.error.HTTPError as exc:
        raise BenchmarkError(f"HTTP {exc.code} from local inference server") from exc
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise BenchmarkError(f"local inference request failed: {exc}") from exc
    end = time.perf_counter()

    if server_error:
        raise BenchmarkError(f"inference server returned an error: {server_error}")
    if first_token is None:
        raise BenchmarkError("stream ended without a content token")
    if usage is None:
        raise BenchmarkError("stream omitted usage; completion token count is required")
    prompt_tokens = usage.get("prompt_tokens")
    completion_tokens = usage.get("completion_tokens")
    if (
        isinstance(prompt_tokens, bool)
        or not isinstance(prompt_tokens, int)
        or prompt_tokens < 0
        or isinstance(completion_tokens, bool)
        or not isinstance(completion_tokens, int)
        or completion_tokens < 1
    ):
        raise BenchmarkError("server usage must contain non-negative prompt_tokens and positive completion_tokens")

    elapsed = end - start
    ttft = first_token - start
    decode_seconds = end - first_token
    return {
        "status": "ok",
        "prompt_tokens": prompt_tokens,
        "completion_tokens": completion_tokens,
        "ttft_ms": round(ttft * 1000, 3),
        "end_to_end_ms": round(elapsed * 1000, 3),
        "decode_tokens_per_second": round(completion_tokens / decode_seconds, 4) if decode_seconds > 0 else None,
        "observed_prompt_tokens_per_second": round(prompt_tokens / ttft, 4) if ttft > 0 else None,
    }


def _percentile(values: list[float], percentile: float) -> float:
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    position = (len(ordered) - 1) * percentile
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    weight = position - lower
    return ordered[lower] * (1 - weight) + ordered[upper] * weight


def _summarize(samples: list[dict[str, Any]]) -> dict[str, Any]:
    measured = [sample for sample in samples if not sample["warmup"]]
    successful = [sample for sample in measured if sample["status"] == "ok"]
    summary: dict[str, Any] = {
        "sample_count": len(measured),
        "success_count": len(successful),
        "failure_count": len(measured) - len(successful),
    }
    for metric in (
        "ttft_ms",
        "end_to_end_ms",
        "decode_tokens_per_second",
        "observed_prompt_tokens_per_second",
    ):
        values = [sample[metric] for sample in successful if isinstance(sample.get(metric), (int, float))]
        summary[metric] = None if not values else {
            "median": round(statistics.median(values), 4),
            "p90": round(_percentile(values, 0.9), 4),
            "min": round(min(values), 4),
            "max": round(max(values), 4),
            "stdev": round(statistics.pstdev(values), 4),
        }
    return summary


def _atomic_json_write(path: Path, payload: dict[str, Any], force: bool) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and not force:
        raise BenchmarkError(f"output already exists (pass --force to replace it): {path}")
    temp_name: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=path.parent,
            prefix=f".{path.name}.",
            suffix=".tmp",
            delete=False,
        ) as target:
            temp_name = target.name
            json.dump(payload, target, indent=2, sort_keys=True)
            target.write("\n")
            target.flush()
            os.fsync(target.fileno())
        os.replace(temp_name, path)
    except OSError as exc:
        if temp_name is not None:
            try:
                os.unlink(temp_name)
            except OSError:
                pass
        raise BenchmarkError(f"cannot write benchmark artifact {path}: {exc}") from exc


def run_benchmark(args: argparse.Namespace) -> int:
    endpoint = _local_endpoint(args.endpoint)
    model_path = Path(args.model_file).expanduser().resolve()
    if not model_path.is_file():
        raise BenchmarkError(f"model file does not exist: {model_path}")
    workload_path = Path(args.workloads).expanduser().resolve()
    output_path = Path(args.output).expanduser().resolve()
    if output_path in {model_path, workload_path}:
        raise BenchmarkError("output path must not replace the model or workload input")
    if output_path.exists() and not args.force:
        raise BenchmarkError(f"output already exists (pass --force to replace it): {output_path}")
    workloads = _load_workloads(workload_path, args.max_tokens)
    workloads_for_manifest = [
        {
            "id": item["id"],
            "prompt_sha256": hashlib.sha256(item["prompt"].encode("utf-8")).hexdigest(),
            "system_sha256": hashlib.sha256(item["system"].encode("utf-8")).hexdigest(),
            "max_tokens": item["max_tokens"],
            "temperature": item["temperature"],
        }
        for item in workloads
    ]
    gpu_name, gpu_driver = _gpu_metadata(args.gpu_index)
    git_commit = _run_git("rev-parse", "HEAD")
    dirty = bool(_run_git("status", "--porcelain"))
    artifact: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "status": "running",
        "manifest": {
            "created_at": datetime.now(timezone.utc).isoformat(),
            "git_commit": git_commit,
            "git_dirty": dirty,
            "python": sys.version,
            "python_executable": sys.executable,
            "platform": platform.platform(),
            "cpu_model": _cpu_model(),
            "cpu_count": os.cpu_count(),
            "gpu_name": gpu_name,
            "gpu_driver": gpu_driver,
            "gpu_index": args.gpu_index,
            "model_id": args.model_id,
            "model_sha256": _file_sha256(model_path),
            "model_bytes": model_path.stat().st_size,
            "quantization": args.quantization,
            "runtime_version": args.runtime_version,
            "runtime_build": args.runtime_build,
            "context_size": args.context_size,
            "max_tokens": args.max_tokens,
            "concurrency": args.concurrency,
            "cache_protocol": {
                "warmups_per_workload": args.warmups,
                "measurements_per_workload": args.repetitions,
                "sequential_requests": True,
            },
            "endpoint": urllib.parse.urlsplit(endpoint).hostname,
            "workloads": workloads_for_manifest,
        },
        "workloads": [],
    }

    for workload in workloads:
        samples: list[dict[str, Any]] = []
        groups: list[dict[str, Any]] = []
        with ThreadPoolExecutor(max_workers=args.concurrency) as executor:
            for group_index in range(args.warmups + args.repetitions):
                warmup = group_index < args.warmups
                group_started = time.perf_counter()
                started_at = datetime.now(timezone.utc).isoformat()
                monitor = _ResourceMonitor(args.gpu_index)
                measurements: list[dict[str, Any]] = []
                with monitor:
                    futures = [
                        executor.submit(
                            _request_stream, endpoint, workload, args.timeout, args.api_key,
                        )
                        for _ in range(args.concurrency)
                    ]
                    for worker_index, future in enumerate(futures):
                        item: dict[str, Any] = {
                            "workload_id": workload["id"],
                            "group": group_index,
                            "worker": worker_index,
                            "sample": group_index - args.warmups if not warmup else group_index,
                            "warmup": warmup,
                            "prompt_sha256": hashlib.sha256(
                                workload["prompt"].encode("utf-8")
                            ).hexdigest(),
                            "started_at": started_at,
                        }
                        try:
                            item.update(future.result())
                        except BenchmarkError as exc:
                            item.update({"status": "failed", "error": str(exc)})
                        measurements.append(item)
                        samples.append(item)
                group_elapsed = time.perf_counter() - group_started
                group_tokens = sum(
                    row.get("completion_tokens", 0)
                    for row in measurements
                    if row["status"] == "ok"
                )
                group_failures = sum(row["status"] != "ok" for row in measurements)
                group = {
                    "group": group_index,
                    "warmup": warmup,
                    "status": "failed" if group_failures else "ok",
                    "elapsed_ms": round(group_elapsed * 1000, 3),
                    "completion_tokens": group_tokens,
                    "decode_tokens_per_second": (
                        round(group_tokens / group_elapsed, 4)
                        if group_elapsed > 0 and not group_failures
                        else None
                    ),
                    "failure_count": group_failures,
                }
                group.update(monitor.result())
                groups.append(group)
        summary = _summarize(samples)
        group_rates = [
            group["decode_tokens_per_second"]
            for group in groups
            if not group["warmup"] and group["status"] == "ok"
        ]
        summary["concurrency_group_decode_tokens_per_second"] = (
            None if not group_rates else {
                "median": round(statistics.median(group_rates), 4),
                "p90": round(_percentile(group_rates, 0.9), 4),
                "min": round(min(group_rates), 4),
                "max": round(max(group_rates), 4),
                "stdev": round(statistics.pstdev(group_rates), 4),
            }
        )
        artifact["workloads"].append({
            "id": workload["id"],
            "samples": samples,
            "groups": groups,
            "summary": summary,
        })

    artifact["status"] = (
        "complete"
        if all(
            row["summary"]["failure_count"] == 0
            and all(group["status"] == "ok" for group in row["groups"])
            for row in artifact["workloads"]
        )
        else "failed"
    )
    artifact["completed_at"] = datetime.now(timezone.utc).isoformat()
    _atomic_json_write(output_path, artifact, args.force)
    print(f"benchmark {artifact['status']}: {args.output}")
    for workload in artifact["workloads"]:
        value = workload["summary"]["decode_tokens_per_second"]
        median = value["median"] if value else "n/a"
        print(
            f"  {workload['id']}: decode median={median} tokens/s "
            f"({workload['summary']['success_count']}/{workload['summary']['sample_count']} samples)"
        )
    return 0 if artifact["status"] == "complete" else 1


def _load_artifact(path: Path) -> dict[str, Any]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise BenchmarkError(f"cannot load benchmark artifact {path}: {exc}") from exc
    if not isinstance(payload, dict) or payload.get("schema_version") != SCHEMA_VERSION:
        raise BenchmarkError(f"{path}: unsupported or invalid benchmark artifact schema")
    if not isinstance(payload.get("manifest"), dict) or not isinstance(payload.get("workloads"), list):
        raise BenchmarkError(f"{path}: artifact must contain manifest and workloads")
    manifest_workloads = payload["manifest"].get("workloads")
    if not isinstance(manifest_workloads, list):
        raise BenchmarkError(f"{path}: manifest must contain workload definitions")
    manifest_ids: set[str] = set()
    for item in manifest_workloads:
        if not isinstance(item, dict) or not isinstance(item.get("id"), str) or not item["id"].strip():
            raise BenchmarkError(f"{path}: manifest workload definitions must have non-empty string ids")
        if item["id"] in manifest_ids:
            raise BenchmarkError(f"{path}: duplicate manifest workload id {item['id']!r}")
        manifest_ids.add(item["id"])

    seen_ids: set[str] = set()
    for row in payload["workloads"]:
        if not isinstance(row, dict) or not isinstance(row.get("id"), str) or not row["id"].strip():
            raise BenchmarkError(f"{path}: workload rows must have non-empty string ids")
        if row["id"] in seen_ids:
            raise BenchmarkError(f"{path}: duplicate workload id {row['id']!r}")
        if not isinstance(row.get("summary"), dict):
            raise BenchmarkError(f"{path}: workload {row['id']!r} has no summary object")
        seen_ids.add(row["id"])
    if seen_ids != manifest_ids:
        raise BenchmarkError(f"{path}: workload rows do not match manifest workload definitions")
    return payload


def compare_artifacts(baseline_path: Path, current_path: Path, threshold_pct: float) -> dict[str, Any]:
    baseline = _load_artifact(baseline_path)
    current = _load_artifact(current_path)
    if baseline.get("status") != "complete" or current.get("status") != "complete":
        return {
            "compatible": False,
            "mismatches": {"status": {
                "baseline": baseline.get("status"),
                "current": current.get("status"),
            }},
            "regressions": [],
        }
    old_manifest = baseline["manifest"]
    new_manifest = current["manifest"]
    mismatches = [
        field for field in COMPATIBILITY_FIELDS if old_manifest.get(field) != new_manifest.get(field)
    ]
    if mismatches:
        return {
            "compatible": False,
            "mismatches": {
                field: {"baseline": old_manifest.get(field), "current": new_manifest.get(field)}
                for field in mismatches
            },
            "regressions": [],
        }

    old_rows: dict[str, dict[str, Any]] = {
        row["id"]: row for row in baseline["workloads"]
    }
    new_rows: dict[str, dict[str, Any]] = {
        row["id"]: row for row in current["workloads"]
    }
    regressions: list[dict[str, Any]] = []
    for workload_id in sorted(old_rows):
        old_summary = old_rows[workload_id].get("summary", {})
        new_summary = new_rows.get(workload_id, {}).get("summary", {})
        metric_names = ["decode_tokens_per_second"]
        if new_manifest["concurrency"] > 1:
            metric_names.append("concurrency_group_decode_tokens_per_second")
        for metric_name in metric_names:
            old_metric = old_summary.get(metric_name)
            new_metric = new_summary.get(metric_name)
            if not isinstance(old_metric, dict) or not isinstance(new_metric, dict):
                regressions.append({
                    "workload_id": workload_id,
                    "metric": metric_name,
                    "error": "missing metric summary",
                })
                continue
            old_tps, new_tps = old_metric.get("median"), new_metric.get("median")
            if (
                isinstance(old_tps, bool) or not isinstance(old_tps, (int, float)) or old_tps <= 0
                or isinstance(new_tps, bool) or not isinstance(new_tps, (int, float)) or new_tps <= 0
            ):
                regressions.append({
                    "workload_id": workload_id,
                    "metric": metric_name,
                    "error": "invalid metric median",
                })
                continue
            drop_pct = max(0.0, (old_tps - new_tps) / old_tps * 100)
            if drop_pct > threshold_pct:
                regressions.append({
                    "workload_id": workload_id,
                    "metric": metric_name,
                    "baseline_median_tps": old_tps,
                    "current_median_tps": new_tps,
                    "drop_pct": round(drop_pct, 3),
                })
    return {
        "compatible": True,
        "max_regression_pct": threshold_pct,
        "regressions": regressions,
        "passed": not regressions,
    }


def _positive_int(value: str) -> int:
    try:
        number = int(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("must be an integer") from exc
    if number <= 0:
        raise argparse.ArgumentTypeError("must be positive")
    return number


def _nonnegative_int(value: str) -> int:
    try:
        number = int(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("must be an integer") from exc
    if number < 0:
        raise argparse.ArgumentTypeError("must be zero or positive")
    return number


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    run = commands.add_parser("run", help="run measured requests against a loopback inference server")
    run.add_argument("--endpoint", required=True, help="local HTTP server base URL")
    run.add_argument("--workloads", required=True, help="JSONL workload file; prompt text is not saved")
    run.add_argument("--output", required=True, help="new JSON artifact path")
    run.add_argument("--model-id", required=True)
    run.add_argument("--model-file", required=True, help="local model file to fingerprint")
    run.add_argument("--quantization", required=True)
    run.add_argument("--runtime-version", required=True)
    run.add_argument("--runtime-build", required=True)
    run.add_argument("--context-size", type=_positive_int, required=True)
    run.add_argument("--max-tokens", type=_positive_int, default=256)
    run.add_argument("--repetitions", type=_positive_int, default=5)
    run.add_argument("--concurrency", type=_positive_int, default=1)
    run.add_argument("--gpu-index", type=_nonnegative_int, default=0)
    run.add_argument("--warmups", type=int, default=1)
    run.add_argument("--timeout", type=float, default=300.0)
    run.add_argument(
        "--api-key",
        default=os.environ.get("LLM_BENCH_API_KEY"),
        help="optional local-server token (prefer LLM_BENCH_API_KEY over a CLI argument)",
    )
    run.add_argument("--force", action="store_true", help="replace an existing output artifact")
    compare = commands.add_parser("compare", help="compare compatible benchmark artifacts")
    compare.add_argument("baseline")
    compare.add_argument("current")
    compare.add_argument("--max-regression-pct", type=float, default=10.0)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)
    try:
        if args.command == "run":
            if args.repetitions < MIN_REPETITIONS:
                raise BenchmarkError(f"repetitions must be at least {MIN_REPETITIONS}")
            if args.warmups < 0:
                raise BenchmarkError("warmups must be non-negative")
            if not math.isfinite(args.timeout) or args.timeout <= 0:
                raise BenchmarkError("timeout must be a finite number greater than zero")
            return run_benchmark(args)
        if not math.isfinite(args.max_regression_pct) or args.max_regression_pct < 0:
            raise BenchmarkError("max regression percentage must be finite and non-negative")
        result = compare_artifacts(
            Path(args.baseline).expanduser(),
            Path(args.current).expanduser(),
            args.max_regression_pct,
        )
        print(json.dumps(result, indent=2, sort_keys=True))
        if not result["compatible"]:
            return 2
        return 0 if result["passed"] else 1
    except BenchmarkError as exc:
        print(f"llm-benchmark: error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
