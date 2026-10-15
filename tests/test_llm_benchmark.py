"""Tests for the opt-in local LLM performance benchmark."""

import json
import threading
import time
from collections.abc import Mapping
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

from tools import llm_benchmark


class _StreamingHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers["Content-Length"])
        request = json.loads(self.rfile.read(length))
        assert request["stream"] is True
        assert request["stream_options"]["include_usage"] is True
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        prompt = request["messages"][-1]["content"]
        events: tuple[Mapping[str, object], ...]
        if prompt == "server-error":
            events = ({"error": {"message": prompt}},)
        elif prompt == "missing-usage":
            events = ({"choices": [{"delta": {"content": "answer"}}]},)
        else:
            assert prompt == "prompt text must never enter the report"
            events = (
                {"choices": [{"delta": {"content": "answer"}}]},
                {"choices": [{"delta": {}}], "usage": {"prompt_tokens": 17, "completion_tokens": 4}},
            )
        for event in events:
            self.wfile.write(f"data: {json.dumps(event)}\n\n".encode())
            self.wfile.flush()
            time.sleep(0.01)
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()

    def log_message(self, _format, *_args):
        return


@pytest.fixture
def streaming_server():
    server = ThreadingHTTPServer(("127.0.0.1", 0), _StreamingHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}"
    finally:
        server.shutdown()
        thread.join(timeout=3)
        server.server_close()


def _write_artifact(path: Path, *, median: float, status: str = "complete", context: int = 4096):
    manifest = {
        "model_sha256": "abc123",
        "quantization": "Q4_K_M",
        "runtime_version": "test",
        "runtime_build": "fixture",
        "gpu_name": "fixture gpu",
        "gpu_driver": "1.0",
        "context_size": context,
        "max_tokens": 32,
        "concurrency": 1,
        "workloads": [{"id": "sample", "prompt_sha256": "prompt", "system_sha256": "",
                       "max_tokens": 32, "temperature": 0.0}],
    }
    payload = {
        "schema_version": llm_benchmark.SCHEMA_VERSION,
        "status": status,
        "manifest": manifest,
        "workloads": [{
            "id": "sample",
            "summary": {
                "decode_tokens_per_second": {"median": median},
            },
        }],
    }
    path.write_text(json.dumps(payload), encoding="utf-8")
    return path


def test_endpoint_refuses_remote_or_credential_urls():
    with pytest.raises(llm_benchmark.BenchmarkError, match="non-loopback"):
        llm_benchmark._local_endpoint("http://example.com:8080")
    with pytest.raises(llm_benchmark.BenchmarkError, match="loopback"):
        llm_benchmark._local_endpoint("http://user:secret@127.0.0.1:8080")
    assert llm_benchmark._local_endpoint("http://[::1]:8080") == (
        "http://[::1]:8080/v1/chat/completions"
    )


def test_workload_loader_is_strict_and_rejects_duplicate_ids(tmp_path):
    path = tmp_path / "workloads.jsonl"
    path.write_text(
        '{"id":"one","prompt":"hi"}\n{"id":"one","prompt":"again"}\n',
        encoding="utf-8",
    )
    with pytest.raises(llm_benchmark.BenchmarkError, match="duplicate workload id"):
        llm_benchmark._load_workloads(path, 32)
    path.write_text('{"id":"one","prompt":"hi","max_tokens":true}\n', encoding="utf-8")
    with pytest.raises(llm_benchmark.BenchmarkError, match="positive integer"):
        llm_benchmark._load_workloads(path, 32)


def test_summary_reports_median_tail_and_failures():
    samples = [
        {"warmup": False, "status": "ok", "ttft_ms": 10, "end_to_end_ms": 30,
         "decode_tokens_per_second": 20, "observed_prompt_tokens_per_second": 100},
        {"warmup": False, "status": "ok", "ttft_ms": 20, "end_to_end_ms": 50,
         "decode_tokens_per_second": 10, "observed_prompt_tokens_per_second": 50},
        {"warmup": False, "status": "failed", "error": "timeout"},
        {"warmup": True, "status": "ok", "ttft_ms": 2},
    ]
    summary = llm_benchmark._summarize(samples)
    assert summary["sample_count"] == 3
    assert summary["success_count"] == 2
    assert summary["failure_count"] == 1
    assert summary["decode_tokens_per_second"]["median"] == 15
    assert summary["decode_tokens_per_second"]["p90"] == 19


def test_run_writes_reproducible_redacted_artifact_and_concurrency_metrics(
    tmp_path, streaming_server, monkeypatch,
):
    workload_file = tmp_path / "workloads.jsonl"
    prompt = "prompt text must never enter the report"
    workload_file.write_text(json.dumps({"id": "sanity", "prompt": prompt}) + "\n", encoding="utf-8")
    model_file = tmp_path / "model.gguf"
    model_file.write_bytes(b"test-model")
    output = tmp_path / "run.json"
    monkeypatch.setattr(llm_benchmark, "_gpu_metadata", lambda _index: (None, None))

    result = llm_benchmark.main([
        "run",
        "--endpoint", streaming_server,
        "--workloads", str(workload_file),
        "--output", str(output),
        "--model-id", "fixture-model",
        "--model-file", str(model_file),
        "--quantization", "Q4_K_M",
        "--runtime-version", "fixture-version",
        "--runtime-build", "fixture-build",
        "--context-size", "4096",
        "--max-tokens", "32",
        "--repetitions", "3",
        "--warmups", "1",
        "--concurrency", "2",
    ])

    assert result == 0
    artifact_text = output.read_text(encoding="utf-8")
    assert prompt not in artifact_text
    artifact = json.loads(artifact_text)
    assert artifact["schema_version"] == 1
    assert artifact["status"] == "complete"
    manifest = artifact["manifest"]
    assert len(manifest["model_sha256"]) == 64
    assert manifest["concurrency"] == 2
    assert manifest["cache_protocol"]["warmups_per_workload"] == 1
    row = artifact["workloads"][0]
    assert len(row["samples"]) == 8
    assert len(row["groups"]) == 4
    assert row["summary"]["success_count"] == 6
    assert row["summary"]["failure_count"] == 0
    assert row["summary"]["ttft_ms"]["median"] > 0
    assert row["summary"]["concurrency_group_decode_tokens_per_second"]["median"] > 0
    assert all(sample["status"] == "ok" for sample in row["samples"])


def test_stream_failures_are_not_converted_to_success(streaming_server):
    endpoint = llm_benchmark._local_endpoint(streaming_server)
    for prompt, message in (
        ("server-error", "inference server returned an error"),
        ("missing-usage", "omitted usage"),
    ):
        workload = {
            "id": "failure",
            "prompt": prompt,
            "system": "",
            "max_tokens": 8,
            "temperature": 0.0,
        }
        with pytest.raises(llm_benchmark.BenchmarkError, match=message) as exc_info:
            llm_benchmark._request_stream(endpoint, workload, 2, None)
        assert prompt not in str(exc_info.value)


def test_runner_never_overwrites_artifact_without_force(tmp_path, capsys):
    output = tmp_path / "existing.json"
    output.write_text("preserve me", encoding="utf-8")
    with pytest.raises(llm_benchmark.BenchmarkError, match="output already exists"):
        llm_benchmark._atomic_json_write(output, {"ok": True}, force=False)
    assert output.read_text(encoding="utf-8") == "preserve me"

    workload = tmp_path / "workloads.jsonl"
    workload.write_text('{"id":"one","prompt":"hello"}\n', encoding="utf-8")
    model_file = tmp_path / "model.gguf"
    model_file.write_bytes(b"fixture")
    result = llm_benchmark.main([
        "run",
        "--endpoint", "http://127.0.0.1:1",
        "--workloads", str(workload),
        "--output", str(output),
        "--model-id", "fixture",
        "--model-file", str(model_file),
        "--quantization", "Q4_K_M",
        "--runtime-version", "test",
        "--runtime-build", "fixture",
        "--context-size", "2048",
    ])
    assert result == 2
    assert "output already exists" in capsys.readouterr().err
    assert output.read_text(encoding="utf-8") == "preserve me"


def test_comparison_rejects_incompatible_or_failed_runs(tmp_path):
    baseline = _write_artifact(tmp_path / "baseline.json", median=100)
    current = _write_artifact(tmp_path / "current.json", median=80)
    result = llm_benchmark.compare_artifacts(baseline, current, 10)
    assert result["compatible"] is True
    assert result["passed"] is False
    assert result["regressions"][0]["drop_pct"] == 20

    incompatible = _write_artifact(tmp_path / "incompatible.json", median=80, context=8192)
    result = llm_benchmark.compare_artifacts(baseline, incompatible, 10)
    assert result["compatible"] is False
    assert "context_size" in result["mismatches"]

    failed = _write_artifact(tmp_path / "failed.json", median=80, status="failed")
    result = llm_benchmark.compare_artifacts(baseline, failed, 10)
    assert result["compatible"] is False
    assert "status" in result["mismatches"]


@pytest.mark.parametrize("mutation", ["missing", "extra"])
def test_comparison_rejects_workload_rows_that_do_not_match_manifest(tmp_path, mutation):
    baseline = _write_artifact(tmp_path / "baseline.json", median=100)
    current = _write_artifact(tmp_path / "current.json", median=100)
    payload = json.loads(current.read_text(encoding="utf-8"))
    if mutation == "missing":
        payload["workloads"] = []
    else:
        payload["workloads"].append({
            "id": "unmanifested",
            "summary": {"decode_tokens_per_second": {"median": 1}},
        })
    current.write_text(json.dumps(payload), encoding="utf-8")

    with pytest.raises(
        llm_benchmark.BenchmarkError,
        match="workload rows do not match manifest workload definitions",
    ):
        llm_benchmark.compare_artifacts(baseline, current, 10)


def test_compare_cli_reports_regression_with_nonzero_status(tmp_path, capsys):
    baseline = _write_artifact(tmp_path / "baseline.json", median=100)
    current = _write_artifact(tmp_path / "current.json", median=80)
    result = llm_benchmark.main([
        "compare", str(baseline), str(current), "--max-regression-pct", "10",
    ])
    report = json.loads(capsys.readouterr().out)
    assert result == 1
    assert report["passed"] is False
