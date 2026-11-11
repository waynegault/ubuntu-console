---
name: quality-gates
description: >-
  Execution runbook and verification procedures for Ubuntu Console quality gates: module
  versioning, error-swallow classification, count ratchets, repo boundaries, and hermetic tests.
---

# Ubuntu Console Quality Gates Runbook

Every change to Ubuntu Console must pass the quality gates before completion. This runbook details each gate, its commands, and how to resolve violations.

## Mandatory Quality Gates

### 1. Module Version Header Gate (`tools/check-module-versions.sh`)
- **Rule**: Every modified file carrying `# Module Version: N` or `# Version: X.Y.Z` must have its version incremented with a dated changelog entry.
- **Verification**:
  ```bash
  tools/check-module-versions.sh
  ```
- **Remediation**: Increment the version number at the top of the file and add a dated entry explaining the change:
  ```bash
  # Module Version: 23
  #   v23 (2026-11-11): clean-room holds actions.runner.* services during autotune.
  ```

### 2. Silent Swallow Classification (`tools/check-contracts.sh swallows`)
- **Rule**: Every `2>/dev/null` or `|| true` in shell scripts must be classified with a `# swallow-ok: <reason>` comment on the line immediately preceding it.
- **Verification**:
  ```bash
  tools/check-contracts.sh swallows
  ```
- **Remediation**: Add a descriptive `# swallow-ok:` comment above the suppression:
  ```bash
  # swallow-ok: systemctl error listing units is handled by empty output
  _runner_units=$(systemctl --user list-unit-files 'actions.runner.*' 2>/dev/null)
  ```

### 3. Shell Function Comments & Style Ratchet (`tools/count-ratchet.sh`)
- **Rule**: Every shell function definition must have a descriptive `# comment` directly above it (§18.3 item 9.5). Non-comment lines must not exceed 120 characters (§18.3 item 8.1.8).
- **Verification**:
  ```bash
  tools/count-ratchet.sh
  ```
- **Remediation**:
  - Add comments directly above function definitions:
    ```bash
    # cleanroom_restore restores stopped watchdogs, tenants, runners and fleet model.
    cleanroom_restore() {
    ```
  - If a metric cleanly drops, update the baseline ratchet:
    ```bash
    tools/count-ratchet.sh --update
    ```

### 4. Repository Boundary Gate (`tools/check-repo-boundaries.sh`)
- **Rule**: Prevents cross-layer leakages between scripts, tools, configs, and models.
- **Verification**:
  ```bash
  tools/check-repo-boundaries.sh
  ```

### 5. Python Type & Lint Hygiene (`ruff` & `mypy`)
- **Rule**: Strict `.venv/bin/python3` execution. Zero warning silencing, zero unannotated `# type: ignore`.
- **Verification**:
  ```bash
  .venv/bin/python3 -m ruff check tools/ scripts/ bin/ tests/
  .venv/bin/python3 -m mypy tools/box scripts/kgraph tools/fsutil.py tools/llm_client.py
  ```

### 6. Hermetic Unit & Integration Tests
- **Rule**: All tests must run cleanly under `-W error` with zero `ResourceWarning` socket leaks and zero production data pollution (`/mnt/HD/HD_a2/...`, `~/.openclaw/...`).
- **Verification**:
  ```bash
  .venv/bin/python3 -m pytest -W error -m "not bats" --ignore=tests/e2e -q
  .venv/bin/python3 tests/e2e/runner.py -q
  ```

## Full Gate Check Sequence
Run the full gate sequence before committing:

```bash
tools/check-module-versions.sh && \
tools/check-contracts.sh && \
tools/count-ratchet.sh && \
tools/check-repo-boundaries.sh && \
.venv/bin/python3 -m ruff check tools/ scripts/ bin/ tests/ && \
.venv/bin/python3 -m mypy tools/box scripts/kgraph tools/fsutil.py tools/llm_client.py && \
.venv/bin/python3 -m pytest -W error -m "not bats" --ignore=tests/e2e -q
```
