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
import statistics
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

# Short burst for ctx discovery — TPS accuracy isn't the goal, we just need to
# confirm the model can generate at a given ctx size without crashing.
BURN_TOKENS_DISCOVERY = int(os.environ.get("LLM_AUTOTUNE_BURN_TOKENS_DISCOVERY", "64"))
BURN_TOKENS_SCORE = int(os.environ.get("LLM_AUTOTUNE_BURN_TOKENS_SCORE", "128"))
TPS_SAMPLES_PROFILE = int(os.environ.get("LLM_AUTOTUNE_TPS_SAMPLES_PROFILE", "2"))
TPS_SAMPLES_PARAM = int(os.environ.get("LLM_AUTOTUNE_TPS_SAMPLES_PARAM", "2"))
STARTUP_HEALTH_TIMEOUT_SEC = int(os.environ.get("LLM_AUTOTUNE_STARTUP_HEALTH_TIMEOUT_SEC", "120"))
STARTUP_PREFLIGHT_TIMEOUT_SEC = int(os.environ.get("LLM_AUTOTUNE_STARTUP_PREFLIGHT_TIMEOUT_SEC", "60"))
CTX_FLOOR = 4096
PORT_BASE = 9200
MIN_ACCEPTABLE_TPS_DEFAULT = 20.0
BURN_TIMEOUT_SEC = int(os.environ.get("LLM_AUTOTUNE_BURN_TIMEOUT_SEC", "600"))

# Backward-compatible alias used by tests and older callers.
BURN_TOKENS = BURN_TOKENS_DISCOVERY

BURN_PROMPT = (
    "Explain the complete theory of special relativity in extreme detail, "
    "including the mathematical derivations for time dilation."
)

# Conservative params for ctx discovery (smallest VRAM footprint)
CONSERVATIVE = dict(batch=512, ubatch=128, parallel=1, mmap="off")

OOM_RE = re.compile(r"out of memory|oom|cuda.*(?:failed|error)|failed to allocate|cannot allocate",
                     re.IGNORECASE)


def _parse_arch_tps_overrides(raw: str) -> dict[str, float]:
    """Parse LLM_AUTOTUNE_MIN_TPS_ARCH mapping like: "phi3=3.0,gemma3n=2.7"."""
    out: dict[str, float] = {}
    for item in (raw or "").split(","):
        token = item.strip()
        if not token or "=" not in token:
            continue
        key, val = token.split("=", 1)
        key = key.strip().lower()
        try:
            out[key] = float(val.strip())
        except Exception:
            continue
    return out


def resolve_min_tps(arch: str, model_size_gb: float, cli_min_tps: float | None) -> float:
    """Resolve min TPS policy.

    Priority:
      1) Explicit --min-tps CLI override.
      2) Arch override from LLM_AUTOTUNE_MIN_TPS_ARCH (exact/prefix).
      3) Built-in arch defaults (phi3=3.0).
      4) Large-model relaxation (>= LLM_AUTOTUNE_LARGE_MODEL_GB => LLM_AUTOTUNE_MIN_TPS_LARGE).
      5) Global default LLM_AUTOTUNE_MIN_TPS (2.5).
    """
    if cli_min_tps is not None:
        return float(cli_min_tps)

    base = float(os.environ.get("LLM_AUTOTUNE_MIN_TPS", MIN_ACCEPTABLE_TPS_DEFAULT))
    a = (arch or "").strip().lower()

    env_map = _parse_arch_tps_overrides(os.environ.get("LLM_AUTOTUNE_MIN_TPS_ARCH", ""))
    for k, v in env_map.items():
        if a == k or a.startswith(k):
            return float(v)

    builtins = {
        "phi3": float(os.environ.get("LLM_AUTOTUNE_MIN_TPS_PHI3", "3.0")),
    }
    for k, v in builtins.items():
        if a == k or a.startswith(k):
            return float(v)

    large_threshold = float(os.environ.get("LLM_AUTOTUNE_LARGE_MODEL_GB", "3.0"))
    large_floor = float(os.environ.get("LLM_AUTOTUNE_MIN_TPS_LARGE", "2.0"))
    if model_size_gb >= large_threshold:
        return float(large_floor)

    return base


def discovery_profiles_for_arch(arch: str) -> list[dict[str, str]]:
    """Return startup flag profiles for ctx discovery.

    Some architectures are sensitive to mmap/flash-attn combinations on
    constrained VRAM systems (notably phi3 variants on WSL2). Try a small
    ordered set of conservative profiles before declaring a model unusable.
    """
    a = (arch or "").strip().lower()
    if a.startswith("phi3") or a.startswith("phi"):
        return [
            {"mmap": "off", "flash_attn": "on"},
            {"mmap": "auto", "flash_attn": "on"},
            {"mmap": "off", "flash_attn": "off"},
            {"mmap": "auto", "flash_attn": "off"},
        ]
    if a.startswith("gemma3n"):
        return [
            {"mmap": "off", "flash_attn": "on"},
            {"mmap": "auto", "flash_attn": "on"},
            {"mmap": "off", "flash_attn": "off"},
            {"mmap": "auto", "flash_attn": "off"},
        ]
    # Default path: evaluate both flash-attn on/off with both mmap modes,
    # so flash-attn=off can legitimately win when it improves stability.
    return [
        {"mmap": "off", "flash_attn": "on"},
        {"mmap": "auto", "flash_attn": "on"},
        {"mmap": "off", "flash_attn": "off"},
        {"mmap": "auto", "flash_attn": "off"},
    ]


# ── GGUF metadata ─────────────────────────────────────────────────────

def read_native_ctx(model_path: str) -> int | None:
    """Read the model's native context length directly from the GGUF binary header.

    GGUF format: magic(4) + version(4) + n_tensors(8) + n_kv(8) + kv_pairs...
    Each kv pair: key_len(8) + key(key_len) + type(4) + value...
    We scan for '<arch>.context_length' or 'context_length'.
    Returns None if unreadable.
    """
    import struct
    GGUF_MAGIC = b"GGUF"
    # Fixed-width byte sizes per GGUF scalar type id
    _SCALAR_SZ = {4: 4, 5: 4, 6: 4, 10: 8, 11: 8, 7: 1, 12: 2, 13: 4}

    def _skip(f: "BinaryIO", vtype: int) -> None:
        if vtype in _SCALAR_SZ:
            f.read(_SCALAR_SZ[vtype])
        elif vtype == 8:  # string
            slen = struct.unpack("<Q", f.read(8))[0]
            f.read(slen)
        elif vtype == 9:  # array — skip each element
            arr_type = struct.unpack("<I", f.read(4))[0]
            arr_len = struct.unpack("<Q", f.read(8))[0]
            for _ in range(arr_len):
                _skip(f, arr_type)
        else:
            raise ValueError(f"unknown GGUF type {vtype}")

    def _read_int(f: "BinaryIO", vtype: int) -> int | None:
        if vtype == 4:  return struct.unpack("<I", f.read(4))[0]
        if vtype == 5:  return struct.unpack("<i", f.read(4))[0]
        if vtype == 10: return struct.unpack("<Q", f.read(8))[0]
        if vtype == 11: return struct.unpack("<q", f.read(8))[0]
        _skip(f, vtype)
        return None

    try:
        with open(model_path, "rb") as f:
            if f.read(4) != GGUF_MAGIC:
                return None
            version = struct.unpack("<I", f.read(4))[0]
            if version not in (1, 2, 3):
                return None
            _n_tensors = struct.unpack("<Q", f.read(8))[0]
            n_kv = struct.unpack("<Q", f.read(8))[0]
            for _ in range(min(int(n_kv), 512)):
                key_len = struct.unpack("<Q", f.read(8))[0]
                if key_len > 512:
                    return None  # malformed
                key = f.read(key_len).decode("utf-8", errors="replace")
                vtype = struct.unpack("<I", f.read(4))[0]
                val = _read_int(f, vtype)
                if key.endswith(".context_length") and val is not None and val > 0:
                    return int(val)
    except Exception:
        pass
    return None


# ── Helpers ────────────────────────────────────────────────────────────

def estimate_vram_ceiling(model_size_gb: float, free_vram_mb: int | None,
                          native_ctx: int | None, floor: int,
                          ceiling: int) -> int:
    """Estimate a safe ctx ceiling from available VRAM.
    
    Returns a 512-aligned ctx value bounded by floor..ceiling.
    If VRAM data is insufficient, returns floor as a safe minimum.
    """
    known_free = free_vram_mb or 3800
    model_overhead = model_size_gb * 320
    kv_per_4k = model_size_gb * 400
    if kv_per_4k <= 0:
        return floor
    est = int((known_free - model_overhead) / kv_per_4k * 4096)
    est = min(est, ceiling)
    est = (est // 512) * 512
    return max(est, floor)


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
            if len(parts) not in (19, 20):
                raise RuntimeError(
                    f"Invalid registry schema in row {row}: expected 19 or 20 columns, got {len(parts)}"
                )

            def _get(idx: int, default: str = "") -> str:
                return parts[idx] if idx < len(parts) else default

            # 19-column schema has no flash_attn field:
            # ...|backend|mmap_mode|tps|autotuned|is_default|in_vram
            if len(parts) == 19:
                flash_attn = "on"
                tps = _get(15, "0")
                autotuned = _get(16, "no")
                is_default = _get(17, "no")
                in_vram = _get(18, "no")
            else:
                flash_attn = _get(15, "on")
                tps = _get(16, "0")
                autotuned = _get(17, "no")
                is_default = _get(18, "no")
                in_vram = _get(19, "no")

            return {
                "num": _get(0), "name": _get(1), "file": _get(2), "size": _get(3),
                "quant_cache": _get(4), "arch": _get(5), "gpu_layers": _get(6),
                "ctx": _get(7), "threads": _get(8), "batch": _get(9),
                "ubatch": _get(10), "parallel": _get(11), "fit_target_mb": _get(12),
                "backend": _get(13), "mmap_mode": _get(14, "auto"),
                "flash_attn": flash_attn,
                "tps": tps,
                "autotuned": autotuned,
                "is_default": is_default,
                "in_vram": in_vram,
            }
    return None


def write_registry_row(row: int, updates: dict) -> None:
    text = REGISTRY.read_text(errors="ignore")
    lines = text.splitlines()
    new_lines = []
    field_map = {
        "ctx": 7, "batch": 9, "ubatch": 10, "parallel": 11,
        "fit_target_mb": 12, "backend": 13, "mmap_mode": 14,
        "flash_attn": 15, "tps": 16, "autotuned": 17,
    }
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            new_lines.append(line)
            continue
        parts = line.split("|")
        if parts[0].strip() == str(row):
            if len(parts) not in (19, 20):
                raise RuntimeError(
                    f"Invalid registry schema in row {row}: expected 19 or 20 columns, got {len(parts)}"
                )

            # Column indexes differ by schema depending on flash_attn presence.
            if len(parts) == 19:
                schema_field_map = {
                    "ctx": 7, "batch": 9, "ubatch": 10, "parallel": 11,
                    "fit_target_mb": 12, "backend": 13, "mmap_mode": 14,
                    "tps": 15, "autotuned": 16,
                }
            else:
                schema_field_map = field_map

            for key, value in updates.items():
                idx = schema_field_map.get(key)
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
    kernel module to force Windows host to release ghost allocations.
    
    After clearing VRAM we add a cooldown to let the WSL2 9p drvfs
    release any cached file handles on the previous model's GGUF."""
    try:
        subprocess.run(["sudo", "/usr/local/bin/clear_vram.sh"],
                       capture_output=True, timeout=30)
        time.sleep(1.5)  # let nvidia-uvm reload settle
    except Exception:
        # Fallback: basic kill if clear_vram.sh fails
        subprocess.run(["killall", "-9", "llama-server"],
                       capture_output=True, timeout=5)
        time.sleep(3)


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
                 parallel: int, mmap: str, port: int, threads: int = 4,
                 flash_attn: str = "on") -> subprocess.Popen | None:
    cmd = [
        str(LLAMA_SERVER),
        "--model", model_path,
        "--host", "127.0.0.1", "--port", str(port),
        "--ctx-size", str(ctx),
        "--batch-size", str(batch), "--ubatch-size", str(ubatch),
        "--parallel", str(parallel),
        "--threads", str(threads),
        "--flash-attn", flash_attn,
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

    deadline = time.monotonic() + STARTUP_HEALTH_TIMEOUT_SEC
    health_ok = False
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
                health_ok = True
                break
        except (urllib.error.URLError, TimeoutError, OSError):
            if proc.poll() is not None:
                try:
                    if OOM_RE.search(Path(log_path).read_text(errors="ignore")):
                        return None
                except Exception:
                    pass
                return None
            time.sleep(0.5)

    if not health_ok:
        proc.kill(); proc.wait(timeout=10)
        return None

    # Pre-flight: send a tiny completion to confirm the model slot is actually
    # ready to serve (WSL2: /health returns OK before slot is ready).
    deadline = time.monotonic() + STARTUP_PREFLIGHT_TIMEOUT_SEC
    preflight = json.dumps({
        "messages": [{"role": "user", "content": "hi"}],
        "max_tokens": 1, "temperature": 0,
    }).encode()
    preflight_url = f"http://127.0.0.1:{port}/v1/chat/completions"
    while time.monotonic() < deadline:
        try:
            req = urllib.request.Request(preflight_url, data=preflight,
                                         headers={"Content-Type": "application/json"}, method="POST")
            with urllib.request.urlopen(req, timeout=30):
                return proc
        except Exception:
            if proc.poll() is not None:
                return None
            time.sleep(2)

    proc.kill(); proc.wait(timeout=10)
    return None


def run_burn(port: int, warmup: bool = False, max_tokens: int = BURN_TOKENS_DISCOVERY) -> float | None:
    base_url = f"http://127.0.0.1:{port}/v1/chat/completions"
    if warmup:
        payload = json.dumps({
            "messages": [{"role": "user", "content": "Warmup"}],
            "max_tokens": 8, "temperature": 0,
        }).encode()
        # Warmup may fail because the model is still being loaded from slow
        # WSL2 drvfs after /health returns ok — retry with escalating delays.
        for _ in range(8):
            try:
                req = urllib.request.Request(base_url, data=payload,
                                             headers={"Content-Type": "application/json"}, method="POST")
                urllib.request.urlopen(req, timeout=300)
                break
            except Exception:
                time.sleep(10)

    payload = json.dumps({
        "messages": [{"role": "user", "content": BURN_PROMPT}],
        "max_tokens": max_tokens, "temperature": 0, "top_p": 1.0,
    }).encode()

    for attempt in range(2):
        start_ns = time.monotonic_ns()
        try:
            req = urllib.request.Request(base_url, data=payload,
                                         headers={"Content-Type": "application/json"}, method="POST")
            with urllib.request.urlopen(req, timeout=BURN_TIMEOUT_SEC) as resp:
                body = resp.read().decode()
        except Exception:
            if attempt == 0:
                time.sleep(2)
                continue
            return None
        elapsed_ms = (time.monotonic_ns() - start_ns) / 1e6

        try:
            data = json.loads(body)
            ct = data.get("usage", {}).get("completion_tokens", 0)
        except Exception:
            if attempt == 0:
                time.sleep(2)
                continue
            return None
        if ct <= 0:
            if attempt == 0:
                time.sleep(2)
                continue
            return None
        return ct * 1000 / elapsed_ms

    return None


def test_config(model_path: str, ctx: int, batch: int, ubatch: int,
                parallel: int, mmap: str, warmup: bool = False,
                flash_attn: str = "on", samples: int = 1,
                burn_tokens: int = BURN_TOKENS_DISCOVERY) -> tuple[str, list[float]]:
    port = pick_port()
    proc = start_server(model_path, ctx, batch, ubatch, parallel, mmap, port,
                        flash_attn=flash_attn)
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
    for i in range(max(1, int(samples))):
        tps = run_burn(port, warmup=(warmup and i == 0), max_tokens=burn_tokens)
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
    kill_zombie_servers()
    return ("ok", tps_samples)


def test_config_with_retry(model_path: str, ctx: int, batch: int, ubatch: int,
                           parallel: int, mmap: str, warmup: bool = False,
                           flash_attn: str = "on", samples: int = 1,
                           burn_tokens: int = BURN_TOKENS_DISCOVERY,
                           retries: int = 1) -> tuple[str, list[float]]:
    """Run one config and retry once on transient startup failures."""
    attempts = 0
    while True:
        status, tps_vals = test_config(
            model_path,
            ctx,
            batch,
            ubatch,
            parallel,
            mmap,
            warmup=warmup,
            flash_attn=flash_attn,
            samples=samples,
            burn_tokens=burn_tokens,
        )
        if status != "load_fail":
            return (status, tps_vals)
        if attempts >= retries:
            return (status, tps_vals)
        attempts += 1
        # Transient startup failures happen after rapid clear/restart cycles.
        kill_zombie_servers()
        time.sleep(1.0)


def stable_tps(samples: list[float]) -> float:
    if not samples:
        return 0.0
    try:
        return float(statistics.median(samples))
    except Exception:
        return float(samples[0])


def stable_score(samples: list[float], penalty: float = 0.20) -> float:
    """Score TPS samples with a stability penalty.

    Higher is better. We penalize high variance so bursty configs lose to
    steadier ones at similar median TPS.
    """
    if not samples:
        return 0.0
    med = stable_tps(samples)
    if len(samples) < 2:
        return med
    try:
        sd = float(statistics.pstdev(samples))
    except Exception:
        sd = 0.0
    return max(0.0, med - (max(0.0, penalty) * sd))


def refine_upward_from_ctx(
    *,
    model_path: str,
    start_ctx: int,
    start_tps: float,
    ceiling: int,
    step: int,
    c: dict[str, int | str],
    flash_attn: str,
) -> tuple[int, float]:
    """Continue upward search from an already-proven ctx without re-probing start_ctx."""
    highest_ok = start_ctx
    best_tps = start_tps
    up_step = max(512, (step // 512) * 512)

    while up_step >= 512:
        candidate = highest_ok + up_step
        if candidate > ceiling:
            if up_step == 512:
                break
            up_step = max(512, (up_step // 2 // 512) * 512)
            continue

        print(f"  {candidate:>8,} -> ", end="", flush=True)
        status, tps_vals = test_config(
            model_path,
            candidate,
            int(c["batch"]),
            int(c["ubatch"]),
            int(c["parallel"]),
            str(c["mmap"]),
            flash_attn=flash_attn,
            samples=1,
            burn_tokens=BURN_TOKENS_DISCOVERY,
        )
        if status == "ok" and tps_vals:
            cand_tps = tps_vals[0]
            print(f"OK {cand_tps:.1f} tps", flush=True)
            highest_ok = candidate
            best_tps = cand_tps
            continue

        print("FAIL", flush=True)
        kill_zombie_servers()
        if up_step == 512:
            break
        up_step = max(512, (up_step // 2 // 512) * 512)

    return (highest_ok, best_tps)


def discover_ctx_with_profile(
    *,
    model_path: str,
    floor: int,
    ceiling: int,
    native_ctx: int | None,
    est_ceiling: int,
    c: dict[str, int | str],
    flash_attn: str,
) -> tuple[int, float, list[str], int]:
    """Discover max stable ctx for one mmap/flash-attn profile.

    Returns: (discovered_ctx, best_tps, ctx_log, step_used)
    """
    discovered_ctx = 0
    best_tps = 0.0
    ctx_log: list[str] = []
    start_ctx = min(ceiling, est_ceiling)
    start_ctx = (start_ctx // 512) * 512
    start_ctx = max(floor, start_ctx)

    step = max(512, ((start_ctx - floor) // 4 // 512) * 512)
    if step == 0:
        step = 512

    def _probe(ctx_val: int, warmup: bool) -> tuple[str, list[float]]:
        print(f"  {ctx_val:>8,} -> ", end="", flush=True)
        _status, _tps_vals = test_config(
            model_path,
            ctx_val,
            int(c["batch"]),
            int(c["ubatch"]),
            int(c["parallel"]),
            str(c["mmap"]),
            warmup=warmup,
            flash_attn=flash_attn,
            samples=1,
            burn_tokens=BURN_TOKENS_DISCOVERY,
        )
        if _status == "ok" and _tps_vals:
            print(f"OK {_tps_vals[0]:.1f} tps", flush=True)
            ctx_log.append(f"OK {ctx_val:,}")
        else:
            print("FAIL", flush=True)
            ctx_log.append(f"FAIL {ctx_val:,}")
            kill_zombie_servers()
        return (_status, _tps_vals)

    # 1) Start at estimated ceiling. If it fails, walk down to find first success.
    probe = start_ctx
    first = True
    while probe >= floor:
        status, tps_vals = _probe(probe, warmup=first)
        first = False
        if status == "ok" and tps_vals:
            discovered_ctx = probe
            best_tps = tps_vals[0]
            break
        if probe == floor:
            break
        probe = max(floor, probe - step)

    if discovered_ctx == 0:
        return (0, 0.0, ctx_log, step)

    # 2) Walk upward from first success. On failure, reduce step and retry from
    # the highest successful ctx until 512 resolution is exhausted.
    highest_ok = discovered_ctx
    up_step = step
    while up_step >= 512:
        candidate = highest_ok + up_step
        if candidate > ceiling:
            if up_step == 512:
                break
            up_step = max(512, (up_step // 2 // 512) * 512)
            continue

        status, tps_vals = _probe(candidate, warmup=False)
        if status == "ok" and tps_vals:
            highest_ok = candidate
            discovered_ctx = candidate
            best_tps = tps_vals[0]
            continue

        if up_step == 512:
            break
        up_step = max(512, (up_step // 2 // 512) * 512)

    return (discovered_ctx, best_tps, ctx_log, step)


# ── Main ───────────────────────────────────────────────────────────────

def main() -> None:
    import argparse

    parser = argparse.ArgumentParser(description="Autotune a GGUF model")
    parser.add_argument("row", type=int)
    parser.add_argument("--ceiling-override", type=int, default=None,
                        help="Override auto-detected native ctx ceiling")
    parser.add_argument("--floor", type=int, default=CTX_FLOOR)
    parser.add_argument("--min-tps", type=float, default=None,
                        help="Minimum acceptable TPS override (otherwise uses arch/size policy)")
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
    min_tps = resolve_min_tps(entry.get("arch", ""), model_size_gb, args.min_tps)

    # ── Phase 0: Read native ctx directly from GGUF binary ──────────────
    native_ctx = read_native_ctx(model_path)
    ceiling = args.ceiling_override or native_ctx or 131072
    floor = args.floor

    _line = '─' * 42
    print()
    print(f"  {_line}")
    print(f"  Autotune {entry['name']} ({model_size_gb} GB)")
    print(f"  {_line}")
    print(f"  Arch      {entry['arch']}")
    print(f"  Min TPS   {min_tps:.1f}")
    print()

    kill_zombie_servers()
    free_vram = _get_free_vram_mb()
    _est = estimate_vram_ceiling(model_size_gb, free_vram, native_ctx, floor, ceiling)
    native_display = f"{native_ctx:,}" if native_ctx else "unknown"
    print(f"  Native ctx {native_display}  — estimated ceiling ~{_est:,}")
    if free_vram:
        print(f"  VRAM {free_vram} MiB free")
    print()

    profiles = discovery_profiles_for_arch(entry.get("arch", ""))

    # ── Phase 1: ctx discovery with reduced redundant probes ─────────────
    #
    # Largest-ctx policy: we must not miss a higher ctx from a secondary
    # profile. We do one full discovery on the primary profile, then only do
    # cheap checks on other profiles and run upward refinement if they can
    # sustain the current global max.
    #
    print(f"  ── ctx discovery ──")
    print()

    primary = profiles[0]
    print(f"  profile mmap={primary['mmap']} flash-attn={primary['flash_attn']}")
    c_primary = dict(CONSERVATIVE)
    c_primary["mmap"] = primary["mmap"]
    max_stable_ctx, max_stable_tps, _ctx_log, step_hint = discover_ctx_with_profile(
        model_path=model_path,
        floor=floor,
        ceiling=ceiling,
        native_ctx=native_ctx,
        est_ceiling=_est,
        c=c_primary,
        flash_attn=primary["flash_attn"],
    )
    discovery_profile = primary if max_stable_ctx > 0 else None

    # If the primary profile cannot hold floor, fall back to full discovery on
    # the remaining profiles until one succeeds.
    if max_stable_ctx == 0:
        for profile in profiles[1:]:
            print(f"  profile mmap={profile['mmap']} flash-attn={profile['flash_attn']}")
            c_profile = dict(CONSERVATIVE)
            c_profile["mmap"] = profile["mmap"]
            _ctx, _tps, _ctx_log, step_hint = discover_ctx_with_profile(
                model_path=model_path,
                floor=floor,
                ceiling=ceiling,
                native_ctx=native_ctx,
                est_ceiling=_est,
                c=c_profile,
                flash_attn=profile["flash_attn"],
            )
            if _ctx > 0:
                max_stable_ctx = _ctx
                max_stable_tps = _tps
                discovery_profile = profile
                break
            print(f"  profile failed at floor {floor:,} — trying next")

    if max_stable_ctx == 0 or discovery_profile is None:
        print(f"  FATAL: No stable context ≥ {floor}")
        sys.exit(1)

    print()
    print(f"  Max stable ctx: {max_stable_ctx:,}  ({max_stable_tps:.1f} tps)")
    print(f"  Discovery profile: mmap={discovery_profile['mmap']} flash-attn={discovery_profile['flash_attn']}")
    print()

    # ── Phase 2: Cross-profile refinement (largest ctx first) ───────────
    print(f"  ── profile refinement at ctx {max_stable_ctx:,} ──")
    print()

    selected_profile = discovery_profile
    discovered_ctx = max_stable_ctx
    selected_tps = max_stable_tps

    for profile in [p for p in profiles if p != discovery_profile]:
        print(f"  mmap={profile['mmap']} fa={profile['flash_attn']}  probe {max_stable_ctx:,} -> ", end="", flush=True)
        status, tps_vals = test_config_with_retry(
            model_path,
            max_stable_ctx,
            CONSERVATIVE["batch"],
            CONSERVATIVE["ubatch"],
            CONSERVATIVE["parallel"],
            profile["mmap"],
            flash_attn=profile["flash_attn"],
            samples=max(1, TPS_SAMPLES_PROFILE),
            burn_tokens=BURN_TOKENS_SCORE,
            retries=1,
        )
        if status != "ok" or not tps_vals:
            print("FAIL", flush=True)
            kill_zombie_servers()
            continue

        profile_tps = stable_tps(tps_vals)
        profile_ctx = max_stable_ctx
        print(f"OK {profile_tps:.1f} tps (median of {len(tps_vals)})", flush=True)

        # Only profiles that hold current max can possibly beat it. Refine
        # upward from current max to see if they can extend the ceiling.
        c_profile = dict(CONSERVATIVE)
        c_profile["mmap"] = profile["mmap"]
        up_ctx, up_tps = refine_upward_from_ctx(
            model_path=model_path,
            start_ctx=max_stable_ctx,
            start_tps=profile_tps,
            ceiling=ceiling,
            step=step_hint,
            c=c_profile,
            flash_attn=profile["flash_attn"],
        )
        if up_ctx > profile_ctx:
            profile_ctx = up_ctx
            profile_tps = up_tps
            print(f"    profile extends max ctx -> {profile_ctx:,} ({profile_tps:.1f} tps)")

        if profile_ctx > max_stable_ctx or (profile_ctx == max_stable_ctx and profile_tps > max_stable_tps):
            max_stable_ctx = profile_ctx
            max_stable_tps = profile_tps

        if profile_ctx > discovered_ctx or (profile_ctx == discovered_ctx and profile_tps > selected_tps):
            discovered_ctx = profile_ctx
            selected_tps = profile_tps
            selected_profile = profile
    print()
    print(f"  Selected profile: mmap={selected_profile['mmap']} flash-attn={selected_profile['flash_attn']}  ({selected_tps:.1f} tps)")
    print()

    # ── Phase 3: Batch/ubatch/parallel tuning at discovered ctx ─────────
    # Adaptive search: evaluate a small anchor set, then expand around top
    # performers (beam search) instead of brute-forcing a static list.
    stability_penalty = float(os.environ.get("LLM_AUTOTUNE_PARAM_STABILITY_PENALTY", "0.20"))
    beam_width = max(1, int(os.environ.get("LLM_AUTOTUNE_PARAM_BEAM_WIDTH", "2")))
    beam_rounds = max(1, int(os.environ.get("LLM_AUTOTUNE_PARAM_BEAM_ROUNDS", "2")))

    def _fit_for_batch(batch: int) -> int:
        if batch <= 1024:
            return 256
        if batch <= 1536:
            return 512
        return 768

    def _combo_key(c: dict[str, int]) -> tuple[int, int, int]:
        return (c["batch"], c["ubatch"], c["parallel"])

    def _candidate_space(ctx_val: int) -> list[dict[str, int]]:
        batches = [512, 768, 1024, 1536, 2048]
        ubatches = [128, 256, 512]
        parallels = [1, 2]
        if ctx_val >= 32768:
            parallels.append(3)

        out: list[dict[str, int]] = []
        for b in batches:
            if ctx_val < 8192 and b > 1024:
                continue
            if ctx_val < 16384 and b > 1536:
                continue
            for u in ubatches:
                if u > b:
                    continue
                for p in parallels:
                    if ctx_val < 16384 and p > 1:
                        continue
                    if ctx_val < 32768 and p > 2:
                        continue
                    out.append({"batch": b, "ubatch": u, "parallel": p, "fit": _fit_for_batch(b)})
        return out

    def _anchor_combos(space: list[dict[str, int]]) -> list[dict[str, int]]:
        wanted = {
            (512, 128, 1),
            (1024, 256, 1),
            (1024, 512, 1),
            (512, 128, 2),
            (1536, 512, 1),
        }
        anchors = [c for c in space if _combo_key(c) in wanted]
        if anchors:
            return anchors
        return space[: min(4, len(space))]

    def _neighbors(combo: dict[str, int], space: list[dict[str, int]]) -> list[dict[str, int]]:
        by_key = {_combo_key(c): c for c in space}
        batches = sorted({c["batch"] for c in space})
        ubatches = sorted({c["ubatch"] for c in space})
        parallels = sorted({c["parallel"] for c in space})

        def _adj(values: list[int], cur: int) -> list[int]:
            if cur not in values:
                return []
            i = values.index(cur)
            out_i = []
            if i > 0:
                out_i.append(values[i - 1])
            if i + 1 < len(values):
                out_i.append(values[i + 1])
            return out_i

        candidate_keys: set[tuple[int, int, int]] = set()
        for nb in _adj(batches, combo["batch"]):
            candidate_keys.add((nb, combo["ubatch"], combo["parallel"]))
        for nu in _adj(ubatches, combo["ubatch"]):
            candidate_keys.add((combo["batch"], nu, combo["parallel"]))
        for np in _adj(parallels, combo["parallel"]):
            candidate_keys.add((combo["batch"], combo["ubatch"], np))

        # One diagonal move helps jump from conservative to higher-throughput
        # candidates without evaluating the entire grid.
        for nb in _adj(batches, combo["batch"]):
            for nu in _adj(ubatches, combo["ubatch"]):
                candidate_keys.add((nb, nu, combo["parallel"]))

        out: list[dict[str, int]] = []
        for k in candidate_keys:
            c = by_key.get(k)
            if c is not None:
                out.append(c)
        return out

    def _run_param_tuning(ctx_val: int, profile: dict[str, str]) -> tuple[dict[str, int], float, int, int, list[dict[str, int]]]:
        space = _candidate_space(ctx_val)
        if not space:
            return (dict(CONSERVATIVE), 0.0, 0, 0, [])

        seen: set[tuple[int, int, int]] = set()
        records: dict[tuple[int, int, int], dict[str, float | dict[str, int]]] = {}
        load_fail_local = 0
        ok_local = 0

        def _eval(combo: dict[str, int], warmup: bool = False) -> None:
            nonlocal load_fail_local
            nonlocal ok_local

            key = _combo_key(combo)
            if key in seen:
                return
            seen.add(key)

            print(f"  {ctx_val:,}  b={combo['batch']}/{combo['ubatch']}  p={combo['parallel']} → ", end="", flush=True)
            status, tps_vals = test_config_with_retry(
                model_path,
                ctx_val,
                combo["batch"],
                combo["ubatch"],
                combo["parallel"],
                profile["mmap"],
                flash_attn=profile["flash_attn"],
                warmup=warmup,
                samples=max(1, TPS_SAMPLES_PARAM),
                burn_tokens=BURN_TOKENS_SCORE,
                retries=1,
            )
            if status != "ok" or not tps_vals:
                if status == "load_fail":
                    load_fail_local += 1
                print(f"✗ ({status})", flush=True)
                return

            ok_local += 1
            median_tps = stable_tps(tps_vals)
            score = stable_score(tps_vals, penalty=stability_penalty)
            spread = max(tps_vals) - min(tps_vals) if len(tps_vals) > 1 else 0.0
            print(f"{median_tps:.1f} tps (score {score:.1f}, spread {spread:.1f})", flush=True)
            records[key] = {
                "combo": combo,
                "score": float(score),
                "tps": float(median_tps),
            }

        def _top_beam() -> list[dict[str, int]]:
            ranked = sorted(
                records.values(),
                key=lambda r: (float(r["score"]), float(r["tps"])),
                reverse=True,
            )
            return [dict(r["combo"]) for r in ranked[:beam_width]]

        anchors = _anchor_combos(space)
        for i, combo in enumerate(anchors):
            _eval(combo, warmup=(i == 0))

        beam = _top_beam()
        for _ in range(beam_rounds):
            if not beam:
                break
            frontier: list[dict[str, int]] = []
            for combo in beam:
                for ncombo in _neighbors(combo, space):
                    if _combo_key(ncombo) not in seen:
                        frontier.append(ncombo)
            if not frontier:
                break
            for combo in frontier:
                _eval(combo)
            next_beam = _top_beam()
            if {_combo_key(c) for c in next_beam} == {_combo_key(c) for c in beam}:
                break
            beam = next_beam

        if not records:
            return (dict(CONSERVATIVE), 0.0, load_fail_local, ok_local, space)

        best = sorted(
            records.values(),
            key=lambda r: (float(r["score"]), float(r["tps"])),
            reverse=True,
        )[0]
        best_combo_local = dict(best["combo"])
        best_tps_local = float(best["tps"])
        return (best_combo_local, best_tps_local, load_fail_local, ok_local, space)

    print(f"  ── param tuning ──")
    best_combo, best_combo_tps, load_fail_count, ok_count, pruned = _run_param_tuning(discovered_ctx, selected_profile)

    # If refinement selected an unstable edge profile/ctx (all combos failed to
    # start), fall back once to the discovery profile which was known-good.
    if ok_count == 0 and load_fail_count == len(pruned) and selected_profile != discovery_profile:
        print(f"  all combos load_fail at selected profile — falling back to discovery profile")
        selected_profile = discovery_profile
        discovered_ctx = max_stable_ctx
        best_combo, best_combo_tps, load_fail_count, ok_count, pruned = _run_param_tuning(discovered_ctx, selected_profile)

    print()
    best_batch    = best_combo["batch"]
    best_ubatch   = best_combo["ubatch"]
    best_parallel = best_combo["parallel"]
    best_mmap     = selected_profile["mmap"]

    # ── Phase 4: TPS floor — downshift ctx if too slow ──────────────────
    tuned_ctx = discovered_ctx
    if best_combo_tps < min_tps:
        print(f"  TPS {best_combo_tps:.1f} below floor {min_tps:.1f} at ctx {discovered_ctx:,} — downshifting ctx")
    while best_combo_tps < min_tps and tuned_ctx > floor:
        next_ctx = max(floor, (int(tuned_ctx * 0.75) // 512) * 512)
        if next_ctx >= tuned_ctx:
            next_ctx = max(floor, tuned_ctx - 512)
        tuned_ctx = next_ctx
        kill_zombie_servers()
        local_best_tps   = 0.0
        local_best_combo = best_combo
        for combo in _candidate_space(tuned_ctx):
            status, tps_vals = test_config_with_retry(
                model_path, tuned_ctx,
                combo["batch"], combo["ubatch"], combo["parallel"],
                selected_profile["mmap"],
                flash_attn=selected_profile["flash_attn"],
                samples=max(1, TPS_SAMPLES_PARAM),
                burn_tokens=BURN_TOKENS_SCORE,
                retries=1,
            )
            if status == "ok" and tps_vals:
                score = stable_tps(tps_vals)
                if score < local_best_tps:
                    continue
                local_best_tps   = score
                local_best_combo = combo
        best_combo_tps = local_best_tps
        best_combo     = local_best_combo
        best_batch     = best_combo["batch"]
        best_ubatch    = best_combo["ubatch"]
        best_parallel  = best_combo["parallel"]
        print(f"  ctx {tuned_ctx:,} -> best {best_combo_tps:.1f} tps")

    discovered_ctx = tuned_ctx
    if best_combo_tps < min_tps:
        print(f"  WARN: No configuration met min TPS floor {min_tps:.1f}; marking row as not autotuned")
        autotuned_flag = "no"
    else:
        autotuned_flag = "yes"

    # ── Phase 5: Registry writeback ─────────────────────────────────────
    print(f"  {_line}")
    print(f"  ✓ ctx {discovered_ctx}  b {best_batch}/{best_ubatch}  p{best_parallel}  mmap={best_mmap}  fa={selected_profile['flash_attn']}  {best_combo_tps:.1f} tps")
    print(f"  {_line}")
    print()

    write_registry_row(args.row, {
        "ctx": discovered_ctx,
        "batch": best_batch,
        "ubatch": best_ubatch,
        "parallel": best_parallel,
        "mmap_mode": best_mmap,
        "flash_attn": selected_profile["flash_attn"],
        "tps": f"{best_combo_tps:.1f}",
        "autotuned": autotuned_flag,
    })

    print(f"    Registry row {args.row}: autotuned={autotuned_flag}")
    print()

    if autotuned_flag != "yes":
        sys.exit(2)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n  Interrupted by user")
        sys.exit(130)
