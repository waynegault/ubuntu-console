"""The consecutive-stall chain belongs to a ROW, not to the boot.

Measured 2026-11-23 in ubuntu-console: the 120B's three readiness timeouts filled
`/dev/shm/autotune-degrade-stalls-<boot>`, and the very next row — Calme-4x7B, 13.6G,
never tried — exited 3 at 8/60 with no load attempted and the ledger unmoved.  The
counter is boot-scoped, so the chain outlived the row that earned it and refused work
that had not been shown to fail.

What the case would catch: a row start that inherits a full chain and refuses before its
first launch.  It drives the real script under AUTOTUNE_SELFTEST (canned curves, no
server, no lane stand-down) against a throwaway HOME, so it needs no model store and
writes nothing outside tmp_path.
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = REPO_ROOT / "scripts" / "autotune-model.sh"
CONSTANTS = REPO_ROOT / "scripts" / "01-constants.sh"


def _registry_header() -> str:
    """The one header definition, so the fixture row has the live column count."""
    res = subprocess.run(
        [
            "bash",
            "-c",
            f"source '{CONSTANTS}' >/dev/null 2>&1; printf '%s' \"$LLM_REGISTRY_HEADER\"",
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    return res.stdout


def _stub_pkill(tmp_path: Path) -> Path:
    """A no-op `pkill`: the script kills local embedding workers unconditionally.

    A test must not tear down a live worker, and the kill is a real side effect rather
    than the behaviour under test, so the command is stubbed for the run.
    """
    stub = tmp_path / "bin"
    stub.mkdir()
    pkill = stub / "pkill"
    pkill.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    pkill.chmod(0o755)
    return stub


def test_a_full_stall_chain_does_not_refuse_the_next_row(tmp_path: Path) -> None:
    (tmp_path / "models" / "active").mkdir(parents=True)
    # The store is derived from $HOME by the host profile, which clears an inherited
    # LLAMA_MODEL_DIR, so a throwaway HOME is what makes this hermetic.
    (tmp_path / "models" / "active" / "dummy.gguf").write_bytes(b"GGUF" + b"\x00" * 2048)

    registry = tmp_path / "models.conf"
    registry.write_text(
        _registry_header()
        + "\n"
        + "1|Dummy|dummy.gguf|0.0G|Q4_K_M/q8_0/q8_0|qwen2|999|32768|6|1024|256|1|256"
        + "|native|auto|on|0|no|no|no\n",
        encoding="utf-8",
    )
    stalls = tmp_path / "stalls"
    stalls.write_text("3\n", encoding="utf-8")
    cycles = tmp_path / "cycles"
    cycles.write_text("0\n", encoding="utf-8")
    stub = _stub_pkill(tmp_path)

    env = {
        **os.environ,
        "HOME": str(tmp_path),
        "PATH": f"{stub}:{os.environ['PATH']}",
        "AUTOTUNE_SELFTEST": "1",
        "CUDA_STALL_FILE": str(stalls),
        "CUDA_CYCLE_FILE": str(cycles),
        "LLAMA_WATCHDOG_CUDA_SUSPEND_FILE": str(tmp_path / "suspend"),
        "TAC_TEST_TMPDIR": str(tmp_path),
        "TAC_DMESG_BIN": "/bin/true",
        "LLM_REGISTRY": str(registry),
        "LLM_STATE_DIR": str(tmp_path / ".llm"),
    }
    res = subprocess.run(
        ["bash", str(SCRIPT), "1"],
        env=env,
        capture_output=True,
        text=True,
        check=False,
        timeout=300,
    )
    output = res.stdout + res.stderr

    # Pre-fix this refused with exit 3 on the chain the previous row left behind.
    assert "consecutive launches stalled" not in output, output[-2000:]
    assert res.returncode == 0, output[-2000:]
    # A reset, not a bypass: the new row starts from an empty chain.
    assert stalls.read_text(encoding="utf-8").strip() in ("", "0")
