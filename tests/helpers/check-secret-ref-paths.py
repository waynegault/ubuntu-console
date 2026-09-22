#!/usr/bin/env python3
"""Validate every SecretRef mapping path against the real config schema.

WHY THIS EXISTS (2026-09-22)
----------------------------
`__oc_apply_secret_refs` (scripts/09d-oc-agents.sh) holds a table of
"<config dot-path> -> <ENV_VAR>" rows.  A row whose path is not a real field in
the OpenClaw config schema does not fail loudly at the table: `set_path` creates
the intermediate objects with `setdefault`, so the write lands on a leaf nothing
reads and the credential is never injected.  That is exactly how
`plugins.entries.typesafe-ai.apiKey` survived review — the real field is
`skills.entries.typesafe-ai.apiKey` (installed skills live under `skills.entries`;
a plugin entry has no `apiKey` of its own), so `TYPESAFE_API_KEY` stayed
un-injected while the table looked complete.

It is also worse than inert.  The refs are written in ONE batched
`openclaw config patch`, and that command VALIDATES: one path the schema rejects
aborts the whole batch, so every other pending SecretRef update in the same run
is dropped too.

The oracle here is the product's own validator, not a re-derived copy of the
schema: the same `openclaw config patch --dry-run` the production code writes
through.  Rows whose env var has no value are still checked — each mapped var is
given a dummy value for the run so that SecretRef *resolvability* cannot mask a
schema error.  (This checks that a path is a legal field; it deliberately does
not check that the key is importable.)

EXIT CODES
----------
  0  every mapping path is a valid config field
  1  at least one path the schema rejects (the rows are named)
  2  could not check (no openclaw CLI, or no config to validate against) —
     callers should treat this as "skipped", not as a pass.

USAGE
-----
  python3 tests/helpers/check-secret-ref-paths.py [--script PATH]
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

DEFAULT_SCRIPT = "scripts/09d-oc-agents.sh"


def extract_rows(script_path):
    """Return [(config_path, ENV_VAR)] from the script's `entries = [...]` list."""
    try:
        with open(script_path, encoding="utf-8") as handle:
            source = handle.read()
    except OSError as exc:
        print(f"check-secret-ref-paths: cannot read {script_path}: {exc}", file=sys.stderr)
        return None
    block = re.search(r"entries = \[(.*?)\n\]", source, re.S)
    if not block:
        print(
            f"check-secret-ref-paths: no `entries = [...]` table found in {script_path} "
            "(has __oc_apply_secret_refs been renamed?)",
            file=sys.stderr,
        )
        return None
    rows = re.findall(r'\("([^"]+)",\s*"([^"]+)"\)', block.group(1))
    if not rows:
        print(f"check-secret-ref-paths: table in {script_path} parsed empty", file=sys.stderr)
        return None
    return rows


def build_patch(rows):
    """Nest the rows into one patch object, exactly as the production code does."""
    patch = {}
    for config_path, env_var in rows:
        node = patch
        parts = config_path.split(".")
        for segment in parts[:-1]:
            node = node.setdefault(segment, {})
        node[parts[-1]] = {"source": "env", "provider": "default", "id": env_var}
    return patch


def attribute(errors, rows):
    """Map the validator's error paths back to the table rows they implicate."""
    blamed = []
    for error_path, message in errors:
        for config_path, env_var in rows:
            if config_path == error_path or config_path.startswith(error_path + "."):
                blamed.append((config_path, env_var, message))
    return blamed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--script", default=DEFAULT_SCRIPT, help="script holding the mapping table")
    parser.add_argument("--quiet", action="store_true", help="print only failures")
    args = parser.parse_args()

    rows = extract_rows(args.script)
    if rows is None:
        return 2

    openclaw = shutil.which("openclaw")
    if openclaw is None:
        print("check-secret-ref-paths: openclaw CLI not available — skipping", file=sys.stderr)
        return 2

    patch = build_patch(rows)
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as handle:
        json.dump(patch, handle)
        patch_path = handle.name

    env = dict(os.environ)
    for _, env_var in rows:
        env.setdefault(env_var, "dummy-validation-value")

    try:
        proc = subprocess.run(
            [openclaw, "config", "patch", "--file", patch_path, "--dry-run"],
            capture_output=True,
            text=True,
            env=env,
            timeout=180,
            check=False,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        print(f"check-secret-ref-paths: could not run the validator: {exc}", file=sys.stderr)
        return 2
    finally:
        os.unlink(patch_path)

    output = (proc.stdout or "") + (proc.stderr or "")
    if proc.returncode == 0:
        if not args.quiet:
            print(f"OK: {len(rows)} SecretRef mapping path(s) are valid config fields")
        return 0

    # "  - - tools.web.fetch: Unrecognized key: \"firecrawl\""
    errors = [
        (match.group(1).strip(), match.group(2).strip())
        for match in re.finditer(r"^\s*-\s*-\s*(\S+):\s*(.+)$", output, re.M)
    ]
    blamed = attribute(errors, rows)

    if blamed:
        for config_path, env_var, message in blamed:
            print(f"FAIL {config_path} ({env_var}): {message}")
    else:
        # The validator refused but we could not pin it to a row — print it raw
        # rather than reporting success by omission.
        print("FAIL: validator rejected the batched patch; no row could be blamed directly:")
        print(output.strip())
    print(
        "\nA mapping path must be a real config field.  The batched `config patch` "
        "VALIDATES, so one bad row aborts every other SecretRef update in the same run.",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
