"""Incremental rebuild and --watch mode for kgraph.

Detects file changes and rebuilds the graph incrementally (or fully)
when source content changes.

--update: rebuild graph from scratch, preserving user edits
--watch: stay running, auto-rebuild on file changes
"""

from __future__ import annotations

import hashlib
import logging
import os
import time
from pathlib import Path

from .models import Graph, GraphBuilder

logger = logging.getLogger(__name__)


def incremental_update(graph_db_path: str, mem_db_path: str | None = None,
                       source_dir: str | None = None, **kwargs) -> Graph:
    """Perform an incremental (or full) rebuild of the graph.

    Strategy:
    1. Load existing user-saved graph from graph_db
    2. Merge in fresh data from memory DB (if available)
    3. Optionally run AST extraction on source_dir to inject code concepts
    4. Re-run community detection, confidence tagging, etc.
    5. Save updated graph back to graph_db

    Returns:
        The merged Graph.
    """
    from .graph_db import load_from_graph_db, save_to_graph_db
    from .memory_import import load_from_memory_db
    from .confidence import tag_confidence
    from .community import detect_communities
    from .ast_extractor import ast_available, extract_repo_graph
    from .life_index import load_life_index

    builder = GraphBuilder()

    # 1. Load existing user graph
    if graph_db_path and os.path.exists(os.path.expanduser(graph_db_path)):
        user_graph = load_from_graph_db(graph_db_path)
        builder.merge(user_graph)

    # 2. Merge memory DB data
    if mem_db_path and os.path.exists(mem_db_path):
        try:
            mem_graph = load_from_memory_db(mem_db_path)
            builder.merge(mem_graph)
        except (OSError, ValueError, KeyError) as exc:
            logger.warning("Memory DB import failed: %s", exc)

    # 3. AST extraction
    ast_run = kwargs.get("ast", True)
    if ast_run and source_dir and ast_available():
        try:
            ast_graph = extract_repo_graph(
                source_dir,
                include_variables=kwargs.get("ast_vars", False),
                max_files=kwargs.get("ast_max_files", 0),
                subdirs=kwargs.get("ast_subdirs"),
            )
            if ast_graph.get("nodes"):
                builder.merge(ast_graph)
                logger.info("AST: %d nodes, %d edges from %s",
                            len(ast_graph["nodes"]), len(ast_graph["edges"]), source_dir)
        except (OSError, ValueError, KeyError) as exc:
            logger.warning("AST extraction failed: %s", exc)

    # 4. Semantic deduplication across all merged sources.
    # Collapses same-concept nodes (e.g. "decision: X" from different chunks)
    # before building the final graph.  Uses life_index for alias resolution.
    # Source: rahulnyk/graph_maker review — dedup at extraction time prevents
    # stale duplicates in the persisted database.
    builder.deduplicate_semantic(life_index=load_life_index())

    graph = builder.build()

    # 5. Confidence tagging
    graph = tag_confidence(graph)

    # 6. Community detection
    graph = detect_communities(graph)

    # 7. Save
    if graph_db_path:
        save_to_graph_db(graph_db_path, graph)

    return graph


def merge_graphs(base: Graph | dict, overlay: Graph | dict,
                 life_index: dict | None = None) -> Graph:
    """Merge overlay graph into base, deduplicating by id and semantics.

    Delegates to ``GraphBuilder`` for consistent dedup logic.
    A semantic dedup pass runs after the merge to collapse equivalent
    concept nodes across both sources.

    Args:
        base: The base graph to merge into.
        overlay: The overlay graph to merge from.
        life_index: Optional life_index dict for alias resolution during
            semantic dedup.  If omitted, dedup runs without alias
            resolution (exact-normalized only).

    Source: rahulnyk/graph_maker review — dedup at extraction time prevents
    stale duplicates in the persisted database.
    """
    builder = GraphBuilder()
    builder.merge(base)
    builder.merge(overlay)
    builder.deduplicate_semantic(life_index=life_index)
    return builder.build()


def start_watch(graph_db_path: str, mem_db_path: str | None = None,
                source_dir: str | None = None, interval: int = 30, **kwargs) -> None:
    """Watch directories and auto-rebuild on changes.

    Polls for file changes at the given interval.  When detected,
    runs incremental_update().
    """
    file_hashes: dict[str, str] = {}

    def _hash_files(directory: str) -> dict[str, str]:
        result: dict[str, str] = {}
        root = Path(directory).resolve()
        for ext in (".py", ".sh", ".bash", ".zsh", ".pyw"):
            for fpath in root.glob(f"**/*{ext}"):
                parts = fpath.relative_to(root).parts
                if any(p.startswith(".") or p in ("venv", "node_modules", "__pycache__", "dist", "build", ".git") for p in parts):
                    continue
                try:
                    data = fpath.read_bytes()
                    result[str(fpath)] = hashlib.sha256(data).hexdigest()
                except OSError:
                    pass
        return result

    if source_dir:
        file_hashes = _hash_files(source_dir)
        print(f"  Watching {source_dir} ({len(file_hashes)} files, interval={interval}s)")

    # Track memory DB mtime for change detection
    last_mem_mtime: float = 0.0
    if mem_db_path and os.path.exists(mem_db_path):
        last_mem_mtime = os.path.getmtime(mem_db_path)

    print("  Watch mode active. Press Ctrl+C to stop.")
    while True:
        time.sleep(interval)

        changed = False
        if source_dir:
            current = _hash_files(source_dir)
            if set(current.items()) != set(file_hashes.items()):
                changed = True
                file_hashes = current

        if mem_db_path and os.path.exists(mem_db_path):
            current_mtime = os.path.getmtime(mem_db_path)
            if current_mtime != last_mem_mtime:
                changed = True
                last_mem_mtime = current_mtime

        if changed:
            print(f"  [{time.strftime('%H:%M:%S')}] File changes detected, rebuilding...")
            try:
                incremental_update(
                    graph_db_path,
                    mem_db_path=mem_db_path,
                    source_dir=source_dir,
                    **kwargs,
                )
                from .graph_db import load_from_graph_db
                reloaded = load_from_graph_db(graph_db_path)
                print(f"  Rebuilt: {len(reloaded.nodes)} nodes, {len(reloaded.edges)} edges")
            except (OSError, ValueError, KeyError) as exc:
                logger.warning("Rebuild failed: %s", exc)