# Architecture, Box-Awareness & Quality Gate Rules

See the repository root [`AGENTS.md`](../../AGENTS.md) for the complete set of always-on rules governing:

1. **Box-Awareness (`tools/box/` & `config/hosts.d/`)**:
   - `asus-n1n-rtx-spark` (ARM64 `Cortex-X925`, 128 GB unified memory, Blackwell `sm_121a`, port `18087`, `LLAMA_GPU_LAYERS=999`, `LLAMA_FIT_KEEP_RESERVE_MB=12288`).
   - `intel-xe-cuda` (x86_64 `i9-12900HK`, 4 GB discrete RTX 3050 Ti + Intel Xe, port `18081`, `LLAMA_GPU_LAYERS=24`, `LLAMA_THREAD_CAP=6`).
2. **Strict `.venv/bin/python3` Execution**: Resolve via `tools/python-runtime.sh`; never use `sys.path.insert` hacks.
3. **Strict Pydantic v2 Validation**: Validate all `tools/box/`, `scripts/kgraph/`, and `tools/llm_client.py` schemas; use `tools/fsutil.py` for atomic writes.
4. **Hermetic Testing under `-W error`**: Zero writes to `/mnt/HD/HD_a2/` or `~/.openclaw/`; zero unclosed sockets.
5. **Version & Contract Gates**: Increment `Module Version:` on edits, document `# swallow-ok: <why>` on any `2>/dev/null` or `|| true`, comment every shell function, and verify with `tools/check-contracts.sh`, `tools/count-ratchet.sh`, `ruff`, `mypy`, and `pytest -W error`.
6. **Standing Engineering Rules**: Never silence a warning; omitted arguments are unmade decisions; verify effects, not returns; solve operational issues in code; timezone discipline (`Europe/London` / ISO 8601 UTC).
