"""Unit tests for WSL2 dxgkrnl health checks and restart/autotune safeguards."""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
TAC_BIN_LIB = REPO_ROOT / "bin" / "_tac-bin-lib.sh"
WSL_RESTART = REPO_ROOT / "bin" / "wsl-restart.sh"


def test_tac_dxg_health_check_healthy(tmp_path: Path) -> None:
    """_tac_dxg_health_check returns 0 when dmesg reports no critical errors or benign EINVAL."""
    fake_dmesg = tmp_path / "fake_dmesg"
    fake_dmesg.write_text(
        "#!/bin/sh\n"
        "echo '[   12.345] dxgkrnl: query adapter info failed: -22'\n"
        "echo '[   12.346] Normal kernel log line'\n",
        encoding="utf-8",
    )
    fake_dmesg.chmod(0o755)

    cmd = f"source '{TAC_BIN_LIB}' && TAC_DMESG_BIN='{fake_dmesg}' _tac_dxg_health_check"
    res = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True, check=False)
    assert res.returncode == 0
    assert res.stdout.strip() == ""


@pytest.mark.parametrize(
    "log_line,expected_pat",
    [
        (
            "[  124.789] dxgkrnl: dxgk_reserve_gpu_virtual_address failed: -75",
            "-75",
        ),
        (
            "[  124.789] dxgkrnl: dxgk_reserve_gpu_virtual_address failed: -12",
            "-12",
        ),
        (
            "[  125.000] dxgkrnl: wait_for_completion_interruptible_timeout failed",
            "wait_for_completion",
        ),
    ],
)
def test_tac_dxg_health_check_flags_critical_errors(tmp_path: Path, log_line: str, expected_pat: str) -> None:
    """_tac_dxg_health_check returns 1 and prints critical dxgkrnl bridge failures."""
    fake_dmesg = tmp_path / "fake_dmesg"
    fake_dmesg.write_text(
        f"#!/bin/sh\necho '[   12.345] dxgkrnl: query adapter info failed: -22'\necho '{log_line}'\n",
        encoding="utf-8",
    )
    fake_dmesg.chmod(0o755)

    cmd = f"source '{TAC_BIN_LIB}' && TAC_DMESG_BIN='{fake_dmesg}' _tac_dxg_health_check"
    res = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True, check=False)
    assert res.returncode == 1
    assert expected_pat in res.stdout


def test_tac_dxg_health_check_missing_binary(tmp_path: Path) -> None:
    """When the dmesg binary is absent, _tac_dxg_health_check gracefully returns 0."""
    nonexistent = tmp_path / "no_such_dmesg"
    cmd = f"source '{TAC_BIN_LIB}' && TAC_DMESG_BIN='{nonexistent}' _tac_dxg_health_check"
    res = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True, check=False)
    assert res.returncode == 0


def test_wsl_restart_dry_run_includes_vmmem_poll() -> None:
    """wsl-restart.sh --dry-run outputs vmmemWSL.exe teardown wait in shutdown step."""
    res = subprocess.run(
        [str(WSL_RESTART), "--dry-run"],
        capture_output=True,
        text=True,
        check=False,
    )
    assert res.returncode == 0
    assert 'tasklist /fi "IMAGENAME eq vmmemWSL.exe"' in res.stdout
    assert ":wait_vmmem_down" in res.stdout
    assert ":vmmem_down" in res.stdout


def test_wsl_restart_admin_lock_fallback(tmp_path: Path) -> None:
    """When default task is locked by Admin, falls back to tac-wsl-restart-user for arm/status/unschedule."""
    user_created = tmp_path / "user_created"
    argv_log = tmp_path / "schtasks.argv"
    fake_schtasks = tmp_path / "schtasks"
    fake_schtasks.write_text(
        "#!/bin/sh\n"
        f"printf '%s\\n' \"$*\" >> '{argv_log}'\n"
        'case "$*" in\n'
        '  *"/query /tn tac-wsl-restart "*)\n'
        "    echo 'TaskName: \\tac-wsl-restart'\n"
        "    echo 'Next Run Time: N/A'\n"
        "    echo 'Status: Ready'\n"
        "    exit 0 ;;\n"
        '  *"/delete /f /tn tac-wsl-restart-user"*)\n'
        f"    rm -f '{user_created}'\n"
        "    exit 0 ;;\n"
        '  *"/delete /f /tn tac-wsl-restart"*)\n'
        "    echo 'ERROR: Access is denied.' >&2\n"
        "    exit 1 ;;\n"
        '  *"/create "*"/tn tac-wsl-restart-user"*)\n'
        f"    : > '{user_created}'\n"
        "    exit 0 ;;\n"
        '  *"/query /tn tac-wsl-restart-user"*)\n'
        f"    if [ -f '{user_created}' ]; then\n"
        "      echo 'TaskName: \\tac-wsl-restart-user'\n"
        "      echo 'Next Run Time: 15/10/2026 23:59:00'\n"
        "      echo 'Status: Ready'\n"
        "      exit 0\n"
        "    fi\n"
        "    echo 'ERROR: The system cannot find the file specified.' >&2\n"
        "    exit 1 ;;\n"
        "  *)\n"
        "    exit 0 ;;\n"
        "esac\n",
        encoding="utf-8",
    )
    fake_schtasks.chmod(0o755)

    code_cmd = tmp_path / "code.cmd"
    code_cmd.write_text("@echo off\n", encoding="utf-8")
    gate_cmd = tmp_path / "gate.sh"
    gate_cmd.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    gate_cmd.chmod(0o755)
    fleet_cmd = tmp_path / "fleet.sh"
    fleet_cmd.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    fleet_cmd.chmod(0o755)

    env = {
        "HOME": str(tmp_path),
        "PATH": f"{tmp_path}:/usr/bin:/bin",
        "TAC_WSL_RESTART_SCHTASKS": str(fake_schtasks),
        "TAC_WSL_RESTART_CODE_CMD_UNIX": str(code_cmd),
        "TAC_WSL_RESTART_GATE_CMD": str(gate_cmd),
        "TAC_WSL_RESTART_FLEET_CMD": str(fleet_cmd),
        "TAC_WSL_RESTART_WRAPPER_UNIX": str(tmp_path / "action.cmd"),
        "TAC_WSL_RESTART_PROMPT_UNIX": str(tmp_path / "prompt.ps1"),
        "TAC_WSL_RESTART_LOG_UNIX": str(tmp_path / "action.log"),
        "TAC_WSL_RESTART_ARM_LOG": str(tmp_path / "arms.log"),
    }

    # 1. Precondition failure must not touch schtasks (must not delete an existing task).
    bad_env = {**env, "TAC_WSL_RESTART_CODE_CMD_UNIX": str(tmp_path / "missing-code.cmd")}
    res_pre = subprocess.run(
        [str(WSL_RESTART), "--restart", "--delay", "5"],
        env=bad_env,
        capture_output=True,
        text=True,
        check=False,
    )
    assert res_pre.returncode == 1
    assert not argv_log.exists()

    # 2. Admin-locked tac-wsl-restart warns on existing registration, then falls back.
    res_arm = subprocess.run(
        [str(WSL_RESTART), "--restart", "--delay", "5"],
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    assert res_arm.returncode == 0, res_arm.stderr
    assert "a tac-wsl-restart registration already exists" in res_arm.stderr
    assert "Switching to user-scoped task name 'tac-wsl-restart-user'" in res_arm.stderr
    assert "armed: tac-wsl-restart-user fires at" in res_arm.stderr
    assert "schtasks.exe /delete /f /tn tac-wsl-restart-user" in (tmp_path / "action.cmd").read_text(encoding="utf-8")

    # 3. --status sees the armed tac-wsl-restart-user fallback task (exit 1).
    res_st = subprocess.run(
        [str(WSL_RESTART), "--status"],
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    assert res_st.returncode == 1, res_st.stderr
    assert "ARMED (tac-wsl-restart-user)" in res_st.stderr

    # 4. --unschedule removes tac-wsl-restart-user cleanly even when tac-wsl-restart is locked.
    res_un = subprocess.run(
        [str(WSL_RESTART), "--unschedule"],
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    assert res_un.returncode == 0, res_un.stderr
    assert "removed: no tac-wsl-restart-user registration remains" in res_un.stderr
    assert not user_created.exists()
