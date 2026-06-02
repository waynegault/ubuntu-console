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
        # Warmup may fail because the model is still being loaded from slow
        # WSL2 drvfs after /health returns ok — retry with longer timeout.
        for _ in range(2):
            try:
                req = urllib.request.Request(base_url, data=payload,
                                             headers={"Content-Type": "application/json"}, method="POST")
                urllib.request.urlopen(req, timeout=300)
                break
            except Exception:
                time.sleep(5)

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

    # Clean shutdown
    proc.kill(); proc.wait(timeout=10)
    try: Path(f"/tmp/autotune_{port}.log").unlink()
    except Exception: pass
    # Quick kill — full VRAM clear only done before each model or on failed probes
    subprocess.run(["killall", "-9", "llama-server"],
                   capture_output=True, timeout=5)
    time.sleep(1)
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
    _log = lambda s, end='\n': print(s, end=end, flush=True)
    print()
    print(f"  ── ctx discovery ──")
    print()

    # ── Phase 1: Find the max stable ctx ──
    # Start at the conservative VRAM estimate, probe UPWARD in steps
    # until failure, then narrow down with binary search.
    discovered_ctx = 0
    best_tps = 0.0
    _ctx_log = []
    
    # Step 1: Initial probe at conservative estimate
    _log(f"  {ceiling:>8,} → ", end="")
    status, tps_vals = test_config(model_path, ceiling, c["batch"], c["ubatch"],
                                   c["parallel"], c["mmap"], warmup=True)
    if status == "ok":
        _log(f"✓ {tps_vals[0]:.1f} tps")
        discovered_ctx = ceiling
        best_tps = tps_vals[0]
        _ctx_log.append(f"✓ {ceiling:,}")
    else:
        _log("✗ too high")
        ceiling = floor  # reset to floor and search up from there

    # Step 2: Probe upward in increasing steps until failure
    if discovered_ctx > 0 and ceiling < native_ctx:
        step = max(2048, ceiling // 8)
        probe = ceiling + step
        while probe <= native_ctx:
            _log(f"  {probe:>8,} → ", end="")
            status, tps_vals = test_config(model_path, probe, c["batch"], c["ubatch"],
                                           c["parallel"], c["mmap"], warmup=True)
            if status == "ok":
                _log(f"✓ {tps_vals[0]:.1f} tps")
                discovered_ctx = probe
                best_tps = tps_vals[0]
                _ctx_log.append(f"✓ {probe:,}")
                step = max(2048, step + ceiling // 12)  # increase step
                probe += step
            else:
                _log("✗")
                _ctx_log.append(f"✗ {probe:,}")
                # Found the upper bound, binary search between last good and this
                _low = discovered_ctx
                _high = probe
                _ctx_log.append("  ── narrowing ──")
                while _low <= _high:
                    _mid = ((_low + _high) // 2) // 512 * 512
                    _mid = max(_mid, _low)
                    status, tps_vals = test_config(model_path, _mid, c["batch"], c["ubatch"],
                                                   c["parallel"], c["mmap"], warmup=True)
                    if status in ("oom", "load_fail"):
                        try:
                            subprocess.run(["sudo", "/usr/local/bin/clear_vram.sh"],
                                           capture_output=True, timeout=30)
                        except Exception:
                            subprocess.run(["killall", "-9", "llama-server"],
                                           capture_output=True, timeout=5)
                            time.sleep(2)
                    if status == "ok":
                        _ctx_log.append(f"    ✓ {_mid:,}")
                        discovered_ctx = _mid
                        best_tps = tps_vals[0] if tps_vals else best_tps
                        _low = _mid + 512
                    else:
                        _ctx_log.append(f"    ✗ {_mid:,}")
                        _high = _mid - 512
                break
            _ = [time.sleep(0.3)]
    
    if discovered_ctx < floor:
        print(f"  FATAL: No stable context ≥ {floor}")
        sys.exit(1)
    
    _ctx_log.sort(key=lambda x: int(x.split()[-1].replace(',', '')) if x.split()[-1].replace(',','').isdigit() else 999999999)
    print(f"  {'  '.join(_ctx_log)}")
    print()
    print(f"  Max ctx: {discovered_ctx}  ({best_tps:.1f} tps)")
    print()

    # ── Phase 2: Test batch/ubatch/parallel combos at max ctx ──
    # Different combos have <1% TPS impact on most models, but some
    # benefit from higher batch sizes on newer architectures (qwen3,
    # gemma3). We test a few key combos to find the best.
    combos = [
        dict(batch=512, ubatch=128, parallel=1, fit=256),
        dict(batch=1024, ubatch=256, parallel=1, fit=256),
        dict(batch=512, ubatch=128, parallel=2, fit=256),
        dict(batch=1024, ubatch=512, parallel=1, fit=512),
    ]
    
    # Prune combos that don't make sense for this model
    pruned = []
    for combo in combos:
        if combo['parallel'] == 2 and discovered_ctx < 16384:
            continue  # parallel=2 needs decent ctx to be worth it
        if combo['batch'] > 512 and discovered_ctx < 8192:
            continue  # high batch useless at small ctx
        pruned.append(combo)
    
    print(f"  ── param tuning ──")
    best_combo = CONSERVATIVE.copy()
    best_combo_tps = best_tps
    
    for combo in pruned:
        # Clear VRAM between param tests
        try:
            subprocess.run(["sudo", "/usr/local/bin/clear_vram.sh"],
                           capture_output=True, timeout=30)
        except Exception:
            subprocess.run(["killall", "-9", "llama-server"],
                           capture_output=True, timeout=5)
            time.sleep(2)
        
        # Quick TPS at this ctx with different params
        _log(f"  {discovered_ctx:,}  b={combo['batch']}/{combo['ubatch']}  p={combo['parallel']} → ", end="")
        status, tps_vals = test_config(
            model_path, discovered_ctx,
            combo['batch'], combo['ubatch'],
            combo['parallel'], CONSERVATIVE['mmap'],
            warmup=(combo == pruned[0]))
        if status == "ok" and tps_vals:
            _log(f"{tps_vals[0]:.1f} tps")
            if tps_vals[0] > best_combo_tps:
                best_combo = combo
                best_combo_tps = tps_vals[0]
        else:
            _log("✗")
    
    print()
    best_batch, best_ubatch = best_combo['batch'], best_combo['ubatch']
    best_parallel, best_mmap = best_combo['parallel'], CONSERVATIVE['mmap']

    # ── Phase 3: Registry writeback ─────────────────────────────────────
    print(f"  {_line}")
    print(f"  ✓ ctx {discovered_ctx}  b {best_batch}/{best_ubatch}  p{best_parallel}  mmap={best_mmap}  {best_combo_tps:.1f} tps")
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
