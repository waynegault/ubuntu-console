"""Read one box's facts from its own conf — the shell is the source, this is the reader.

WHY (measured 2026-11-18): `tools/box/profiles.py` and `config/hosts.d/<id>.conf` both
describe each machine, and nothing compared them.  The ASUS profile's `autotune_census` and
its `:18089` measure lane had to be re-synced BY HAND in profiles.py v2, and the shell conf
is what the box actually runs on — so a Python copy that drifts sizes a sweep against a
census the launcher does not honour, silently.

The confs are declarative shell (`: "${VAR:=value}"`), so they are SOURCED, never grepped: a
regex that re-implements `:=` and `$HOME` expansion would be a second reading of the same
file, which is the drift this module exists to remove.  Two details are load-bearing:

* `env -i` — the confs use `:=`, so an INHERITED value WINS.  A python process started from
  a shell that sourced `env.sh` carries THIS box's facts, and without a clean environment
  the XPS conf reported the ASUS's port and lanes (measured: `intel-xe-cuda` read 18087).
* one BLOCK per key — `LLAMA_LANE_SPECS` is a multi-line value, and a `key=value` line parser
  keeps only its first lane (measured: the ASUS read as a single lane).

Exit paths: a missing conf or unreadable value raises `ConfFactsError` naming the file, the
key and the profile — the caller is a library import, so silence would be a profile built
from half a file.
"""

from __future__ import annotations

import functools
import re
import subprocess
from pathlib import Path

# tools/box/conf_facts.py -> repo root is two levels up from this package.
CONFIG_DIR = Path(__file__).resolve().parents[2] / "config" / "hosts.d"

# Every fact the Python layer may need from a conf.  Requesting one that a conf does not
# declare is not an error: several are underived on one box by design (the XPS declares no
# autotune census), and `facts()` simply omits them.
KNOWN_KEYS: tuple[str, ...] = (
    "LLAMA_DRIVE_ROOT",
    "LLAMA_MODEL_DIR",
    "LLAMA_ARCHIVE_DIR",
    "HF_HOME",
    "HF_HUB_CACHE",
    "LLM_REGISTRY",
    "LLM_STATE_DIR",
    "LLAMA_GPU_LAYERS",
    "LLAMA_CPU_THREADS_BASE",
    "LLAMA_THREAD_CAP",
    "LLAMA_FIT_TARGET_MB",
    "LLAMA_CACHE_RAM_MB",
    "LLAMA_PARALLEL_SLOTS",
    "LLAMA_CTX_WINDOW",
    "LLAMA_MAX_PROBE_CTX",
    "VRAM_TOTAL_BYTES_FALLBACK",
    "LLAMA_QUANT_GUIDE_REL",
    "LLAMA_LANE_SPECS",
    "LLAMA_LANE_KEEP_UNITS",
    "LLAMA_CUDA_LANE_UNIT",
    "LLM_SERVICE_PORT",
    "TAC_HOST_PRIMARY_LANE",
    "TAC_HOST_BASELINE_MODEL",
    "LLAMA_GPU_FREE_THRESHOLD_MIB",
    "LLM_AUTOTUNE_BASELINE_GAP_MAX",
    "LLM_AUTOTUNE_CENSUS",
    "LLM_AUTOTUNE_CENSUS_MAX_MIB",
    "LLAMA_CUDA_SERVER_BIN",
    "LLAMA_BUILD_DIR",
    "LLAMA_CUDA_ARCH",
    "LLAMA_CUDA_FA_QUANTS",
    "TAC_HOST_GPU_LABEL",
    "TAC_HOST_IGPU_LABEL",
)


class ConfFactsError(RuntimeError):
    """A profile's conf could not be read; the message names the file and the profile."""


@functools.lru_cache(maxsize=8)
def facts(profile_id: str) -> dict[str, str]:
    """This box's declared facts, sourced from `config/hosts.d/<profile_id>.conf`.

    Absent keys are omitted — callers pass a default.  Cached: one source per profile per
    process, and `profiles.py` calls it twice at import.
    """
    conf = CONFIG_DIR / f"{profile_id}.conf"
    if not conf.is_file():
        raise ConfFactsError(f"{profile_id}: no conf at {conf}")
    script = 'source "$1" >/dev/null 2>&1 || exit 3; '
    script += "; ".join(f'printf "<<<{k}\\n%s\\n>>>{k}\\n" "${{{k}:-}}"' for k in KNOWN_KEYS)
    try:
        proc = subprocess.run(
            [
                "env",
                "-i",
                f"HOME={Path.home()}",
                "PATH=/usr/bin:/bin",
                "bash",
                "-c",
                script,
                "_",
                str(conf),
            ],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError as exc:  # bash itself is missing — a broken host, not a broken conf
        raise ConfFactsError(f"{profile_id}: cannot run bash to source {conf}: {exc}") from exc
    if proc.returncode != 0:
        raise ConfFactsError(
            f"{profile_id}: {conf} did not source cleanly (rc={proc.returncode}): {proc.stderr.strip()[:200]}"
        )
    out: dict[str, str] = {}
    for key in KNOWN_KEYS:
        m = re.search(rf"<<<{re.escape(key)}\n(.*?)\n>>>{re.escape(key)}", proc.stdout, re.S)
        if m and m.group(1).strip():
            out[key] = m.group(1)
    return out


def lane_specs(profile_id: str) -> list[tuple[str, int]]:
    """(unit, port) for every declared lane, in conf order."""
    raw = facts(profile_id).get("LLAMA_LANE_SPECS", "")
    lanes: list[tuple[str, int]] = []
    for line in raw.splitlines():
        if "|" not in line:
            continue
        unit, _, port = line.partition("|")
        if unit.strip() and port.strip().isdigit():
            lanes.append((unit.strip(), int(port)))
    return lanes


# end of file
