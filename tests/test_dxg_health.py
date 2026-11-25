"""Unit tests for WSL2 dxgkrnl health checks and restart/autotune safeguards."""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
TAC_BIN_LIB = REPO_ROOT / "bin" / "_tac-bin-lib.sh"
WSL_RESTART = REPO_ROOT / "bin" / "wsl-restart.sh"


def _fake_bin(tmp_path: Path, name: str, body: str) -> Path:
    path = tmp_path / name
    path.write_text(f"#!/bin/sh\n{body}", encoding="utf-8")
    path.chmod(0o755)
    return path


def _fake_dmesg(tmp_path: Path, *lines: str) -> Path:
    return _fake_bin(tmp_path, "fake_dmesg", "".join(f"echo '{line}'\n" for line in lines))


def _fake_journalctl(tmp_path: Path, load_monotonic: str | None) -> Path:
    """A journalctl stand-in. `None` writes no `model loaded` line at all."""
    body = ""
    if load_monotonic is not None:
        body = f"echo '[{load_monotonic}] host llama-cuda-server[1]: 0.00.1 I srv  server_run_i: model loaded'\n"
    return _fake_bin(tmp_path, "fake_journalctl", body)


def _run_gate(dmesg: Path, journalctl: Path) -> subprocess.CompletedProcess[str]:
    cmd = (
        f"source '{TAC_BIN_LIB}'"
        f" && TAC_DMESG_BIN='{dmesg}'"
        f" && TAC_JOURNALCTL_BIN='{journalctl}'"
        " && _tac_dxg_health_check"
    )
    return subprocess.run(["bash", "-c", cmd], capture_output=True, text=True, check=False)


def test_tac_dxg_health_check_healthy(tmp_path: Path) -> None:
    """_tac_dxg_health_check returns 0 when dmesg reports no critical errors or benign EINVAL."""
    dmesg = _fake_dmesg(
        tmp_path,
        "[   12.345] dxgkrnl: query adapter info failed: -22",
        "[   12.346] Normal kernel log line",
    )
    res = _run_gate(dmesg, _fake_journalctl(tmp_path, None))
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
    """A critical line NEWER than the last successful load is still refused.

    The load stamp is 10.0, so the 124.789 failure is current — the case this gate
    exists for.
    """
    dmesg = _fake_dmesg(
        tmp_path,
        "[   12.345] dxgkrnl: query adapter info failed: -22",
        log_line,
    )
    res = _run_gate(dmesg, _fake_journalctl(tmp_path, "10.000000"))
    assert res.returncode == 1
    assert expected_pat in res.stdout


def test_tac_dxg_health_check_missing_binary(tmp_path: Path) -> None:
    """When the dmesg binary is absent, _tac_dxg_health_check gracefully returns 0."""
    nonexistent = tmp_path / "no_such_dmesg"
    res = _run_gate(nonexistent, _fake_journalctl(tmp_path, None))
    assert res.returncode == 0


def test_a_critical_line_superseded_by_a_later_load_is_not_current(tmp_path: Path) -> None:
    """A -12 older than a successful load does not describe the adapter's state now.

    Catches the 2026-11-23 halt: one `create_allocation: -12` from 16:47 refused the
    whole 17:39 sweep at preflight — nothing was attempted — while two lanes loaded
    cleanly at 17:41.  On the pre-fix gate this returned 1 and printed the stale line.
    """
    dmesg = _fake_dmesg(
        tmp_path,
        "[13909.570765] misc dxg: dxgk: dxgkio_create_allocation: Ioctl failed: -12",
    )
    res = _run_gate(dmesg, _fake_journalctl(tmp_path, "17120.975292"))
    assert res.returncode == 0, res.stdout
    assert res.stdout.strip() == ""


def test_a_critical_line_with_no_known_load_is_still_refused(tmp_path: Path) -> None:
    """No load in the journal supersedes nothing: refuse rather than assume healthy."""
    dmesg = _fake_dmesg(
        tmp_path,
        "[13909.570765] misc dxg: dxgk: dxgkio_create_allocation: Ioctl failed: -12",
    )
    res = _run_gate(dmesg, _fake_journalctl(tmp_path, None))
    assert res.returncode == 1
    assert "create_allocation" in res.stdout


def test_a_critical_line_with_an_unreadable_stamp_is_refused(tmp_path: Path) -> None:
    """A stamp that cannot be parsed must not be silently promoted to 'stale'."""
    dmesg = _fake_dmesg(tmp_path, "misc dxg: dxgkio_create_allocation: Ioctl failed: -12")
    res = _run_gate(dmesg, _fake_journalctl(tmp_path, "17120.975292"))
    assert res.returncode == 1
    assert "-12" in res.stdout


def test_witnessed_oom_stamp_supersedes_enomem_12_but_never_75_or_timeouts(tmp_path: Path) -> None:
    """Row 4 beam-search regression (2026-11-25): a candidate cudaMalloc OOM writes
    `dxgkio_make_resident: Ioctl failed: -12` into dmesg with no subsequent journalctl load.

    Stamping TAC_DXG_OOM_STAMP_FILE via _tac_dxg_record_oom_refusal must clear -12 lines
    up to that monotonic timestamp while still refusing:
      - -12 lines NEWER than the OOM watermark (unwitnessed failure),
      - -75 (EOVERFLOW) and wait_for_completion timeouts regardless of the OOM watermark.
    """
    uptime = tmp_path / "uptime"
    uptime.write_text("35120.50 600000.00\n", encoding="utf-8", errors="strict")
    oom_stamp = tmp_path / "oom.ts"
    no_journal = _fake_journalctl(tmp_path, None)

    dmesg_oom_12 = _fake_dmesg(
        tmp_path,
        "[35095.875190] misc dxg: dxgk: dxgkio_make_resident: Ioctl failed: -12",
        "[35119.142438] misc dxg: dxgk: dxgkio_make_resident: Ioctl failed: -12",
    )
    cmd_ok = (
        f"source '{TAC_BIN_LIB}'"
        f" && TAC_UPTIME_FILE='{uptime}'"
        f" && TAC_DXG_OOM_STAMP_FILE='{oom_stamp}'"
        " && _tac_dxg_record_oom_refusal"
        f" && TAC_DMESG_BIN='{dmesg_oom_12}'"
        f" && TAC_JOURNALCTL_BIN='{no_journal}'"
        " && _tac_dxg_health_check"
    )
    res_ok = subprocess.run(
        ["bash", "-c", cmd_ok],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="strict",
        timeout=10,
        check=False,
    )
    assert res_ok.returncode == 0, res_ok.stdout
    assert res_ok.stdout.strip() == ""

    # A newer -12 after the OOM watermark (unwitnessed) must STILL be refused.
    dmesg_newer_12 = _fake_dmesg(
        tmp_path,
        "[35119.142438] misc dxg: dxgk: dxgkio_make_resident: Ioctl failed: -12",
        "[35200.000001] misc dxg: dxgk: dxgkio_make_resident: Ioctl failed: -12",
    )
    cmd_newer = (
        f"source '{TAC_BIN_LIB}'"
        f" && TAC_DXG_OOM_STAMP_FILE='{oom_stamp}'"
        f" && TAC_DMESG_BIN='{dmesg_newer_12}'"
        f" && TAC_JOURNALCTL_BIN='{no_journal}'"
        " && _tac_dxg_health_check"
    )
    res_newer = subprocess.run(
        ["bash", "-c", cmd_newer],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="strict",
        timeout=10,
        check=False,
    )
    assert res_newer.returncode == 1
    assert "35200.000001" in res_newer.stdout

    # -75 (EOVERFLOW) and wait_for_completion timeouts are NEVER excused by an OOM watermark.
    for severe_line in (
        "[35110.000000] misc dxg: dxgk: dxgkio_reserve_gpu_va: Ioctl failed: -75",
        "[35110.000000] dxgkrnl: wait_for_completion_interruptible_timeout failed",
    ):
        dmesg_sev = _fake_dmesg(tmp_path, severe_line)
        cmd_sev = (
            f"source '{TAC_BIN_LIB}'"
            f" && TAC_DXG_OOM_STAMP_FILE='{oom_stamp}'"
            f" && TAC_DMESG_BIN='{dmesg_sev}'"
            f" && TAC_JOURNALCTL_BIN='{no_journal}'"
            " && _tac_dxg_health_check"
        )
        res_sev = subprocess.run(
            ["bash", "-c", cmd_sev],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="strict",
            timeout=10,
            check=False,
        )
        assert res_sev.returncode == 1


def test_ephemeral_autotune_model_load_stamp_supersedes_older_dxg_errors(tmp_path: Path) -> None:
    """Ephemeral autotune llama-server spawns log to /tmp/at-*.log, not journalctl --user.

    _tac_dxg_record_model_load stamps TAC_DXG_LOAD_STAMP_FILE from /proc/uptime so a
    subsequent healthy autotune load supersedes earlier dxg errors even with no journal entry.
    """
    uptime = tmp_path / "uptime"
    uptime.write_text("36000.25 600000.00\n", encoding="utf-8", errors="strict")
    load_stamp = tmp_path / "load.ts"
    dmesg = _fake_dmesg(
        tmp_path,
        "[35119.142438] misc dxg: dxgk: dxgkio_make_resident: Ioctl failed: -12",
    )
    cmd = (
        f"source '{TAC_BIN_LIB}'"
        f" && TAC_UPTIME_FILE='{uptime}'"
        f" && TAC_DXG_LOAD_STAMP_FILE='{load_stamp}'"
        " && _tac_dxg_record_model_load"
        f" && TAC_DMESG_BIN='{dmesg}'"
        f" && TAC_JOURNALCTL_BIN='{_fake_journalctl(tmp_path, None)}'"
        " && _tac_dxg_health_check"
    )
    res = subprocess.run(
        ["bash", "-c", cmd],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="strict",
        timeout=10,
        check=False,
    )
    assert res.returncode == 0, res.stdout
    assert res.stdout.strip() == ""


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
