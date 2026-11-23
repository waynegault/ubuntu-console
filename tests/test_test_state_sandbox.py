"""The test LLM sandbox: every path a suite can write is redirected, and the live one refused.

Measured 2026-11-19: the runner inherited the operator's live store exports, so a
suite that did not pin them wrote production — 631 of 782 scan backups were fixtures,
286 rows-999 logs sat beside the real autotune logs, autotune-failures.tsv carried
stub.gguf tallies, and a 0-byte beta.gguf appeared in the model store.  AGENTS.md §4.

What these cases would catch, one each:
  * a helper that redirects only SOME of the paths — a suite writing through the
    unredirected one contaminates production exactly as before;
  * a sandbox inside the live store reported as a success;
  * a relative root, which a `cd` in the suite can move anywhere;
  * a runner that stops calling the helper, so the guarantee silently lapses.
"""

import os
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
HELPER = REPO_ROOT / "tools" / "test-state-sandbox.sh"
RUNNER = REPO_ROOT / "tools" / "run-tests.sh"
CONSTANTS = REPO_ROOT / "scripts" / "01-constants.sh"

# The paths a suite can write through.  LLM_STATE_DIR carries the backups and the
# log/ledger trees, LLM_REGISTRY and LLM_DEFAULT_FILE the registry sidecars,
# LLAMA_MODEL_DIR the store itself (scans, archives), TAC_STATE_DIR the retired rows.
REDIRECTED = (
    "LLM_STATE_DIR",
    "LLM_REGISTRY",
    "LLM_DEFAULT_FILE",
    "LLAMA_MODEL_DIR",
    "TAC_STATE_DIR",
)


def _sandboxed_env(root: Path, home: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            "bash",
            "-c",
            # `&&`, not `;`: a refusal exits 2 and must not be followed by a print that
            # would make the exported (empty) paths look like a successful sandbox.
            'source "$1" && tac_test_state_sandbox "$2" && for v in "${@:3}"; do printf "%s=%s\\n" "$v" "${!v}"; done',
            "_",
            str(HELPER),
            str(root),
            *REDIRECTED,
        ],
        env={"PATH": os.environ["PATH"], "HOME": str(home)},
        capture_output=True,
        text=True,
        check=False,
        timeout=30,
    )


@pytest.fixture()
def home(tmp_path: Path) -> Path:
    h = tmp_path / "home"
    (h / "models" / "active").mkdir(parents=True)
    return h


def test_every_writable_path_is_redirected_under_the_root(tmp_path: Path, home: Path) -> None:
    root = tmp_path / "sandbox"
    res = _sandboxed_env(root, home)
    assert res.returncode == 0, res.stderr
    got = dict(line.split("=", 1) for line in res.stdout.splitlines())
    assert set(got) == set(REDIRECTED), f"a path was left unpinned: {got}"
    for name, value in got.items():
        assert Path(value).is_relative_to(root), f"{name} escaped the sandbox: {value}"
    # The directories exist, so a writer that mkdirs a parent is not the thing tested.
    for name in ("LLM_STATE_DIR", "LLAMA_MODEL_DIR", "TAC_STATE_DIR"):
        assert Path(got[name]).is_dir(), f"{name} was not created: {got[name]}"


def test_a_sandbox_inside_the_live_model_store_is_refused(tmp_path: Path, home: Path) -> None:
    root = home / "models" / "active"
    res = _sandboxed_env(root, home)
    assert res.returncode == 1, res.stdout
    assert "refusing a sandbox inside the live model store" in res.stderr
    # Refused, not half-applied: no path was exported.
    assert res.stdout == ""


def test_a_relative_root_is_refused(tmp_path: Path, home: Path) -> None:
    res = _sandboxed_env(Path("relative-sandbox"), home)
    assert res.returncode == 1, res.stdout
    assert "root must be absolute" in res.stderr


def test_the_runner_hands_every_suite_the_sandbox() -> None:
    # The chokepoint is the runner: a suite written tomorrow inherits this without
    # being told.  Catches a refactor that drops the source or the call.
    source = RUNNER.read_text(encoding="utf-8")
    assert 'source "$REPO_ROOT/tools/test-state-sandbox.sh"' in source
    assert 'tac_test_state_sandbox "$TAP_DIR/llm"' in source


def _constants_state_dir(env: dict[str, str]) -> str:
    res = subprocess.run(
        ["bash", "-c", 'source "$1" && printf "%s\\n" "$LLM_STATE_DIR"', "_", str(CONSTANTS)],
        env=env,
        capture_output=True,
        text=True,
        check=False,
        timeout=30,
    )
    assert res.returncode == 0, res.stderr
    return res.stdout.strip()


def test_constants_ignores_an_inherited_state_dir_under_bats(tmp_path: Path) -> None:
    """A direct `bats <suite>` run must not follow the operator's live LLM_STATE_DIR.

    Catches the 2026-11-23 leak: 01-constants read `${LLM_STATE_DIR:-…}`, which TAKEs
    the exported live value, so a suite that pinned HOME/LLM_REGISTRY/LLAMA_MODEL_DIR
    still wrote ~/models/.llm/backups through 11e's scan backup.  A direct run has no
    sandbox beside it, so this guard is the only thing between it and the store.
    """
    run_dir = tmp_path / "run"
    got = _constants_state_dir(
        {
            "PATH": os.environ["PATH"],
            "HOME": str(tmp_path),
            "BATS_RUN_TMPDIR": str(run_dir),
            "LLM_STATE_DIR": "/home/wayne/models/.llm",  # the operator's export, verbatim
        }
    )
    assert got != "/home/wayne/models/.llm", "an inherited live state dir was accepted under BATS"
    assert Path(got).is_relative_to(run_dir), f"the BATS state dir escaped the run: {got}"


def test_constants_keeps_the_exported_state_dir_outside_bats(tmp_path: Path) -> None:
    """Production is unchanged: an exported state dir still wins.

    Catches a guard written too broadly — one that redirected every caller rather than
    the test run, which would move the operator's backups somewhere else.
    """
    live = tmp_path / "live"
    got = _constants_state_dir({"PATH": os.environ["PATH"], "HOME": str(tmp_path), "LLM_STATE_DIR": str(live)})
    assert got == str(live)
