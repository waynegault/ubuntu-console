"""Root hermetic fixtures for E2E tests in tests/e2e/."""

from __future__ import annotations

import site
from pathlib import Path
from typing import Any, Generator
import pytest

from .helpers.mock_hardware import (
    emulate_asus_spark,
    emulate_dell_xps,
)
from .helpers.mock_procfs import VirtualProcfs
from .helpers.mock_server import HermeticHTTPServer


def _real_user_base() -> str | None:
    """The user-site BASE this suite was started with, captured before HOME moves.

    ``hermetic_sandbox`` below repoints HOME at ``tmp_path``, and the user site is derived
    from HOME — so a CHILD interpreter started inside the sandbox looks for packages under
    ``tmp_path/home/.local/...`` and finds none.  On a CI runner that is not a corner case:
    ``pip install -r .github/ci-requirements.txt`` satisfies some requirements from the
    USER site (run 43991753373 logged ``Requirement already satisfied: pluggy ... in
    /home/wayne/.local/lib/python3.14/site-packages``) while ``pytest`` itself sits in the
    tool python.  The child then fails ``import pluggy``, ``pytest_interpreter()``'s probe
    fails correctly, and its documented fallback returns the one interpreter that is broken
    — so ``test_tier2_f4_05_strict_config_validation`` failed for a sandbox artefact and
    reported it as a broken pytest configuration.

    The answer is to keep the sandbox's HOME and tell children where the user site really
    is, via PYTHONUSERBASE.  This is read at import time, i.e. before any fixture runs.

    Deliberately NOT gated on ``site.ENABLE_USER_SITE``: that flag is False inside a venv
    (measured here, ``site.ENABLE_USER_SITE is False`` for the repo's own ``.venv``), yet
    ``getusersitepackages()`` still resolves from HOME and a CHILD built by a tool python —
    the CI shape — does enable it.  Gating on this process's flag would therefore disable
    the fix in exactly the suite that needs it, which the first version of this helper did.
    """
    base = Path(site.getusersitepackages()).parents[2]
    return str(base) if base.is_dir() else None


REAL_USER_BASE = _real_user_base()


def pytest_configure(config: pytest.Config) -> None:
    """Register custom E2E markers to satisfy --strict-markers."""
    config.addinivalue_line("markers", "e2e: End-to-end tests for tactical console")
    config.addinivalue_line("markers", "tier1: Tier 1 isolated feature coverage tests")
    config.addinivalue_line("markers", "tier2: Tier 2 boundary and corner case tests")
    config.addinivalue_line("markers", "tier3: Tier 3 cross-feature interaction tests")
    config.addinivalue_line("markers", "tier4: Tier 4 real-world workload scenario tests")


@pytest.fixture(autouse=True)
def hermetic_sandbox(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Generator[Path, None, None]:
    """Autouse fixture redirecting all mutable filesystem state to isolated tmp_path."""
    sandbox_dirs = {
        "HOME": tmp_path / "home",
        "OPENCLAW_ROOT": tmp_path / "openclaw",
        "TAC_STATE_DIR": tmp_path / "state",
        "LLAMA_MODEL_DIR": tmp_path / "models",
        "KG_REPORTS_DIR": tmp_path / "kg-reports",
        "GLOWMARKT_DATA_DIR": tmp_path / "glowmarkt",
        "IT500_DATA_DIR": tmp_path / "it500",
    }

    for env_var, dir_path in sandbox_dirs.items():
        dir_path.mkdir(parents=True, exist_ok=True)
        monkeypatch.setenv(env_var, str(dir_path))

    # Keep the REAL user site reachable from here (see _real_user_base above): HOME is now
    # the sandbox, and without this a child interpreter silently loses every user-site
    # package — which on this repo's CI runner is where pluggy lives.
    if REAL_USER_BASE:
        monkeypatch.setenv("PYTHONUSERBASE", REAL_USER_BASE)

    # Set non-directory sandbox paths
    monkeypatch.setenv("SECRETS_FILE", str(tmp_path / "secrets.json"))
    monkeypatch.setenv("HEAVY_JOB_LOCK", str(tmp_path / "heavy-job.lock"))

    yield tmp_path


@pytest.fixture
def virtual_procfs(
    monkeypatch: pytest.MonkeyPatch,
) -> Generator[VirtualProcfs, None, None]:
    """Provides a programmable virtual /proc filesystem applied via monkeypatch."""
    procfs = VirtualProcfs(pid_1_comm="systemd", fallback_to_real=True)
    procfs.apply(monkeypatch)
    yield procfs
    procfs.stop()


@pytest.fixture
def profile_spark(
    monkeypatch: pytest.MonkeyPatch,
    virtual_procfs: VirtualProcfs,
) -> Generator[dict[str, Any], None, None]:
    """Configures environment and hardware facts for Asus RTX Spark (128GB unified)."""
    with emulate_asus_spark(procfs=virtual_procfs, monkeypatch=monkeypatch) as profile:
        yield profile


@pytest.fixture
def profile_xps(
    monkeypatch: pytest.MonkeyPatch,
    virtual_procfs: VirtualProcfs,
) -> Generator[dict[str, Any], None, None]:
    """Configures environment and hardware facts for Dell XPS 15 (4GB discrete VRAM)."""
    with emulate_dell_xps(procfs=virtual_procfs, monkeypatch=monkeypatch) as profile:
        yield profile


@pytest.fixture
def mock_llm_service() -> Generator[HermeticHTTPServer, None, None]:
    """Launches an ephemeral HTTP server mocking LLM service with guaranteed cleanup."""
    server = HermeticHTTPServer()
    server.start()
    try:
        yield server
    finally:
        server.stop()


@pytest.fixture
def isolated_graph_db(tmp_path: Path) -> Path:
    """Provides an isolated graph JSON file path with automatic cleanup."""
    db_file = tmp_path / "graph.json"
    db_file.write_text('{"nodes": [], "edges": [], "meta": {}}', encoding="utf-8")
    return db_file


@pytest.fixture
def mock_venv_tree(tmp_path: Path) -> Path:
    """Creates a temporary fake .venv directory containing executable bin/python3."""
    venv_dir = tmp_path / ".venv"
    bin_dir = venv_dir / "bin"
    bin_dir.mkdir(parents=True, exist_ok=True)
    python_bin = bin_dir / "python3"
    python_bin.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    python_bin.chmod(0o755)
    return venv_dir
