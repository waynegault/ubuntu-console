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
"""
import argparse
import os
import json
import sys
from .constants import GRAPH_DB_DEFAULT, SAMPLE_GRAPH, MEMORY_DB_CANDIDATES, load_canonical_data, normalize_canonical_name
from .graph_db import resolve_memory_db_path, load_from_graph_db, save_to_graph_db
from .html import generate_html, ensure_parent_dir
from .memory_import import load_from_memory_db
from .server import serve_file
from .confidence import tag_confidence, confidence_stats
from .community import detect_communities, find_god_nodes, communities_available
from .report import generate_report
from .ast_extractor import ast_available, extract_repo_graph
from .query import query_nodes, find_path, explain_node, format_explain, format_path
from .call_flow import generate_call_flow_mermaid, generate_call_flow_html
from .update import incremental_update, start_watch
from .git_hook import install_hook, uninstall_hook


def _load_graph(args) -> dict:
    """Load graph from best available source (CLI args, graph DB, memory DB, sample)."""
    graph = SAMPLE_GRAPH

    if args.graph:
        with open(args.graph, 'r', encoding='utf-8') as gf:
            graph = json.load(gf)
        return graph

    graph_db = args.graph_db or os.path.expanduser(GRAPH_DB_DEFAULT)
    memory_db = args.import_db or resolve_memory_db_path()

    # From graph DB
    if os.path.exists(os.path.expanduser(graph_db)):
        try:
            g = load_from_graph_db(graph_db)
            if g.get('nodes') or g.get('edges'):
                graph = g
                return graph
        except Exception:
            pass

    # From memory DB
    if memory_db and os.path.exists(memory_db):
        try:
            g = load_from_memory_db(memory_db)
            if g.get('nodes') or g.get('edges'):
                graph = g
        except Exception:
            pass

    return graph


def main():
    parser = argparse.ArgumentParser(prog='kgraph')

    # Top-level commands (mutually exclusive-ish)
    parser.add_argument('--serve', action='store_true', help='Serve graph viewer and open browser')
    parser.add_argument('--install-hook', action='store_true', help='Install git post-commit hook for auto-rebuild')
    parser.add_argument('--uninstall-hook', action='store_true', help='Remove git post-commit hook')
    parser.add_argument('--update', action='store_true', help='Incremental rebuild of graph from memory DB + AST')
    parser.add_argument('--watch', action='store_true', help='Watch for file changes and auto-rebuild')
    parser.add_argument('--report', action='store_true', help='Generate GRAPH_REPORT.md')
    parser.add_argument('--ast', action='store_true', help='Extract AST code concepts from a repo')
    parser.add_argument('--communities', action='store_true', help='Detect communities/clusters in graph')
    parser.add_argument('--god-nodes', action='store_true', help='List most central nodes')
    parser.add_argument('--call-flow', action='store_true', help='Generate call-flow HTML/Mermaid')
    parser.add_argument('--validate', help='Validate a graph JSON file against schema')
    parser.add_argument('--pr-dashboard', action='store_true', help='Generate PR dashboard HTML (requires gh CLI)')
    parser.add_argument('--security-check', help='Run security checks on a graph JSON file')
    parser.add_argument('--mcp', action='store_true', help='Serve MCP server')
    parser.add_argument('--confidence', action='store_true', help='Show confidence stats for edges')

    # Query tools
    parser.add_argument('--query', help='Query nodes matching pattern')
    parser.add_argument('--path', nargs=2, metavar=('SOURCE', 'TARGET'), help='Find shortest path')
    parser.add_argument('--explain', help='Describe a node and its connections')

    # Shared options
    parser.add_argument('--output', '-o', help='Write output to this path')
    parser.add_argument('--graph', help='Path to a JSON file with nodes/edges')
    parser.add_argument('--store', help='Path to persistent graph JSON')
    parser.add_argument('--graph-db', help=f'Path to graph SQLite DB (default: {GRAPH_DB_DEFAULT})')
    parser.add_argument('--view', choices=['overview', 'topics', 'files', 'semantic', 'raw'], default='overview')
    parser.add_argument('--semantic-threshold', type=float, default=0.82)
    parser.add_argument('--host', default='127.0.0.1', help='Host for server (default 127.0.0.1)')
    parser.add_argument('--port', type=int, default=0, help='Port (default ephemeral)')
    parser.add_argument('--import-db', help='Path to memory SQLite DB')
    parser.add_argument('--embed', action='store_true')

    # AST-specific
    parser.add_argument('--repo', help='Repository root path for AST extraction')
    parser.add_argument('--ast-vars', action='store_true', help='Include variable nodes in AST extract')
    parser.add_argument('--ast-max-files', type=int, default=0, help='Max files to parse (0=unlimited)')
    parser.add_argument('--ast-subdirs', nargs='*', help='Subdirs to scan (default: all)')

    # Report / update options
    parser.add_argument('--report-path', default='GRAPH_REPORT.md', help='Output path for report')
    parser.add_argument('--community-method', choices=['louvain', 'greedy'], default='louvain')
    parser.add_argument('--min-community-size', type=int, default=2)
    parser.add_argument('--top-god-nodes', type=int, default=10)

    # Watch options
    parser.add_argument('--watch-interval', type=int, default=30, help='Watch poll interval in seconds')
    parser.add_argument('--source-dir', help='Source directory for AST + watch')

    args = parser.parse_args()

    # ── AST extraction mode ──
    if args.ast:
        if not args.repo:
            print('Error: --repo is required for AST extraction')
            sys.exit(1)
        if not ast_available():
            print('Error: tree-sitter not available. Install: pip install tree-sitter tree-sitter-bash tree-sitter-python')
            sys.exit(1)
        graph = extract_repo_graph(
            args.repo,
            include_variables=args.ast_vars,
            max_files=args.ast_max_files,
            subdirs=args.ast_subdirs,
        )
        print(f'AST extraction: {len(graph["nodes"])} nodes, {len(graph["edges"])} edges')

        # Tag confidence
        graph = tag_confidence(graph)
        stats = confidence_stats(graph)
        print(f'Confidence: {stats["extracted"]} EXTRACTED, {stats["inferred"]} INFERRED, {stats["ambiguous"]} AMBIGUOUS')

        if args.output:
            with open(args.output, 'w', encoding='utf-8') as f:
                json.dump(graph, f, indent=2)
            print(f'Saved to {args.output}')
        else:
            print(json.dumps(graph, indent=2))
        return

    # ── Git hook mode ──
    if args.install_hook:
        print(install_hook())
        return

    if args.uninstall_hook:
        print(uninstall_hook())
        return

    # ── Update mode ──
    if args.update:
        graph_db = args.graph_db or os.path.expanduser(GRAPH_DB_DEFAULT)
        mem_db = args.import_db or resolve_memory_db_path()
        src = args.source_dir or args.repo
        graph = incremental_update(
            graph_db,
            mem_db_path=mem_db,
            source_dir=src,
            ast=bool(src),
            ast_vars=args.ast_vars,
            ast_max_files=args.ast_max_files,
            ast_subdirs=args.ast_subdirs,
        )
        print(f'Update complete: {len(graph["nodes"])} nodes, {len(graph["edges"])} edges')
        print(f'  Confidence stats: {confidence_stats(graph)}')

        if args.output:
            with open(args.output, 'w', encoding='utf-8') as f:
                json.dump(graph, f, indent=2)
        return

    # ── Watch mode ──
    if args.watch:
        graph_db = args.graph_db or os.path.expanduser(GRAPH_DB_DEFAULT)
        mem_db = args.import_db or resolve_memory_db_path()
        src = args.source_dir or args.repo
        start_watch(
            graph_db,
            mem_db_path=mem_db,
            source_dir=src,
            interval=args.watch_interval,
            ast=bool(src),
            ast_vars=args.ast_vars,
            ast_max_files=args.ast_max_files,
            ast_subdirs=args.ast_subdirs,
        )
        return

    # ── Validate mode ──
    if args.validate:
        from .validate import validate_graph_file
        errors = validate_graph_file(args.validate)
        if errors:
            print(f'Validation FAILED: {len(errors)} error(s)')
            for err in errors:
                print(f'  [{err.get("severity","error")}] {err.get("message","")}')
            sys.exit(1)
        else:
            print(f'{args.validate}: validation PASSED')
        return

    # ── PR Dashboard mode ──
    if args.pr_dashboard:
        from .pr_dashboard import fetch_prs, generate_dashboard
        prs = fetch_prs()
        output = getattr(args, 'output', None) or 'kgraph_pr_dashboard.html'
        generate_dashboard(prs, output)
        return

    # ── Security check mode ──
    if args.security_check:
        from .security import check_graph_security
        issues = check_graph_security(args.security_check)
        if issues:
            print(f'Security check: {len(issues)} issue(s)')
            for issue in issues:
                print(f'  [{issue.get("severity","info")}] [{issue.get("type","unknown")}] {issue.get("message","")}')
            sys.exit(1)
        else:
            print(f'{args.security_check}: security check PASSED')
        return

    # ── MCP server ──
    if args.mcp:
        from .mcp_server import serve_mcp
        graph_db = args.graph_db or os.path.expanduser(GRAPH_DB_DEFAULT)
        serve_mcp(host=args.host, port=args.port or 8331, graph_db=graph_db)
        return

    # ── Query tools ──
    graph = _load_graph(args)

    if args.query:
        results = query_nodes(graph, args.query)
        if not results:
            print(f'No nodes matching "{args.query}"')
        else:
            print(f'{len(results)} matching nodes:')
            for n in results:
                nid = str(n.get('id', ''))
                label = str(n.get('label', ''))
                ntype = str(n.get('type', ''))
                print(f'  [{ntype}] {label} ({nid})')
        return

    if args.path:
        src, tgt = args.path
        path = find_path(graph, src, tgt)
        print(format_path(path))
        return

    if args.explain:
        explanation = explain_node(graph, args.explain)
        print(format_explain(explanation))
        return

    # ── Communities / god nodes ──
    if args.communities:
        if not communities_available():
            print('Error: networkx not available. pip install networkx')
            sys.exit(1)
        graph = detect_communities(graph, method=args.community_method,
                                    min_community_size=args.min_community_size)
        communities = (graph.get('_meta') or {}).get('communities', [])
        if not communities:
            print('No communities detected (graph may be too small)')
        else:
            print(f'{len(communities)} communities found:')
            for c in communities:
                print(f'  {c["label"]} — {c["size"]} members')
        return

    if args.god_nodes:
        if not communities_available():
            print('Error: networkx not available. pip install networkx')
            sys.exit(1)
        gods = find_god_nodes(graph, top_n=args.top_god_nodes)
        if not gods:
            print('No god nodes found (graph may be too small)')
        else:
            print(f'Top {len(gods)} god nodes:')
            print(f'  {"Rank":<6} {"Label":<30} {"Composite":<10} {"Degree":<8} {"Betweenness":<12} {"Eigenvector":<12}')
            for idx, gn in enumerate(gods, 1):
                print(f'  {idx:<6} {gn["label"][:29]:<30} {gn["composite_score"]:<10.3f} {gn["degree"]:<8} {gn["betweenness"]:<12.4f} {gn["eigenvector"]:<12.4f}')
        return

    # ── Call flow export ──
    if args.call_flow:
        mermaid = generate_call_flow_mermaid(graph)
        html = generate_call_flow_html(graph, title=args.output or 'Call Flow')

        if args.output:
            if args.output.endswith('.html'):
                with open(args.output, 'w', encoding='utf-8') as f:
                    f.write(html)
            else:
                with open(args.output + '.md', 'w', encoding='utf-8') as f:
                    f.write(mermaid)
        else:
            print(mermaid)
        return

    # ── Confidence stats ──
    if args.confidence:
        graph = tag_confidence(graph)
        stats = confidence_stats(graph)
        print(f'Edge confidence stats:')
        print(f'  Total edges: {stats["total"]}')
        print(f'  EXTRACTED:   {stats["extracted"]} ({stats["extracted_pct"]}%)')
        print(f'  INFERRED:    {stats["inferred"]} ({stats["inferred_pct"]}%)')
        print(f'  AMBIGUOUS:   {stats["ambiguous"]} ({stats["ambiguous_pct"]}%)')
        return

    # ── Report generation ──
    if args.report:
        graph_db = args.graph_db or os.path.expanduser(GRAPH_DB_DEFAULT)
        if args.graph:
            pass  # already loaded
        elif os.path.exists(os.path.expanduser(graph_db)):
            graph = load_from_graph_db(graph_db)
        report = generate_report(graph, title='Knowledge Graph Report', outpath=args.report_path)
        print(report[:500] + '...' if len(report) > 500 else report)
        print(f'\nFull report written to {args.report_path}')
        return

    # ── Default: serve mode ──
    graph_db = args.graph_db or os.path.expanduser(GRAPH_DB_DEFAULT)
    default_store = args.store or os.path.expanduser('~/.openclaw/kgraph.json')

    outpath = args.output or os.path.join(tempfile.gettempdir() if 'tempfile' in dir() else '/tmp', 'kgraph.html')
    import tempfile
    outpath = args.output or os.path.join(tempfile.gettempdir(), 'kgraph.html')

    # Build graph for embedded HTML
    if not args.graph:
        g = _load_graph(args)
    else:
        with open(args.graph, 'r', encoding='utf-8') as gf:
            g = json.load(gf)
    generate_html(g, outpath)
    print('Wrote', outpath)

    if args.serve:
        serve_file(outpath, host=args.host, port=args.port,
                   store_path=args.store, force_embed=args.embed,
                   graph_db_path=graph_db, view_mode=args.view,
                   semantic_threshold=args.semantic_threshold)
    else:
        print('Use --serve to start the web viewer, or try --help for other commands')


if __name__ == '__main__':
    main()
