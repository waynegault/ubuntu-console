"""Filesystem primitives shared by the repo's tools.

One atomic text writer, because several load-bearing files were truncated in
place: a crash during the write left a partial CI-verdict cache, ratchet
baseline or outcome artefact, and the next reader treated the wreckage as data.
The pattern is the one ``tools/llm_benchmark.py`` already used: write a temp
file in the target directory, fsync, then ``os.replace``.
"""

from __future__ import annotations

import logging
import os
import tempfile
from pathlib import Path

logger = logging.getLogger(__name__)

# Module-local so a test can replace the rename without patching the global os
# module every other caller shares.
_replace = os.replace


def atomic_write_text(path: str | os.PathLike[str], text: str, *, encoding: str = "utf-8") -> None:
    """Write *text* to *path* atomically.

    The destination is either the old bytes or the complete new bytes; it is
    never a truncated file.  The temporary file is created beside the target so
    ``os.replace`` stays on one filesystem.
    """
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(dir=target.parent, prefix=f".{target.name}.", suffix=".tmp")
    tmp_path = Path(tmp_name)
    try:
        with os.fdopen(fd, "w", encoding=encoding) as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        _replace(tmp_path, target)
    except BaseException:
        try:
            tmp_path.unlink()
        except OSError:
            logger.debug("could not remove temp file %s", tmp_path, exc_info=True)
        raise
