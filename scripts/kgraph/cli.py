"""CLI entry point.

Exposes:
- kgraph --serve (existing)
- kgraph --update (new incremental rebuild)
- kgraph --watch (new file watcher)
- kgraph --report (generate GRAPH_REPORT.md)
- kgraph --ast (extract AST from repo)
- kgraph --communities (detect communities)
- kgraph --god-nodes (list central nodes)
- kgraph --query / --path / --explain (navigation tools)
- kgraph --call-flow (generate call-flow HTML/Mermaid)
- kgraph --mcp (serve MCP server for tool-call access)
- kgraph --confidence (show confidence stats)
- kgraph --pr-dashboard (generate PR dashboard HTML)
- kgraph --benchmark (run token-reduction benchmark)
- kgraph --audit (show security audit report)
- kgraph --install-hook / --uninstall-hook (git hooks)
"""
import argparse
import os
import json
import sys
import tempfile
from .constants import GRAPH_DB_DEFAULT, SAMPLE_GRAPH
from .graph_db import resolve_memory_db_path, load_from_graph_db
from .html import generate_html
from .memory_import import load_from_memory_db
from .server import serve_file
from .confidence import tag_confidence, confidence_stats
from .community import detect_communities, find_god_nodes, communities_available
from .report import generate_report
from .ast_extractor import ast_available, extract_repo_graph
from .query import query_nodes, find_path, explain_node, format_explain, format_path
from .call_flow import generate_call_flow_mermaid, generate_call_flow_html
from .update import incremental_update, start_watch


def _load_graph(args) -> dict:
    """Load graph from best available source (CLI args, graph DB, memory DB, sample)."""
    graph = SAMPLE_GRAPH

    if args.graph:
        with open(args.graph, 'r', encoding='utf-8') as gf:
            graph = json.load(gf)
        return graph

    graph_db = args.graph_db or os.path.expanduser(GRAPH_DB_DEFAULT)
    memory_db = args.import_db or resolve_memory_db_path()

    if os.path.exists(os.path.expanduser(graph_db)):
        try:
            g = load_from_graph_db(graph_db)
            if g.get('nodes') or g.get('edges'):
                graph = g
                return graph
        except Exception:
            pass

    if memory_db and os.path.exists(memory_db):
        try:
            g = load_from_memory_db(memory_db)
            if g.get('nodes') or g.get('edges'):
                graph = g
        except Exception:
            pass

    return graph


def main():
    parser = argparse.ArgumentParser(prog='kgraph',
        description='Knowledge graph — server, AST extraction, community detection, MCP, and CLI tools')

    # ── Mode (mutually-exclusive-ish) ──
    parser.add_argument('--serve', action='store_true', help='Serve graph viewer in browser')
    parser.add_argument('--update', action='store_true', help='Incremental rebuild from memory DB + AST')
    parser.add_argument('--watch', action='store_true', help='Watch files and auto-rebuild')
    parser.add_argument('--report', action='store_true', help='Generate GRAPH_REPORT.md')
    parser.add_argument('--ast', action='store_true', help='Extract AST code concepts from a repo')
    parser.add_argument('--communities', action='store_true', help='Detect communities/clusters')
    parser.add_argument('--god-nodes', action='store_true', help='List most central nodes')
    parser.add_argument('--call-flow', action='store_true', help='Generate call-flow HTML/Mermaid')
    parser.add_argument('--mcp', action='store_true', help='Serve MCP JSON-RPC server')
    parser.add_argument('--confidence', action='store_true', help='Show confidence stats for edges')
    parser.add_argument('--pr-dashboard', action='store_true', help='Generate PR dashboard HTML')
    parser.add_argument('--benchmark', action='store_true', help='Run token-reduction benchmark')
    parser.add_argument('--audit', action='store_true', help='Show security audit report')
    parser.add_argument('--install-hook', action='store_true', help='Install git post-commit hook')
    parser.add_argument('--uninstall-hook', action='store_true', help='Remove git post-commit hook')

    # Query tools
    parser.add_argument('--query', help='Search nodes matching a pattern')
    parser.add_argument('--path', nargs=2, metavar=('SOURCE', 'TARGET'), help='Shortest path between two nodes')
    parser.add_argument('--explain', help='Describe a node and its graph connections')

    # Shared I/O
    parser.add_argument('--output', '-o', help='Output file path')
    parser.add_argument('--graph', help='Path to graph JSON file')
    parser.add_argument('--store', help='Path to persistent graph JSON store')
    parser.add_argument('--graph-db', default=GRAPH_DB_DEFAULT, help=f'SQLite graph DB path (default: {GRAPH_DB_DEFAULT})')
    parser.add_argument('--import-db', help='Memory SQLite DB path (overrides auto-detect)')
    parser.add_argument('--host', default='127.0.0.1', help='Server bind host')
    parser.add_argument('--port', type=int, default=0, help='Server port (0 = ephemeral)')
    parser.add_argument('--view', choices=['overview', 'topics', 'files', 'semantic', 'raw'], default='overview')
    parser.add_argument('--semantic-threshold', type=float, default=0.82)
    parser.add_argument('--embed', action='store_true', help='Force embedded HTML mode')

    # AST
    parser.add_argument('--repo', help='Repository root for AST extraction')
    parser.add_argument('--ast-vars', action='store_true', help='Include variable nodes')
    parser.add_argument('--ast-max-files', type=int, default=0, help='Max source files to parse (0=unlimited)')
    parser.add_argument('--ast-subdirs', nargs='*', help='Subdirs to scan (default: all)')

    # Analysis
    parser.add_argument('--report-path', default='GRAPH_REPORT.md', help='Report output path')
    parser.add_argument('--community-method', choices=['louvain', 'greedy'], default='louvain')
    parser.add_argument('--min-community-size', type=int, default=2)
    parser.add_argument('--top-god-nodes', type=int, default=10)

    # Watch / update
    parser.add_argument('--watch-interval', type=int, default=30, help='Poll interval in seconds')
    parser.add_argument('--source-dir', help='Source directory for AST + watch')

    # PR dashboard / benchmark
    parser.add_argument('--days', type=int, default=30, help='History window in days')
    parser.add_argument('--author', help='Filter by author')
    parser.add_argument('--max-prs', type=int, default=30, help='Max PRs/merges to include')

    args = parser.parse_args()

    # ── Resolve graph early for query/path/explain/report/confidence ──
    needs_graph = bool(args.query or args.path or args.explain or
                       args.communities or args.god_nodes or args.call_flow or
                       args.confidence or args.report or args.benchmark or
                       args.pr_dashboard)
    if needs_graph:
        graph = _load_graph(args)

    # ── AST extraction ──
    if args.ast:
        if not args.repo:
            print('Error: --repo is required for AST extraction', file=sys.stderr)
            sys.exit(1)
        if not ast_available():
            print('Error: tree-sitter not available. Install with: pip install tree-sitter tree-sitter-bash tree-sitter-python', file=sys.stderr)
            sys.exit(1)
        g = extract_repo_graph(args.repo, include_variables=args.ast_vars,
                                max_files=args.ast_max_files, subdirs=args.ast_subdirs)
        g = tag_confidence(g)
        s = confidence_stats(g)
        print(f'AST extraction: {len(g["nodes"])} nodes, {len(g["edges"])} edges')
        print(f'Confidence: {s["extracted"]} EXTRACTED, {s["inferred"]} INFERRED, {s["ambiguous"]} AMBIGUOUS')
        if args.output:
            with open(args.output, 'w', encoding='utf-8') as f:
                json.dump(g, f, indent=2)
            print(f'Saved to {args.output}')
        else:
            print(json.dumps(g, indent=2))
        return

    # ── Git hooks ──
    if args.install_hook or args.uninstall_hook:
        hook_dir = os.path.join(os.getcwd() if os.path.isdir('.git') else '', '.git', 'hooks')
        if not os.path.isdir(hook_dir):
            # Try finding .git from cwd
            cwd = os.getcwd()
            while cwd:
                if os.path.isdir(os.path.join(cwd, '.git')):
                    hook_dir = os.path.join(cwd, '.git', 'hooks')
                    break
                parent = os.path.dirname(cwd)
                if parent == cwd:
                    break
                cwd = parent
        if not os.path.isdir(hook_dir):
            print('Error: not in a git repository', file=sys.stderr)
            sys.exit(1)

        if args.install_hook:
            hook = '#!/bin/bash\n# kgraph auto-rebuild post-commit hook\nif command -v kgraph &>/dev/null; then\n    kgraph --update --source-dir "$(git rev-parse --show-toplevel)" 2>&1 | sed \'s/^/[kgraph] /\'\nfi\n'
            with open(os.path.join(hook_dir, 'post-commit'), 'w') as f:
                f.write(hook)
            os.chmod(os.path.join(hook_dir, 'post-commit'), 0o755)
            print(f'Installed post-commit hook in {hook_dir}')
            # Also post-merge
            with open(os.path.join(hook_dir, 'post-merge'), 'w') as f:
                f.write(hook)
            os.chmod(os.path.join(hook_dir, 'post-merge'), 0o755)
            print(f'Installed post-merge hook in {hook_dir}')
        else:
            for name in ('post-commit', 'post-merge'):
                path = os.path.join(hook_dir, name)
                if os.path.exists(path):
                    os.remove(path)
                    print(f'Removed {path}')
        return

    # ── Update mode ──
    if args.update:
        graph_db = os.path.expanduser(args.graph_db)
        mem_db = args.import_db or resolve_memory_db_path()
        src = args.source_dir or args.repo
        g = incremental_update(graph_db, mem_db_path=mem_db, source_dir=src,
                                ast=bool(src), ast_vars=args.ast_vars,
                                ast_max_files=args.ast_max_files, ast_subdirs=args.ast_subdirs)
        s = confidence_stats(g)
        print(f'Update complete: {len(g["nodes"])} nodes, {len(g["edges"])} edges')
        print(f'  EXTRACTED: {s["extracted"]}, INFERRED: {s["inferred"]}, AMBIGUOUS: {s["ambiguous"]}')
        if args.output:
            with open(args.output, 'w', encoding='utf-8') as f:
                json.dump(g, f, indent=2)
        return

    # ── Watch mode ──
    if args.watch:
        graph_db = os.path.expanduser(args.graph_db)
        mem_db = args.import_db or resolve_memory_db_path()
        src = args.source_dir or args.repo
        start_watch(graph_db, mem_db_path=mem_db, source_dir=src,
                     interval=args.watch_interval, ast=bool(src),
                     ast_vars=args.ast_vars, ast_max_files=args.ast_max_files,
                     ast_subdirs=args.ast_subdirs)
        return

    # ── MCP server ──
    if args.mcp:
        from .mcp_server import serve_mcp
        serve_mcp(host=args.host, port=args.port or 8331, graph_db=args.graph_db)
        return

    # ── Query tools ──
    if args.query:
        results = query_nodes(graph, args.query)
        if not results:
            print(f'No nodes matching "{args.query}"')
        else:
            print(f'{len(results)} matching nodes:')
            for n in results:
                print(f'  [{n.get("type","?")}] {n.get("label","")} ({n.get("id","")})')
        return

    if args.path:
        print(format_path(find_path(graph, args.path[0], args.path[1])))
        return

    if args.explain:
        print(format_explain(explain_node(graph, args.explain)))
        return

    # ── Communities / god nodes ──
    if args.communities:
        if not communities_available():
            print('Error: networkx not available. pip install networkx', file=sys.stderr)
            sys.exit(1)
        g = detect_communities(graph, method=args.community_method, min_community_size=args.min_community_size)
        clusters = (g.get('_meta') or {}).get('communities', [])
        if not clusters:
            print('No communities detected')
        else:
            print(f'{len(clusters)} communities:')
            for c in clusters:
                print(f'  {c["label"]} — {c["size"]} members')
        return

    if args.god_nodes:
        if not communities_available():
            print('Error: networkx not available. pip install networkx', file=sys.stderr)
            sys.exit(1)
        gods = find_god_nodes(graph, top_n=args.top_god_nodes)
        if not gods:
            print('No god nodes found')
        else:
            print(f'Top {len(gods)} god nodes:')
            for idx, gn in enumerate(gods, 1):
                print(f'  {idx}. {gn["label"][:35]:35s} score={gn["composite_score"]:.3f}  deg={gn["degree"]}')
        return

    # ── Call flow ──
    if args.call_flow:
        if args.output and args.output.endswith('.html'):
            html = generate_call_flow_html(graph)
            with open(args.output, 'w', encoding='utf-8') as f:
                f.write(html)
            print(f'Written to {args.output}')
        else:
            print(generate_call_flow_mermaid(graph))
        return

    # ── Confidence stats ──
    if args.confidence:
        g = tag_confidence(graph)
        s = confidence_stats(g)
        print('Edge confidence:')
        print(f'  Total: {s["total"]}')
        print(f'  EXTRACTED: {s["extracted"]} ({s["extracted_pct"]}%)')
        print(f'  INFERRED:  {s["inferred"]} ({s["inferred_pct"]}%)')
        print(f'  AMBIGUOUS: {s["ambiguous"]} ({s["ambiguous_pct"]}%)')
        return

    # ── GRAPH_REPORT.md ──
    if args.report:
        print(generate_report(graph, outpath=args.report_path))
        return

    # ── PR dashboard ──
    if args.pr_dashboard:
        from .pr_dashboard import generate_pr_dashboard
        out = args.output or 'kgraph_pr_dashboard.html'
        generate_pr_dashboard(os.getcwd(), days=args.days, graph_data=graph,
                               output_path=out, author=args.author, max_prs=args.max_prs)
        print(f'Written to {out}')
        return

    # ── Benchmark ──
    if args.benchmark:
        from .benchmark import benchmark_graph_vs_raw, print_benchmark
        out = args.output or 'benchmark_results.json'
        result = benchmark_graph_vs_raw(graph, output_path=out)
        print_benchmark(result)
        return

    # ── Security audit ──
    if args.audit:
        audit_path = os.path.join(os.path.dirname(__file__), 'audit_security.md')
        if os.path.exists(audit_path):
            with open(audit_path) as f:
                print(f.read())
        else:
            print('Security audit report not found at', audit_path)
        return

    # ── Default: generate HTML + optionally serve ──
    g = _load_graph(args)
    outpath = args.output or os.path.join(tempfile.gettempdir(), 'kgraph.html')
    generate_html(g, outpath)
    print('Wrote', outpath)

    if args.serve:
        serve_file(outpath, host=args.host, port=args.port,
                   store_path=args.store, force_embed=args.embed,
                   graph_db_path=os.path.expanduser(args.graph_db),
                   view_mode=args.view, semantic_threshold=args.semantic_threshold)
    else:
        parser.print_help()


if __name__ == '__main__':
    main()
