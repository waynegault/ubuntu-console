#!/usr/bin/env python3
"""
model-autotune — Discover optimal llama-server parameters for one GGUF model.

Strategy (data-proven on 4GB VRAM / RTX 3050 Ti):
  Phase 1 — Read model's native ctx from GGUF metadata → use as ceiling.
  Phase 1 — Binary-search max stable ctx with conservative params (smallest VRAM).
  Phase 2 — Record TPS at discovered ctx, write results to registry.


Conservative-params-first ensures we discover the true VRAM-limited ctx ceiling
without being constrained by aggressive batch/ubatch settings.

Usage:
    python3 model-autotune.py <registry_row> [--ceiling-override CTX]
"""
from __future__ import annotations

import json
import os
import re
import socket
import subprocess
import sys
import time
import urllib.request
import urllib.error
from pathlib import Path

# ── Constants ──────────────────────────────────────────────────────────

LLAMA_SERVER = Path(os.path.expanduser("~/llama.cpp/build/bin/llama-server"))
REGISTRY = Path(os.path.expanduser("~/.llm/models.conf"))
MODEL_DIR = Path("/mnt/m/active")

BURN_TOKENS = 768
CTX_FLOOR = 4096
PORT_BASE = 9200

BURN_PROMPT = (
    "Explain the complete theory of special relativity in extreme detail, "
    "including the mathematical derivations for time dilation."
)

# Conservative params for ctx discovery (smallest VRAM footprint)
CONSERVATIVE = dict(batch=512, ubatch=128, parallel=1, mmap="off")

OOM_RE = re.compile(r"out of memory|oom|cuda.*(?:failed|error)|failed to allocate|cannot allocate",
                     re.IGNORECASE)


# ── GGUF metadata ─────────────────────────────────────────────────────

def read_native_ctx(model_path: str) -> int | None:
    """Read the model's native context length by briefly starting llama-server
    and parsing its metadata output. Returns None if unreadable."""
    import tempfile
    log_path = Path(tempfile.mktemp(suffix=".log", prefix="autotune_meta_"))
    port = pick_port()
    try:
        proc = subprocess.Popen(
            [str(LLAMA_SERVER),
             "--model", model_path,
             "--host", "127.0.0.1", "--port", str(port),
             "--ctx-size", "512",
             "--batch-size", "64", "--ubatch-size", "64",
             "--parallel", "1", "--threads", "1",
             "--flash-attn", "on", "--fit", "off", "--no-mmap"],
            stdout=open(str(log_path), "w"),
            stderr=subprocess.STDOUT,
        )
        # Wait for n_ctx_train to appear in log
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            if log_path.exists():
                try:
                    text = log_path.read_text(errors="ignore")
                    m = re.search(r'n_ctx_train\s*=\s*(\d+)', text)
                    if m:
                        return int(m.group(1))
                except Exception:
                    pass
            if proc.poll() is not None:
                break
            time.sleep(0.2)
        proc.kill()
        proc.wait(timeout=5)
    except Exception:
        pass
    finally:
        try:
            proc.kill()
            proc.wait(timeout=5)
        except Exception:
            pass
        try:
            log_path.unlink()
        except Exception:
            pass
    return None


# ── Helpers ────────────────────────────────────────────────────────────

def pick_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def load_registry_row(row: int) -> dict | None:
    text = REGISTRY.read_text(errors="ignore")
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("|")
        if parts[0].strip() == str(row):
            return {
                "num": parts[0], "name": parts[1], "file": parts[2], "size": parts[3],
                "quant_cache": parts[4], "arch": parts[5], "gpu_layers": parts[6],
                "ctx": parts[7], "threads": parts[8], "batch": parts[9],
                "ubatch": parts[10], "parallel": parts[11], "fit_target_mb": parts[12],
                "backend": parts[13], "mmap_mode": parts[14], "tps": parts[15],
                "autotuned": parts[16], "is_default": parts[17],
                "in_vram": parts[18] if len(parts) > 18 else "no",
            }
    return None


def write_registry_row(row: int, updates: dict) -> None:
    text = REGISTRY.read_text(errors="ignore")
    lines = text.splitlines()
    new_lines = []
    field_map = {
        "ctx": 7, "batch": 9, "ubatch": 10, "parallel": 11,
        "fit_target_mb": 12, "backend": 13, "mmap_mode": 14,
        "tps": 15, "autotuned": 16,
    }
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            new_lines.append(line)
            continue
        parts = line.split("|")
        if parts[0].strip() == str(row):
            for key, value in updates.items():
                idx = field_map.get(key)
                if idx is not None and idx < len(parts):
                    parts[idx] = str(value)
            new_lines.append("|".join(parts))
        else:
            new_lines.append(line)
    REGISTRY.write_text("\n".join(new_lines) + "\n")


def kill_zombie_servers() -> None:
    """Kill ALL llama-server instances and fully release VRAM.
    
    WSL2 CUDA has a known issue where SIGKILL doesn't always release
    VRAM immediately. We use clear_vram.sh which reloads the nvidia-uvm
    kernel module to force Windows host to release ghost allocations."""
    try:
        subprocess.run(["sudo", "/usr/local/bin/clear_vram.sh"],
                       capture_output=True, timeout=30)
    except Exception:
        # Fallback: basic kill if clear_vram.sh fails
        subprocess.run(["killall", "-9", "llama-server"],
                       capture_output=True, timeout=5)
        time.sleep(2)


def _get_free_vram_mb() -> int | None:
    for candidate in ("nvidia-smi", "/usr/lib/wsl/lib/nvidia-smi"):
        try:
            result = subprocess.run(
                [candidate, "--query-gpu=memory.free", "--format=csv,noheader,nounits"],
                capture_output=True, text=True, timeout=5
            )
            if result.returncode == 0 and result.stdout.strip():
                return int(result.stdout.strip().split("\n")[0])
        except Exception:
            continue
    return None


# ── Server lifecycle ───────────────────────────────────────────────────

def start_server(model_path: str, ctx: int, batch: int, ubatch: int,
                 parallel: int, mmap: str, port: int, threads: int = 4) -> subprocess.Popen | None:
    cmd = [
        str(LLAMA_SERVER),
        "--model", model_path,
        "--host", "127.0.0.1", "--port", str(port),
        "--ctx-size", str(ctx),
        "--batch-size", str(batch), "--ubatch-size", str(ubatch),
        "--parallel", str(parallel),
        "--threads", str(threads),
        "--flash-attn", "on",
        "--fit", "off",
    ]
    if mmap == "off":
        cmd.append("--no-mmap")

    log_path = f"/tmp/autotune_{port}.log"
    try:
        proc = subprocess.Popen(
            cmd, stdout=open(log_path, "w"), stderr=subprocess.STDOUT)
    except FileNotFoundError:
        return None

    deadline = time.monotonic() + 240
    while time.monotonic() < deadline:
        try:
            req = urllib.request.Request(f"http://127.0.0.1:{port}/health", method="GET")
            with urllib.request.urlopen(req, timeout=5):
                try:
                    log_text = Path(log_path).read_text(errors="ignore")
                    if OOM_RE.search(log_text):
                        proc.kill(); proc.wait(timeout=10)
                        return None
                except Exception:
                    pass
                return proc
        except (urllib.error.URLError, TimeoutError, OSError):
            if proc.poll() is not None:
                try:
                    if OOM_RE.search(Path(log_path).read_text(errors="ignore")):
                        return None
                except Exception:
                    pass
                return None
            time.sleep(0.5)

    proc.kill(); proc.wait(timeout=10)
    return None


def run_burn(port: int, warmup: bool = False) -> float | None:
    base_url = f"http://127.0.0.1:{port}/v1/chat/completions"
    if warmup:
        payload = json.dumps({
            "messages": [{"role": "user", "content": "Warmup"}],
            "max_tokens": 64, "temperature": 0,
        }).encode()
        try:
            req = urllib.request.Request(base_url, data=payload,
                                         headers={"Content-Type": "application/json"}, method="POST")
            urllib.request.urlopen(req, timeout=90)
        except Exception:
            pass

    payload = json.dumps({
        "messages": [{"role": "user", "content": BURN_PROMPT}],
        "max_tokens": BURN_TOKENS, "temperature": 0, "top_p": 1.0,
    }).encode()

    start_ns = time.monotonic_ns()
    try:
        req = urllib.request.Request(base_url, data=payload,
                                     headers={"Content-Type": "application/json"}, method="POST")
        with urllib.request.urlopen(req, timeout=600) as resp:
            body = resp.read().decode()
    except Exception:
        return None
    elapsed_ms = (time.monotonic_ns() - start_ns) / 1e6

    try:
        data = json.loads(body)
        ct = data.get("usage", {}).get("completion_tokens", 0)
    except Exception:
        return None
    if ct <= 0:
        return None
    return ct * 1000 / elapsed_ms


def test_config(model_path: str, ctx: int, batch: int, ubatch: int,
                parallel: int, mmap: str, warmup: bool = False) -> tuple[str, list[float]]:
    port = pick_port()
    proc = start_server(model_path, ctx, batch, ubatch, parallel, mmap, port)
    if proc is None:
        log_path = Path(f"/tmp/autotune_{port}.log")
        if log_path.exists():
            try:
                text = log_path.read_text(errors="ignore")
                if OOM_RE.search(text):
                    return ("oom", [])
                # Check for CUDA or load specific errors
                for err in ("cudaError", "CUDA error", "failed to allocate",
                           "std::bad_alloc", "cannot allocate memory",
                           "GGML_ASSERT", "not enough memory"):
                    if err in text:
                        return ("oom", [])
            except Exception:
                pass
        return ("load_fail", [])

    tps_samples = []
    for i in range(1):
        tps = run_burn(port, warmup=(warmup and i == 0))
        if tps is None:
            proc.kill(); proc.wait(timeout=10)
            try: Path(f"/tmp/autotune_{port}.log").unlink()
            except Exception: pass
            if not tps_samples:
                return ("burn_fail", [])
            break
        tps_samples.append(tps)

    # Clean shutdown: kill server and wait for VRAM release
    proc.kill(); proc.wait(timeout=10)
    try: Path(f"/tmp/autotune_{port}.log").unlink()
    except Exception: pass
    # Force VRAM release — WSL2 CUDA doesn't always free on SIGKILL
    try:
        subprocess.run(["sudo", "/usr/local/bin/clear_vram.sh"],
                       capture_output=True, timeout=30)
    except Exception:
        subprocess.run(["killall", "-9", "llama-server"],
                       capture_output=True, timeout=5)
        time.sleep(2)
    return ("ok", tps_samples)


# ── Main ───────────────────────────────────────────────────────────────

def main() -> None:
    import argparse

    parser = argparse.ArgumentParser(description="Autotune a GGUF model")
    parser.add_argument("row", type=int)

    parser.add_argument("--ceiling-override", type=int, default=None,
                        help="Override auto-detected native ctx ceiling")
    parser.add_argument("--floor", type=int, default=CTX_FLOOR)
    args = parser.parse_args()

    if not LLAMA_SERVER.exists():
        print(f"ERROR: {LLAMA_SERVER} not found")
        sys.exit(1)

    entry = load_registry_row(args.row)
    if entry is None:
        print(f"ERROR: Row {args.row} not in registry")
        sys.exit(1)

    model_path = str(MODEL_DIR / entry["file"])
    if not Path(model_path).exists():
        print(f"ERROR: {model_path} not found")
        sys.exit(1)

    model_size_gb = round(Path(model_path).stat().st_size / 1e9, 1)

    # ── Phase 0: Detect native ctx ceiling from GGUF ────────────────────
    native_ctx = read_native_ctx(model_path)
    ceiling = args.ceiling_override or native_ctx or 131072
    floor = args.floor

    print()
    _line = '─' * 42
    print(f"  {_line}")
    print(f"  Autotune {entry['name']} ({model_size_gb} GB)")
    print(f"  {_line}")
    print(f"  Arch      {entry['arch']}")
    print()

    kill_zombie_servers()
    free_vram = _get_free_vram_mb()
    
    # — Estimate a conservative starting ceiling —
    # The GGUF's native ctx is the model's declaration, but rarely fits
    # on a 4GB GPU with larger models. We estimate a safe starting point
    # and rely on the binary search to find the true stable max.
    known_free = free_vram or 3800
    model_overhead = model_size_gb * 320
    kv_per_4k = model_size_gb * 400
    if kv_per_4k > 0:
        vram_ceiling = int((known_free - model_overhead) / kv_per_4k * 4096)
        vram_ceiling = max(vram_ceiling, floor)
        vram_ceiling = min(vram_ceiling, ceiling)
        vram_ceiling = (vram_ceiling // 512) * 512
        if vram_ceiling < ceiling:
            print(f"  Native ctx {native_ctx or 'unknown'} — starting probe at ~{vram_ceiling:,}")
            ceiling = max(vram_ceiling, floor)
    if free_vram:
        print(f"  VRAM {free_vram} MiB free")
    
    c = CONSERVATIVE
    print(f"  Tuning: ctx (fixed batch={c['batch']} ubatch={c['ubatch']} p={c['parallel']})")
    print()

    # Probe ceiling first with conservative params and warmup.
    # Warmup ensures the GPU is in high-clock state before measuring TPS.
    _ctx_display = f"{ceiling:,}" if ceiling > 999 else str(ceiling)
    print(f"  ctx {_ctx_display:>7} → ", end="", flush=True)
    status, tps_vals = test_config(model_path, ceiling, c["batch"], c["ubatch"],
                                   c["parallel"], c["mmap"], warmup=True)
    _status_msg = {"ok": "✓", "oom": "OOM", "burn_fail": "✗", "load_fail": "✗"}.get(status, status)
    _tps_msg = f" ({tps_vals[0]:.1f} tps)" if tps_vals else ""
    print(f"{_status_msg}{_tps_msg}")

    if status == "ok":
        discovered_ctx = ceiling
        best_tps = tps_vals[0] if tps_vals else 0
        print(f"  → Stable at {ceiling}")
    else:
        print(f"  → {ceiling} too high — binary searching")
        discovered_ctx = 0
        best_tps = 0
        low, high = floor, ceiling
        _probe_log = []

        while low <= high:
            mid = ((low + high) // 2) // 512 * 512
            mid = max(mid, floor)
            mid = max(mid, low)

            # Probe with compact one-char status
            status, tps_vals = test_config(model_path, mid, c["batch"], c["ubatch"],
                                           c["parallel"], c["mmap"], warmup=True)
            # Aggressive VRAM cleanup between probes
            if status in ("oom", "load_fail"):
                try:
                    subprocess.run(["sudo", "/usr/local/bin/clear_vram.sh"],
                                   capture_output=True, timeout=30)
                except Exception:
                    subprocess.run(["killall", "-9", "llama-server"],
                                   capture_output=True, timeout=5)
                    time.sleep(2)
            
            if status == "ok":
                _probe_log.append(f"✓ {mid:,}")
                discovered_ctx = mid
                best_tps = tps_vals[0] if tps_vals else 0
                low = mid + 512
            else:
                _probe_log.append(f"✗ {mid:,}")
                high = mid - 512
            if low > ceiling:
                break
        
        # Show probe log sorted, with failed entries indicated
        _probe_log.sort(key=lambda x: int(x.split()[-1].replace(',', '')))
        print(f"  {'  '.join(_probe_log)}")

    if discovered_ctx < floor:
        print(f"  FATAL: No stable context ≥ {floor}")
        sys.exit(1)

    print(f"  → ctx {discovered_ctx}  ({best_tps:.1f} tps)")

    # Use conservative params directly (proven: batch/ubatch/parallel
    # have <1% effect on TPS; conservative = smallest VRAM footprint).
    best_batch, best_ubatch = c["batch"], c["ubatch"]
    best_parallel, best_mmap = c["parallel"], c["mmap"]

    # ── Phase 3: Registry writeback ─────────────────────────────────────
    print(f"  {_line}")
    print(f"  ✓ ctx {discovered_ctx}  batch {best_batch}/{best_ubatch}  p{best_parallel}  mmap={best_mmap}  {best_tps:.1f} tps")
    print(f"  {_line}")
    print()

    write_registry_row(args.row, {
        "ctx": discovered_ctx,
        "batch": best_batch,
        "ubatch": best_ubatch,
        "parallel": best_parallel,
        "mmap_mode": best_mmap,
        "tps": f"{best_tps:.1f}",
        "autotuned": "yes",
    })

    print(f"    Registry row {args.row}: autotuned=yes")
    print()


if __name__ == "__main__":
    main()
