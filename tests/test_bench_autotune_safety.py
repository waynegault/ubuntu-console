"""Hermetic tests for autotune and bench safety fixes."""

from __future__ import annotations

import os
import shutil
import stat
import subprocess
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent


def _run_bash(script: str, *, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    run_env = os.environ.copy()
    if env is not None:
        run_env.update(env)
    return subprocess.run(
        ["bash", "-c", script],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="strict",
        timeout=30,
        env=run_env,
        check=False,
    )


def test_model_autotune_clean_room_does_not_force_contended_by_default(tmp_path: Path) -> None:
    """Quiet `model autotune` leaves TAC_CONTENDED unset so quiet runs certify."""
    stub_dir = tmp_path / "stub"
    stub_dir.mkdir()
    wrapper = stub_dir / "rows.sh"
    wrapper.write_text(
        '#!/usr/bin/env bash\nprintf "wl=%s cont=%s args=%s\\n" "$LLM_AUTOTUNE_WORKLOAD" "${TAC_CONTENDED-<unset>}" "$*"\n',
        encoding="utf-8",
    )
    wrapper.chmod(0o755)

    env = os.environ.copy()
    env.pop("TAC_CONTENDED", None)
    env["STUB_DIR"] = str(stub_dir)

    script = f"""
source "{REPO_ROOT}/scripts/11e-llm-model.sh" >/dev/null 2>&1
__autotune_script_path() {{ printf "%s/rows.sh\\n" "$STUB_DIR"; }}
__model_autotune_clean_room 3 --workload chat
"""
    res = subprocess.run(
        ["bash", "-c", script],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="strict",
        timeout=15,
        env=env,
        check=False,
    )
    assert res.returncode == 0, res.stderr
    assert res.stdout.strip() == "wl=chat cont=<unset> args=3"


def test_model_autotune_clean_room_passes_contended_when_flag_given(tmp_path: Path) -> None:
    """Explicit `--allow-contended` still exports TAC_CONTENDED=1."""
    stub_dir = tmp_path / "stub"
    stub_dir.mkdir()
    wrapper = stub_dir / "rows.sh"
    wrapper.write_text(
        '#!/usr/bin/env bash\nprintf "wl=%s cont=%s args=%s\\n" "$LLM_AUTOTUNE_WORKLOAD" "${TAC_CONTENDED-<unset>}" "$*"\n',
        encoding="utf-8",
    )
    wrapper.chmod(0o755)

    env = os.environ.copy()
    env.pop("TAC_CONTENDED", None)
    env["STUB_DIR"] = str(stub_dir)

    script = f"""
source "{REPO_ROOT}/scripts/11e-llm-model.sh" >/dev/null 2>&1
__autotune_script_path() {{ printf "%s/rows.sh\\n" "$STUB_DIR"; }}
__model_autotune_clean_room 3 --workload legal --allow-contended
"""
    res = subprocess.run(
        ["bash", "-c", script],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="strict",
        timeout=15,
        env=env,
        check=False,
    )
    assert res.returncode == 0, res.stderr
    assert res.stdout.strip() == "wl=legal cont=1 args=3"


def test_direct_model_bench_respects_global_heavy_job_lock(tmp_path: Path) -> None:
    """Direct `__model_bench` refuses (rc=3) when HEAVY_JOB_LOCK is held by another process."""
    heavy_lock = tmp_path / "heavy-job.lock"
    registry = tmp_path / "models.conf"
    registry.write_text("1|test|test.gguf|1G|Q4|llama|4096|4096|99|512|128|1|128|native|1|1|50|yes\n", encoding="utf-8")

    # Hold heavy-job.lock in a background process until we terminate it.
    holder = subprocess.Popen(
        ["flock", "-x", str(heavy_lock), "sleep", "30"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        # Wait briefly for flock to acquire the lock.
        time.sleep(0.15)
        env = os.environ.copy()
        env.pop("HEAVY_JOB_HELD", None)
        env.update(
            {
                "HEAVY_JOB_LOCK": str(heavy_lock),
                "LLM_BENCH_HEAVY_LOCK_WAIT_SECONDS": "1",
                "LLM_REGISTRY": str(registry),
                "LLM_BENCH_PID_FILE": str(tmp_path / "bench.pid"),
                "LLM_BENCH_LOCK_FILE": str(tmp_path / "bench.lock"),
            }
        )
        script = f"""
source "{REPO_ROOT}/scripts/11e-llm-model.sh" >/dev/null 2>&1
__tac_info() {{ printf '%s: %s\\n' "$1" "$2"; }}
__tac_cleanup_stale_locks() {{ return 0; }}
_tac_adapter_health_check() {{ return 0; }}
__model_bench 1
"""
        res = subprocess.run(
            ["bash", "-c", script],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="strict",
            timeout=15,
            env=env,
            check=False,
        )
        assert res.returncode == 3, (
            f"expected rc=3 on busy heavy-job lock, got {res.returncode}: {res.stdout} {res.stderr}"
        )
        assert "Heavy-job lock still busy" in res.stdout
    finally:
        holder.terminate()
        holder.wait(timeout=5)


def test_model_bench_unwritable_state_dir_reports_error_not_saved(tmp_path: Path) -> None:
    """Failed TSV writes must return non-zero, print an error, and never print Saved."""
    ro_state = tmp_path / "ro_state"
    ro_state.mkdir()
    models_dir = tmp_path / "models"
    models_dir.mkdir()
    (models_dir / "test.gguf").write_bytes(b"GGUF")
    registry = tmp_path / "models.conf"
    registry.write_text(
        "1|TestModel|test.gguf|1.0G|Q4_K_M|llama|4096|4096|99|512|128|1|128|native|1|1|50.0|yes\n",
        encoding="utf-8",
    )
    ro_state.chmod(stat.S_IRUSR | stat.S_IXUSR)
    try:
        env = os.environ.copy()
        env.update(
            {
                "HEAVY_JOB_HELD": "1",
                "LLM_REGISTRY": str(registry),
                "LLAMA_MODEL_DIR": str(models_dir),
                "LLM_STATE_DIR": str(ro_state),
                "TAC_CACHE_DIR": str(tmp_path / "cache"),
                "LLM_BENCH_PID_FILE": str(tmp_path / "bench.pid"),
                "LLM_BENCH_LOCK_FILE": str(tmp_path / "bench.lock"),
                "LLM_BENCH_WATCHDOG_TIMER": "nonexistent-test-timer.timer",
                "LLAMA_WATCHDOG_CUDA_SUSPEND_FILE": str(tmp_path / "cuda.suspend"),
                "LLM_BENCH_COOLDOWN_SEC": "0",
                "LLM_TPS_CACHE": str(tmp_path / "tps.cache"),
                "LLM_WINDOW_MISMATCH_CACHE": str(tmp_path / "win.cache"),
                "LLM_LOG_FILE": str(tmp_path / "llama.log"),
                "UIWidth": "80",
            }
        )
        script = f"""
source "{REPO_ROOT}/scripts/11e-llm-model.sh" >/dev/null 2>&1
__tac_info() {{ printf '%s: %s\\n' "$1" "$2"; }}
__tac_header() {{ :; }}
__tac_footer() {{ :; }}
__tac_cleanup_stale_locks() {{ return 0; }}
_tac_adapter_health_check() {{ return 0; }}
_tac_suspend_acquire() {{ return 0; }}
_tac_suspend_release() {{ return 0; }}
_tac_cleanroom_enter() {{ return 0; }}
_tac_cleanroom_restore() {{ return 0; }}
__llm_backend_normalize() {{ printf '%s\\n' "${{1:-native}}"; }}
__llm_autotune_done_for_model() {{ return 0; }}
__llm_quant_rating() {{ printf 'good\\n'; }}
__llm_health_timeout() {{ printf '30\\n'; }}
__llm_burn_request_timeout() {{ printf '30\\n'; }}
__bench_build_identity() {{ printf 'drv\\tcuda\\tbuild\\tarch\\n'; }}
__model_stop() {{ return 0; }}
__bench_run_with_timeout() {{ printf '42.0' > "$LLM_TPS_CACHE"; return 0; }}
__model_bench 1
"""
        res = subprocess.run(
            ["bash", "-c", script],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="strict",
            timeout=20,
            env=env,
            check=False,
        )
        assert res.returncode == 1, f"expected rc=1 on unwritable state dir, got {res.returncode}: {res.stdout}"
        assert "Failed to save benchmark TSV" in res.stdout
        assert "Saved:" not in res.stdout
        assert list(ro_state.iterdir()) == []
    finally:
        ro_state.chmod(stat.S_IRWXU)


def test_worktree_wrappers_use_their_own_checkout(tmp_path: Path) -> None:
    """`bin/autotune-rows.sh` and `bin/bench-rows.sh` resolve REPO and bin/tac-exec from their own tree."""
    wt = tmp_path / "worktree"
    (wt / "bin").mkdir(parents=True)
    (wt / "scripts").mkdir(parents=True)
    state_dir = tmp_path / "state"
    state_dir.mkdir()

    shutil.copy2(REPO_ROOT / "bin" / "autotune-rows.sh", wt / "bin" / "autotune-rows.sh")
    shutil.copy2(REPO_ROOT / "bin" / "bench-rows.sh", wt / "bin" / "bench-rows.sh")
    shutil.copy2(REPO_ROOT / "bin" / "_tac-bin-lib.sh", wt / "bin" / "_tac-bin-lib.sh")

    # Minimal stub 01-constants.sh inside the worktree to prove it is sourced from wt, not canonical REPO.
    (wt / "scripts" / "01-constants.sh").write_text(
        f'export LLM_STATE_DIR="{state_dir}"\n'
        'export LLAMA_CUDA_LANE_UNIT="test-lane.service"\n'
        'export TAC_HOST_PRIMARY_LANE="test-lane.service"\n'
        'export _WT_CONSTANTS_LOADED="yes"\n',
        encoding="utf-8",
    )

    # Stub bin/tac-exec inside the worktree to record that bench-rows.sh invokes THIS checkout's tac-exec.
    tac_exec_marker = tmp_path / "tac-exec.called"
    wt_tac_exec = wt / "bin" / "tac-exec"
    wt_tac_exec.write_text(
        f'#!/usr/bin/env bash\nprintf "repo=%s args=%s\\n" "$PWD" "$*" > "{tac_exec_marker}"\nexit 0\n',
        encoding="utf-8",
    )
    wt_tac_exec.chmod(0o755)

    # Stub scripts/run-autotune-batch.sh inside the worktree.
    batch_marker = tmp_path / "batch.called"
    wt_batch = wt / "scripts" / "run-autotune-batch.sh"
    wt_batch.write_text(
        f'#!/usr/bin/env bash\nprintf "repo=%s args=%s\\n" "$PWD" "$*" > "{batch_marker}"\nexit 0\n',
        encoding="utf-8",
    )
    wt_batch.chmod(0o755)

    # Override hardware-touching helpers in the worktree's _tac-bin-lib.sh.
    with (wt / "bin" / "_tac-bin-lib.sh").open("a", encoding="utf-8") as fh:
        fh.write(
            "\n_tac_suspend_acquire() { return 0; }\n"
            "_tac_suspend_release() { return 0; }\n"
            "_tac_cleanroom_enter() { return 0; }\n"
            "_tac_cleanroom_restore() { return 0; }\n"
            "_tac_gpu_wait_baseline() { printf 'verdict=pass\\n'; return 0; }\n"
            "_tac_gpu_used_mib() { printf '0\\n'; }\n"
            "_tac_cuda_lane_unit() { printf 'test-lane.service\\n'; }\n"
            "_tac_is_retired() { return 1; }\n"
            "_tac_retired_reason() { return 1; }\n"
        )

    gate = tmp_path / "gate-ok"
    gate.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    gate.chmod(0o755)

    env = os.environ.copy()
    env.pop("REPO", None)
    env.update(
        {
            "HEAVY_JOB_HELD": "1",
            "AUTOTUNE_QUIET_GATE": str(gate),
            "CUDA_CYCLE_FILE": str(tmp_path / "ledger"),
            "LLAMA_WATCHDOG_CUDA_SUSPEND_FILE": str(tmp_path / "suspend"),
            "BENCH_RESUME_PLAN": str(tmp_path / "bench-resume.rows"),
        }
    )

    res_at = subprocess.run(
        ["bash", str(wt / "bin" / "autotune-rows.sh"), "test.gguf"],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="strict",
        timeout=20,
        env=env,
        check=False,
    )
    assert res_at.returncode == 0, f"autotune-rows failed: {res_at.stdout} {res_at.stderr}"
    assert batch_marker.read_text(encoding="utf-8").strip() == f"repo={wt.resolve()} args=test.gguf"

    res_bench = subprocess.run(
        ["bash", str(wt / "bin" / "bench-rows.sh"), "test.gguf"],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="strict",
        timeout=20,
        env=env,
        check=False,
    )
    assert res_bench.returncode == 0, f"bench-rows failed: {res_bench.stdout} {res_bench.stderr}"
    assert tac_exec_marker.read_text(encoding="utf-8").strip() == f"repo={wt.resolve()} args=model bench test.gguf"
