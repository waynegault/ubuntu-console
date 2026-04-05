"""CLI entry point.

Exports main() — the argparse-based command-line interface that
supports --output, --serve, --graph, --store, --graph-db, --view,
--semantic-threshold, --host, --port, --import-db, --install, and
--embed flags.
"""
import argparse
import os
import json
import tempfile
import shutil
from .constants import GRAPH_DB_DEFAULT, SAMPLE_GRAPH
from .graph_db import resolve_memory_db_path, load_from_graph_db
from .html import generate_html, ensure_parent_dir
from .memory_import import load_from_memory_db
from .server import serve_file


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', '-o', help='Write HTML to this path')
    parser.add_argument('--serve', action='store_true', help='Serve generated page and open browser')
    parser.add_argument('--graph', help='Path to a JSON file with nodes/edges')
    parser.add_argument('--store', help='Path to persistent graph JSON (default: ~/.openclaw/kgraph.json)')
    parser.add_argument('--graph-db', help=f'Path to persistent graph SQLite DB (default: {GRAPH_DB_DEFAULT})')
    parser.add_argument('--view', choices=['overview', 'topics', 'files', 'semantic', 'raw'], default='overview', help='Initial graph view/projection (default: overview)')
    parser.add_argument('--semantic-threshold', type=float, default=0.82, help='Minimum semantic score shown in semantic/overview views (default: 0.82)')
    parser.add_argument('--host', help='Host to bind server to (default 127.0.0.1)', default='127.0.0.1')
    parser.add_argument('--port', type=int, help='Port to bind server to (default ephemeral)', default=0)
    parser.add_argument('--import-db', help='Import nodes/edges from SQLite memory DB and use as graph')
    parser.add_argument('--install', nargs='?', const='~/.openclaw/kgraph.py', help='Copy this script to target path and make executable')
    parser.add_argument('--embed', action='store_true', help='Serve the generated embedded HTML instead of a built frontend')
    args = parser.parse_args()

    graph = SAMPLE_GRAPH
    if args.graph:
      with open(args.graph, 'r', encoding='utf-8') as gf:
        graph = json.load(gf)

    graph_db = args.graph_db or os.path.expanduser(GRAPH_DB_DEFAULT)
    # Prefer importing from the OpenClaw memory DB when available or requested.
    # Supports legacy and current OpenClaw layouts.
    default_memory_db = resolve_memory_db_path()
    import_db_path = None
    if args.import_db:
      import_db_path = resolve_memory_db_path(args.import_db)
    elif default_memory_db and os.path.exists(default_memory_db):
      import_db_path = default_memory_db

    if import_db_path:
      try:
        db_graph = load_from_memory_db(import_db_path)
        # Only use DB contents for the embedded HTML if it contains data.
        if db_graph.get('nodes') or db_graph.get('edges'):
          graph = db_graph
          print('Imported graph from', import_db_path)
        else:
          print('Memory DB present but empty; using fallback store/sample')
      except Exception as e:
        print('Failed to import DB:', e)

    # Prefer user graph DB over memory DB/sample for embedded HTML preview.
    if (not args.graph) and os.path.exists(os.path.expanduser(graph_db)):
      try:
        user_graph = load_from_graph_db(graph_db)
        if user_graph.get('nodes') or user_graph.get('edges'):
          graph = user_graph
          print('Using graph DB for embedded HTML:', graph_db)
      except Exception:
        pass

    # If after attempting DB import we still don't have a user graph, prefer
    # the persistent JSON store so embedded HTML shows the saved graph.
    default_store = args.store or os.path.expanduser('~/.openclaw/kgraph.json')
    if (not args.graph) and os.path.isfile(default_store):
      try:
        with open(default_store, 'r', encoding='utf-8') as sf:
          graph = json.load(sf)
          print('Using store for embedded HTML:', default_store)
      except Exception:
        pass

    outpath = args.output or os.path.join(tempfile.gettempdir(), 'kgraph.html')
    generate_html(graph, outpath)
    print('Wrote', outpath)

    if args.install:
      dest = os.path.expanduser(args.install)
      ensure_parent_dir(dest)
      shutil.copy2(__file__, dest)
      os.chmod(dest, 0o755)
      print('Installed to', dest)

    if args.serve:
      serve_file(outpath, host=args.host, port=args.port, store_path=(args.store or None), force_embed=args.embed, graph_db_path=graph_db, view_mode=args.view, semantic_threshold=args.semantic_threshold)


if __name__ == "__main__":
    main()
