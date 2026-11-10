"""Empirical adversarial challenge suite for VirtualProcfs and MockHardwareEmulator.

Tests stress-test assumptions, failure modes, edge cases, concurrency,
path normalization, and isolation boundaries.
"""

from __future__ import annotations

import os
import pathlib
import subprocess
import threading
import time
import pytest

from tests.e2e.helpers.mock_hardware import emulate_asus_spark, emulate_dell_xps
from tests.e2e.helpers.mock_procfs import VirtualProcfs


# Every adversarial case below proves a BYPASS by reading /proc/1/comm outside the virtual
# filesystem and asserting the value came from the host.  Comparing it against the FAKED name
# only works on a box whose PID 1 is something else: on this one systemd IS PID 1 (AGENTS.md
# lists systemd, exe and init as valid supervisors), so a real bypass read "systemd" — the very
# value the test faked — and five cases failed while the code under test was correct.
#
# So the fake name is a SENTINEL no host can be, and the host's own name is the positive
# oracle: a bypass must read the host's value AND must not read the sentinel.
SENTINEL = "vproc-sentinel-pid1"


def _read_host_pid1() -> str:
    """This host's PID 1 name, read with the real open."""
    with open("/proc/1/comm", encoding="utf-8") as fh:
        return fh.read().strip()


# Read at IMPORT, before any case patches builtins.open: a read taken inside a virtual fs
# answers with the virtual value.  My first cut of this helper called it from inside the
# `with` block, so the oracle read the sentinel and the collision check fired on itself.
HOST_PID1 = _read_host_pid1()


def _assert_host_leak(observed: str) -> None:
    """The read escaped to the host: it is the host's PID 1, and it is not the sentinel."""
    # A sentinel that equalled the host name would make every case here vacuous.
    assert SENTINEL != HOST_PID1, "the sentinel collides with this host's PID 1 name"
    assert observed == HOST_PID1, f"expected the host's PID 1 ({HOST_PID1!r}), got {observed!r}"
    assert observed != SENTINEL, "the virtual value leaked instead of the host's"


# --- Challenge 1: Context Manager Re-entrancy Failure ---


def test_adversarial_reentrancy_deactivates_outer_procfs() -> None:
    """Stress-test: Re-entering the same VirtualProcfs instance deactivates outer context upon inner exit.

    Vulnerability:
        VirtualProcfs._is_active is a simple boolean without depth or reference counting.
        Entering `with v:` twice and exiting the inner block calls `v.stop()`, which resets
        `builtins.open` to `_orig_open` and `_is_active = False` while outer block is still active.
    """
    vproc = VirtualProcfs(pid_1_comm=SENTINEL)
    with vproc:
        assert vproc._is_active is True
        assert open("/proc/1/comm", encoding="utf-8").read().strip() == SENTINEL

        # Re-enter the same context manager
        with vproc:
            assert vproc._is_active is True
            assert open("/proc/1/comm", encoding="utf-8").read().strip() == SENTINEL

        # Vulnerability manifest: inner exit called vproc.stop()
        # The outer block is now unpatched!
        assert vproc._is_active is False
        # Reading /proc/1/comm now falls through to host kernel procfs!
        with open("/proc/1/comm", encoding="utf-8") as f:
            leaked_comm = f.read().strip()
        _assert_host_leak(leaked_comm)


# --- Challenge 2: Nested Hardware Emulator State Pollution ---


def test_adversarial_nested_hardware_emulators_leak_procfs_state() -> None:
    """Stress-test: Nesting emulate_dell_xps inside emulate_asus_spark permanently pollutes procfs.

    Vulnerability:
        MockHardwareEmulator.start() overwrites procfs.set_cpuinfo() and procfs.set_meminfo(),
        but MockHardwareEmulator.stop() only restores environment variables and subprocess.run,
        never restoring the prior procfs cpuinfo or meminfo states.
    """
    with VirtualProcfs() as vproc:
        with emulate_asus_spark(procfs=vproc):
            with open("/proc/cpuinfo", encoding="utf-8") as f:
                assert "ARM Cortex-X925" in f.read()

            with emulate_dell_xps(procfs=vproc):
                with open("/proc/cpuinfo", encoding="utf-8") as f:
                    assert "Intel" in f.read()

            # Vulnerability manifest: Dell XPS exited, but vproc was NOT restored to Asus Spark!
            with open("/proc/cpuinfo", encoding="utf-8") as f:
                polluted_cpu = f.read()
            assert "ARM Cortex-X925" not in polluted_cpu
            assert "Intel" in polluted_cpu

            with open("/proc/meminfo", encoding="utf-8") as f:
                polluted_mem = f.read()
            # Asus Spark has 131072000 kB (128GB), but Dell XPS left 32768000 kB (32GB)
            assert "131072000" not in polluted_mem
            assert "32768000" in polluted_mem


# --- Challenge 3: Path Normalization Bypasses (Bytes and Redundant Slashes) ---


def test_adversarial_bytes_path_bypasses_virtual_procfs() -> None:
    """Stress-test: Passing bytes path to open() or os.listdir() bypasses VirtualProcfs.

    Vulnerability:
        VirtualProcfs._normalize_path(path) does `str(path)`.
        For bytes `b'/proc/1/comm'`, `str(path)` evaluates to `"b'/proc/1/comm'"`,
        which does NOT start with `"/proc"`. The call falls through to real open().
    """
    vproc = VirtualProcfs(pid_1_comm=SENTINEL, fallback_to_real=False)
    vproc.start()
    try:
        # 1. open(bytes) bypasses VirtualProcfs and reads host PID 1
        with open(b"/proc/1/comm") as f:
            host_comm = f.read().strip()
        # It read the host PID 1, completely ignoring VirtualProcfs
        _assert_host_leak(host_comm)

        # 2. os.listdir(bytes) bypasses VirtualProcfs even when fallback_to_real=False
        entries = os.listdir(b"/proc")
        # Leaked all real host kernel proc entries as bytes!
        assert b"meminfo" in entries
        assert b"sys" in entries
    finally:
        vproc.stop()


def test_adversarial_unnormalized_proc_path_slashes() -> None:
    """Stress-test: Paths with redundant slashes (e.g. /proc//1/comm) bypass dictionary lookup.

    Vulnerability:
        VirtualProcfs does not call os.path.normpath().
        When /proc//1/comm is opened, it is not found in self._files,
        falling through to host or raising FileNotFoundError when fallback_to_real=False.
    """
    # Test under fallback_to_real=False
    with VirtualProcfs(pid_1_comm=SENTINEL, fallback_to_real=False):
        with pytest.raises(FileNotFoundError, match="No such file or directory: '/proc//1/comm'"):
            open("/proc//1/comm")

    # Test under fallback_to_real=True: falls through to host
    with VirtualProcfs(pid_1_comm=SENTINEL, fallback_to_real=True):
        with open("/proc//1/comm", encoding="utf-8") as f:
            host_comm = f.read().strip()
        # Falls through to host procfs instead of the sentinel
        _assert_host_leak(host_comm)


# --- Challenge 4: pathlib.Path Bypass via io.open ---


def test_adversarial_pathlib_io_open_bypass() -> None:
    """Stress-test: pathlib.Path.open() and read_text() bypass builtins.open patch via io.open.

    Vulnerability:
        pathlib.Path.open() in Python's standard library directly calls `io.open()`.
        VirtualProcfs only patches `builtins.open`, leaving `io.open` unpatched.
        Any module using `pathlib.Path("/proc/...")` (e.g. tools/llm_benchmark.py)
        reads the host filesystem directly.
    """
    with VirtualProcfs(pid_1_comm=SENTINEL):
        # builtins.open works
        with open("/proc/1/comm", encoding="utf-8") as f:
            assert f.read().strip() == SENTINEL

        # pathlib.Path bypasses VirtualProcfs!
        path_comm = pathlib.Path("/proc/1/comm").read_text(encoding="utf-8").strip()
        _assert_host_leak(path_comm)


# --- Challenge 5: Incomplete Filesystem Hierarchy & Inode Type Mismatch ---


def test_adversarial_missing_proc_1_parent_directory() -> None:
    """Stress-test: Under fallback_to_real=False, /proc/1/comm exists but parent /proc/1 does not.

    Vulnerability:
        VirtualProcfs.set_pid_1_comm sets /proc/1/comm in self._files,
        but does not register PID 1 in self._processes.
        Therefore os.path.exists('/proc/1') returns False.
    """
    with VirtualProcfs(pid_1_comm="systemd", fallback_to_real=False):
        assert os.path.exists("/proc/1/comm") is True
        # Broken directory hierarchy:
        assert os.path.exists("/proc/1") is False
        assert os.path.exists("/proc/1/") is False


def test_adversarial_os_stat_and_file_type_unimplemented() -> None:
    """Stress-test: os.path.isfile and os.path.isdir fail because os.stat is not intercepted.

    Vulnerability:
        VirtualProcfs intercepts os.path.exists, but NOT os.stat or os.lstat.
        os.path.isfile and os.path.isdir rely on os.stat, which hits the real host filesystem.
    """
    vproc = VirtualProcfs(fallback_to_real=False)
    vproc.add_process(pid=99999, comm="fake-proc")
    with vproc:
        # exists returns True because of custom check
        assert os.path.exists("/proc/99999/comm") is True
        assert os.path.exists("/proc/99999") is True

        # BUT isfile and isdir fail because os.stat is not intercepted!
        assert os.path.isfile("/proc/99999/comm") is False
        assert os.path.isdir("/proc/99999") is False


def test_adversarial_simulated_process_dir_listdir_fails() -> None:
    """Stress-test: os.listdir('/proc/{pid}') fails for simulated processes.

    Vulnerability:
        VirtualProcfs._intercept_listdir only intercepts path == '/proc' or '/proc/'.
        Attempting to list the directory of a simulated process raises FileNotFoundError.
    """
    vproc = VirtualProcfs(fallback_to_real=False)
    vproc.add_process(pid=77777, comm="sim-proc")
    with vproc:
        with pytest.raises(FileNotFoundError):
            os.listdir("/proc/77777")


# --- Challenge 6: Concurrency Race Condition during Dict Iteration ---


def test_adversarial_concurrent_process_registration_dict_mutation() -> None:
    """Stress-test: Concurrent process mutation causes RuntimeError during listdir and exists.

    Vulnerability:
        VirtualProcfs has no threading Lock.
        _intercept_listdir iterates over `self._processes.keys()`.
        _intercept_exists iterates over `for pid in self._processes:`.
        Concurrent add_process or remove_process triggers:
        RuntimeError: dictionary changed size during iteration.
    """
    vproc = VirtualProcfs(fallback_to_real=False)
    vproc.start()

    errors: list[Exception] = []
    stop_event = threading.Event()

    def mutator() -> None:
        p = 30000
        while not stop_event.is_set():
            p += 1
            vproc.add_process(pid=p, comm="mutator")
            if p > 30300:
                for k in range(30001, p + 1):
                    vproc.remove_process(pid=k)
                p = 30000

    def scanner() -> None:
        while not stop_event.is_set():
            try:
                _ = os.listdir("/proc")
                _ = os.path.exists("/proc/30150")
            except RuntimeError as exc:
                if "dictionary changed size during iteration" in str(exc):
                    errors.append(exc)
            except Exception:
                pass

    threads = [threading.Thread(target=mutator)] + [threading.Thread(target=scanner) for _ in range(4)]
    for t in threads:
        t.start()
    time.sleep(0.5)
    stop_event.set()
    for t in threads:
        t.join()
    vproc.stop()

    # Empirically verify that unhandled concurrency causes RuntimeError
    assert len(errors) > 0, "Expected concurrency race condition did not trigger"


# --- Challenge 7: Missing /proc/*/status Isolation Leak under Default Fallback ---


def test_adversarial_default_fallback_leaks_host_pid1_status() -> None:
    """Stress-test: Default VirtualProcfs does not mock /proc/1/status, leaking host PID 1 status.

    Vulnerability:
        VirtualProcfs sets /proc/1/comm, but not /proc/1/status.
        Under fallback_to_real=True (the default), opening /proc/1/status
        reads the host system's PID 1 status (e.g. Name: exe under WSL2).
    """
    with VirtualProcfs(pid_1_comm=SENTINEL, fallback_to_real=True):
        with open("/proc/1/status", encoding="utf-8") as f:
            status_content = f.read()
        first_line = status_content.splitlines()[0]
        # Leaked host PID 1 status name — the HOST's, whatever this box calls PID 1.
        assert first_line == f"Name:\t{HOST_PID1}", f"expected the host's Name, got {first_line!r}"
        assert SENTINEL not in status_content, "the virtual PID 1 name leaked into status"


# --- Challenge 8: Subprocess Mock in MockHardwareEmulator vs CLI Contracts ---


def test_adversarial_mock_hardware_smi_fails_csv_parsing() -> None:
    """Stress-test: MockHardwareEmulator returns ASCII table for CSV nvidia-smi queries.

    Vulnerability:
        MockHardwareEmulator intercepts all 'nvidia-smi' commands and unconditionally returns
        the multi-line human-readable table (smi_out), regardless of flags like:
        `--query-gpu=name,driver_version --format=csv,noheader`.
        This causes tools like tools/llm_benchmark.py and scripts/oc-restart-check.py to fail
        or parse empty fields.
    """
    with emulate_asus_spark():
        # Query matching tools/llm_benchmark.py:_gpu_metadata
        res = subprocess.run(
            ["nvidia-smi", "--query-gpu=name,driver_version", "--format=csv,noheader"],
            capture_output=True,
            text=True,
        )
        first_line = res.stdout.splitlines()[0] if res.stdout.splitlines() else ""
        name, separator, driver = first_line.partition(",")
        # Fails because first line is timestamp, not comma-separated GPU info:
        assert separator == ""
        # The parser misidentifies the timestamp as the GPU model name!
        assert name == "Sat Nov 10 12:00:00 2026"
        assert driver == ""


# --- Challenge 9: Corrupted Meminfo Boundary Resilience ---


def test_adversarial_corrupted_meminfo_handling() -> None:
    """Stress-test: VirtualProcfs allows injecting malformed meminfo payloads.

    Verifies behavior when meminfo is empty, non-numeric, or missing units.
    """
    with VirtualProcfs() as vproc:
        # 1. Empty meminfo
        vproc.set_file("/proc/meminfo", "")
        with open("/proc/meminfo", encoding="utf-8") as f:
            assert f.read() == ""

        # 2. Corrupted formatting (missing numbers and units)
        vproc.set_file("/proc/meminfo", "MemTotal: corrupted_total\nMemAvailable:\n")
        with open("/proc/meminfo", encoding="utf-8") as f:
            lines = f.read().splitlines()
        assert len(lines) == 2

        # 3. Exception injection
        vproc.set_file("/proc/meminfo", OSError(5, "Input/output error"))
        with pytest.raises(OSError, match="Input/output error"):
            open("/proc/meminfo")


# --- Challenge 10: Non-Existent PIDs and Missing Status Handling ---


def test_adversarial_nonexistent_pid_and_missing_status() -> None:
    """Stress-test: Handling of non-existent PIDs and processes with missing status.

    Verifies behavior under fallback_to_real=False and fallback_to_real=True.
    """
    # Under fallback_to_real=False
    with VirtualProcfs(fallback_to_real=False) as vproc:
        # Non-existent PID raises FileNotFoundError
        with pytest.raises(FileNotFoundError):
            open("/proc/12345678/cmdline")

        # Process without status file
        vproc.add_process(pid=44444, comm="ghost")
        # Remove status specifically
        vproc._files.pop("/proc/44444/status")
        with pytest.raises(FileNotFoundError):
            open("/proc/44444/status")
        # But comm and cmdline still exist
        with open("/proc/44444/comm", encoding="utf-8") as f:
            assert f.read().strip() == "ghost"
