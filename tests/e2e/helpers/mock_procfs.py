"""Lightweight hermetic VirtualProcfs context manager.

Intercepts open, os.readlink, os.listdir, and os.path.exists for:
- /proc/1/comm ("systemd", "init", "exe")
- /proc/{pid}/cmdline (null-delimited argv)
- /proc/{pid}/status (PPid, Name, State)
- /proc/{pid}/exe (symlink target or permission error)
- /proc/{pid}/cwd (symlink target)
- /proc/meminfo (customizable memory specs)
- /proc/cpuinfo (customizable CPU architecture facts)
"""

from __future__ import annotations

import builtins
import io
import os
from typing import Any, Callable


class VirtualProcfs:
    """A context manager and patcher that intercepts accesses to /proc.

    Can be used directly as a context manager:
        with VirtualProcfs() as vproc:
            vproc.set_pid_1_comm("systemd")
            ...

    Or with pytest's monkeypatch:
        vproc = VirtualProcfs()
        vproc.apply(monkeypatch)
    """

    def __init__(
        self,
        pid_1_comm: str = "systemd",
        fallback_to_real: bool = True,
    ) -> None:
        self.fallback_to_real = fallback_to_real
        self._files: dict[str, bytes | Exception | type[Exception]] = {}
        self._readlinks: dict[str, str | Exception | type[Exception]] = {}
        self._processes: dict[int, dict[str, Any]] = {}
        self._is_active = False

        # Original functions saved for restoration
        self._orig_open = builtins.open
        self._orig_readlink = os.readlink
        self._orig_listdir = os.listdir
        self._orig_exists = os.path.exists

        # Set initial default procfs state
        self.set_pid_1_comm(pid_1_comm)
        self.set_meminfo(total_kb=131072000, available_kb=120000000)
        self.set_cpuinfo("processor\t: 0\nmodel name\t: ARM Cortex-X925\n")

    def _normalize_path(self, path: Any) -> str:
        """Convert path or PathLike to normalized string."""
        if hasattr(path, "__fspath__"):
            path = path.__fspath__()
        return str(path)

    # --- Configuration APIs ---

    def set_pid_1_comm(self, comm: str) -> VirtualProcfs:
        """Set /proc/1/comm content."""
        clean_comm = comm.strip() + "\n"
        self.set_file("/proc/1/comm", clean_comm.encode("utf-8"))
        return self

    def set_file(self, path: str, content: str | bytes | Exception | type[Exception]) -> VirtualProcfs:
        """Set simulated content for an arbitrary /proc path."""
        norm_path = self._normalize_path(path)
        if isinstance(content, str):
            self._files[norm_path] = content.encode("utf-8")
        else:
            self._files[norm_path] = content
        return self

    def set_readlink(self, path: str, target_or_exc: str | Exception | type[Exception]) -> VirtualProcfs:
        """Set symlink target or error for os.readlink."""
        norm_path = self._normalize_path(path)
        self._readlinks[norm_path] = target_or_exc
        return self

    def set_meminfo(
        self,
        total_kb: int = 131072000,
        available_kb: int = 120000000,
        free_kb: int | None = None,
    ) -> VirtualProcfs:
        """Configure /proc/meminfo with standard fields."""
        if free_kb is None:
            free_kb = available_kb
        content = (
            f"MemTotal:       {total_kb} kB\n"
            f"MemFree:        {free_kb} kB\n"
            f"MemAvailable:   {available_kb} kB\n"
            f"Buffers:          500000 kB\n"
            f"Cached:          4000000 kB\n"
            f"SwapTotal:             0 kB\n"
            f"SwapFree:              0 kB\n"
        )
        self.set_file("/proc/meminfo", content.encode("utf-8"))
        return self

    def set_cpuinfo(self, content: str) -> VirtualProcfs:
        """Configure /proc/cpuinfo."""
        self.set_file("/proc/cpuinfo", content.encode("utf-8"))
        return self

    def add_process(
        self,
        pid: int,
        comm: str = "llama-server",
        cmdline: list[str] | None = None,
        ppid: int = 1,
        exe: str = "/usr/local/bin/llama-server",
        cwd: str = "/home/wayne",
        state: str = "S (sleeping)",
        exe_error: Exception | type[Exception] | None = None,
    ) -> VirtualProcfs:
        """Register a simulated process with all /proc files."""
        if cmdline is None:
            cmdline = [comm]

        self._processes[pid] = {
            "comm": comm,
            "cmdline": cmdline,
            "ppid": ppid,
            "exe": exe,
            "cwd": cwd,
            "state": state,
            "exe_error": exe_error,
        }

        # /proc/{pid}/comm
        self.set_file(f"/proc/{pid}/comm", f"{comm}\n".encode("utf-8"))

        # /proc/{pid}/cmdline (null-terminated string list)
        null_delimited = b"\x00".join(arg.encode("utf-8") for arg in cmdline) + (b"\x00" if cmdline else b"")
        self.set_file(f"/proc/{pid}/cmdline", null_delimited)

        # /proc/{pid}/status
        status_text = f"Name:\t{comm}\nState:\t{state}\nTgid:\t{pid}\nPid:\t{pid}\nPPid:\t{ppid}\nThreads:\t4\n"
        self.set_file(f"/proc/{pid}/status", status_text.encode("utf-8"))

        # /proc/{pid}/exe (readlink)
        if exe_error is not None:
            self.set_readlink(f"/proc/{pid}/exe", exe_error)
        else:
            self.set_readlink(f"/proc/{pid}/exe", exe)

        # /proc/{pid}/cwd (readlink)
        self.set_readlink(f"/proc/{pid}/cwd", cwd)

        return self

    def remove_process(self, pid: int) -> None:
        """Remove a simulated process."""
        self._processes.pop(pid, None)
        for sub in ("comm", "cmdline", "status"):
            self._files.pop(f"/proc/{pid}/{sub}", None)
        for sub in ("exe", "cwd"):
            self._readlinks.pop(f"/proc/{pid}/{sub}", None)

    # --- Interception Logic ---

    def _intercept_open(
        self,
        file: Any,
        mode: str = "r",
        buffering: int = -1,
        encoding: str | None = None,
        errors: str | None = None,
        newline: str | None = None,
        closefd: bool = True,
        opener: Callable[..., Any] | None = None,
    ) -> Any:
        path_str = self._normalize_path(file)

        if path_str.startswith("/proc"):
            if path_str in self._files:
                val = self._files[path_str]
                if isinstance(val, type) and issubclass(val, Exception):
                    raise val()
                if isinstance(val, Exception):
                    raise val

                if not isinstance(val, bytes):
                    raise TypeError(f"virtual procfs entry {path_str} holds {type(val).__name__}, not bytes")
                data = val
                if "b" in mode:
                    bio = io.BytesIO(data)
                    return bio
                enc = encoding or "utf-8"
                err = errors or "replace"
                bio = io.BytesIO(data)
                return io.TextIOWrapper(bio, encoding=enc, errors=err, newline=newline)

            if not self.fallback_to_real:
                raise FileNotFoundError(2, f"No such file or directory: '{path_str}'")

        return self._orig_open(
            file,
            mode=mode,
            buffering=buffering,
            encoding=encoding,
            errors=errors,
            newline=newline,
            closefd=closefd,
            opener=opener,
        )

    def _intercept_readlink(self, path: Any, *, dir_fd: int | None = None) -> str:
        path_str = self._normalize_path(path)

        if path_str.startswith("/proc"):
            if path_str in self._readlinks:
                val = self._readlinks[path_str]
                if isinstance(val, type) and issubclass(val, Exception):
                    raise val()
                if isinstance(val, Exception):
                    raise val
                if not isinstance(val, str):
                    raise TypeError(f"virtual readlink entry {path_str} holds {type(val).__name__}, not str")
                return val

            if not self.fallback_to_real:
                raise FileNotFoundError(2, f"No such file or directory: '{path_str}'")

        if dir_fd is not None:
            return self._orig_readlink(path, dir_fd=dir_fd)
        return self._orig_readlink(path)

    def _intercept_listdir(self, path: Any = ".") -> list[str]:
        path_str = self._normalize_path(path)

        if path_str in ("/proc", "/proc/"):
            sim_pids = [str(p) for p in self._processes.keys()]
            if self.fallback_to_real:
                try:
                    real = self._orig_listdir(path)
                    return sorted(set(real) | set(sim_pids))
                except OSError:
                    pass
            base_entries = ["1", "meminfo", "cpuinfo", "version", "uptime"]
            return sorted(set(base_entries) | set(sim_pids))

        return self._orig_listdir(path)

    def _intercept_exists(self, path: Any) -> bool:
        path_str = self._normalize_path(path)
        if path_str.startswith("/proc"):
            if path_str in self._files or path_str in self._readlinks:
                return True
            # Also check if it's a simulated process directory
            for pid in self._processes:
                if path_str in (f"/proc/{pid}", f"/proc/{pid}/"):
                    return True
            if not self.fallback_to_real:
                return False
        return self._orig_exists(path)

    # --- Activation & Context Management ---

    def start(self) -> VirtualProcfs:
        """Activate monkeypatching."""
        if self._is_active:
            return self
        self._orig_open = builtins.open
        self._orig_readlink = os.readlink
        self._orig_listdir = os.listdir
        self._orig_exists = os.path.exists

        # setattr rather than assignment: the interceptors' signatures are deliberately
        # wider than typeshed's overloads, and setattr states the patch without a
        # `# type: ignore` hiding any other error on the line.
        setattr(builtins, "open", self._intercept_open)
        setattr(os, "readlink", self._intercept_readlink)
        setattr(os, "listdir", self._intercept_listdir)
        setattr(os.path, "exists", self._intercept_exists)
        self._is_active = True
        return self

    def stop(self) -> None:
        """Deactivate and restore original functions."""
        if not self._is_active:
            return
        setattr(builtins, "open", self._orig_open)
        setattr(os, "readlink", self._orig_readlink)
        setattr(os, "listdir", self._orig_listdir)
        setattr(os.path, "exists", self._orig_exists)
        self._is_active = False

    def apply(self, monkeypatch: Any) -> VirtualProcfs:
        """Apply using pytest's monkeypatch fixture for automatic teardown."""
        monkeypatch.setattr(builtins, "open", self._intercept_open)
        monkeypatch.setattr(os, "readlink", self._intercept_readlink)
        monkeypatch.setattr(os, "listdir", self._intercept_listdir)
        monkeypatch.setattr(os.path, "exists", self._intercept_exists)
        self._is_active = True
        return self

    def __enter__(self) -> VirtualProcfs:
        return self.start()

    def __exit__(self, exc_type: Any, exc_val: Any, exc_tb: Any) -> None:
        self.stop()
