"""Incremental rebuild and --watch mode for kgraph.

Detects file changes and rebuilds the graph incrementally (or fully)
when source content changes. Supports both file-system watchers and
manual --update invocations.

--update: rebuild graph from scratch, preserving user edits
--watch: stay running, auto-rebuild on file changes
"""

import os
import time
import hashlib
from pathlib import Path


def incremental_update(graph_db_path: str, mem_db_path: str | None = None,
                       source_dir: str | None = None, **kwargs) -> dict:
    """Perform an incremental (or full) rebuild of the graph.

    Strategy:
    1. Load existing user-saved graph from graph_db
    2. Merge in fresh data from memory DB (if available)
    3. Optionally run AST extraction on source_dir to inject code concepts
    4. Re-run community detection, confidence tagging, etc.
    5. Save updated graph back to graph_db

    Returns:
        The merged graph dict.
    """
    from .graph_db import load_from_graph_db, save_to_graph_db
    from .memory_import import load_from_memory_db
    from .confidence import tag_confidence
    from .community import detect_communities
    from .ast_extractor import ast_available, extract_repo_graph

    graph = {'nodes': [], 'edges': []}

    # 1. Load existing user graph
    if graph_db_path and os.path.exists(os.path.expanduser(graph_db_path)):
        user_graph = load_from_graph_db(graph_db_path)
        if user_graph.get('nodes') or user_graph.get('edges'):
            graph = user_graph

    # 2. Merge memory DB data
    if mem_db_path and os.path.exists(mem_db_path):
        try:
            mem_graph = load_from_memory_db(mem_db_path)
            graph = merge_graphs(graph, mem_graph)
        except Exception as e:
            print(f'  [warn] Memory DB import failed: {e}')

    # 3. AST extraction
    ast_run = kwargs.get('ast', True)
    if ast_run and source_dir and ast_available():
        try:
            ast_graph = extract_repo_graph(source_dir,
                                            include_variables=kwargs.get('ast_vars', False),
                                            max_files=kwargs.get('ast_max_files', 0),
                                            subdirs=kwargs.get('ast_subdirs', None))
            if ast_graph.get('nodes'):
                graph = merge_graphs(graph, ast_graph)
                print(f'  AST: {len(ast_graph["nodes"])} nodes, {len(ast_graph["edges"])} edges from {source_dir}')
        except Exception as e:
            print(f'  [warn] AST extraction failed: {e}')

    # 4. Confidence tagging
    graph = tag_confidence(graph)

    # 5. Community detection
    graph = detect_communities(graph)

    # 6. Save
    if graph_db_path:
        save_to_graph_db(graph_db_path, graph)

    return graph


def merge_graphs(base: dict, overlay: dict) -> dict:
    """Merge overlay graph into base, deduplicating by id."""
    merged = {'nodes': list(base.get('nodes', [])), 'edges': []}
    seen_nodes = set()
    seen_edges = set()

    for n in base.get('nodes', []):
        nid = str(n.get('id', ''))
        if nid:
            seen_nodes.add(nid)

    for n in overlay.get('nodes', []):
        nid = str(n.get('id', ''))
        if nid and nid not in seen_nodes:
            seen_nodes.add(nid)
            merged['nodes'].append(n)

    for e in base.get('edges', []):
        src = str(e.get('from', e.get('source', '')))
        dst = str(e.get('to', e.get('target', '')))
        lbl = str(e.get('label', ''))
        key = (src, dst, lbl)
        if key not in seen_edges:
            seen_edges.add(key)
            merged['edges'].append(e)

    for e in overlay.get('edges', []):
        src = str(e.get('from', e.get('source', '')))
        dst = str(e.get('to', e.get('target', '')))
        lbl = str(e.get('label', ''))
        key = (src, dst, lbl)
        if key not in seen_edges:
            seen_edges.add(key)
            merged['edges'].append(e)

    return merged


def start_watch(graph_db_path: str, mem_db_path: str | None = None,
                source_dir: str | None = None, interval: int = 30, **kwargs):
    """Watch directories and auto-rebuild on changes.

    Polls for file changes at the given interval. When detected,
    runs incremental_update().

    Args:
        graph_db_path: Path to graph SQLite DB.
        mem_db_path: Path to memory DB for re-import.
        source_dir: Repo root for AST extraction.
        interval: Poll interval in seconds.
    """

    # Track file hashes
    file_hashes = {}

    def _hash_files(directory: str) -> dict:
        result = {}
        root = Path(directory).resolve()
        for ext in ('.py', '.sh', '.bash', '.zsh', '.pyw'):
            for fpath in root.glob(f'**/*{ext}'):
                parts = fpath.relative_to(root).parts
                if any(p.startswith('.') or p in ('venv', 'node_modules', '__pycache__', 'dist', 'build', '.git') for p in parts):
                    continue
                try:
                    with open(fpath, 'rb') as f:
                        data = f.read()
                    result[str(fpath)] = hashlib.md5(data).hexdigest()
                except (OSError, IOError):
                    pass
        return result

    if source_dir:
        file_hashes = _hash_files(source_dir)
        print(f'  Watching {source_dir} ({len(file_hashes)} files, interval={interval}s)')

    print('  Watch mode active. Press Ctrl+C to stop.')
    while True:
        time.sleep(interval)

        changed = False
        if source_dir:
            current = _hash_files(source_dir)
            if set(current.items()) != set(file_hashes.items()):
                changed = True
                file_hashes = current

        if mem_db_path and os.path.exists(mem_db_path):
            os.path.getmtime(mem_db_path)
            # We rely on file watcher or explicit changes to memory DB
            pass

        if changed:
            print(f'  [{time.strftime("%H:%M:%S")}] File changes detected, rebuilding...')
            try:
                incremental_update(
                    graph_db_path,
                    mem_db_path=mem_db_path,
                    source_dir=source_dir,
                    **kwargs
                )
                from .graph_db import load_from_graph_db
                reloaded = load_from_graph_db(graph_db_path)
                print(f'  Rebuilt: {len(reloaded.get("nodes", []))} nodes, {len(reloaded.get("edges", []))} edges')
            except Exception as exp:
                print(f'  [warn] Rebuild failed: {exp}')
