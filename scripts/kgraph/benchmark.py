"""Token-reduction benchmark for kgraph queries vs raw files.

Compares estimated tokens needed to represent graph data vs
equivalent raw file content. Provides a benchmark report.
"""

import os
import json


def estimate_tokens(text: str) -> int:
    """Rough token count: ~4 chars per token for English."""
    return max(1, len(text) // 4)


def benchmark_graph_vs_raw(graph: dict, source_files: list[str] = None, **kwargs) -> dict:
    """Compare token usage between graph representation and raw files.

    Args:
        graph: Graph dict with nodes and edges.
        source_files: Optional list of file paths to compare against.
        output_path: Optional JSON output path.

    Returns:
        Dict with benchmark results.
    """
    nodes = graph.get('nodes', []) or []
    edges = graph.get('edges', []) or []

    # ── Graph tokens ──
    # Node: id + label + type + content_preview = ~80 chars = 20 tokens
    # Edge: from + to + label + semantic_score = ~60 chars = 15 tokens
    graph_token_estimate = len(nodes) * 20 + len(edges) * 15

    # With compression (assuming edges share structure):
    compressed_node_tokens = len(nodes) * 8 + len(edges) * 6

    # ── Raw file tokens ──
    raw_tokens = 0
    files_available = 0
    file_sizes = []

    if source_files:
        for fpath in source_files:
            if not os.path.isfile(fpath):
                continue
            try:
                with open(fpath, 'r', encoding='utf-8', errors='replace') as f:
                    content = f.read()
                tokens = estimate_tokens(content)
                raw_tokens += tokens
                files_available += 1
                file_sizes.append({
                    'path': fpath,
                    'size_bytes': len(content.encode('utf-8')),
                    'tokens': tokens,
                })
            except (OSError, IOError):
                pass

    # ── Compare ──
    result = {
        'graph_tokens': graph_token_estimate,
        'compressed_graph_tokens': compressed_node_tokens,
        'raw_file_tokens': raw_tokens if source_files else 'N/A (no source files provided)',
        'files_scanned': files_available,
        'node_count': len(nodes),
        'edge_count': len(edges),
        'avg_tokens_per_node': round(graph_token_estimate / max(1, len(nodes)), 1),
        'avg_tokens_per_edge': round(graph_token_estimate / max(1, len(edges)), 1),
    }

    if isinstance(result['raw_file_tokens'], int) and raw_tokens > 0:
        result['raw_to_graph_ratio'] = round(raw_tokens / max(1, graph_token_estimate), 2)
        result['raw_to_compressed_ratio'] = round(raw_tokens / max(1, compressed_node_tokens), 2)
        result['savings_pct_vs_raw'] = round(
            (1 - graph_token_estimate / raw_tokens) * 100, 1
        )
        result['compressed_savings_pct_vs_raw'] = round(
            (1 - compressed_node_tokens / raw_tokens) * 100, 1
        )

    if file_sizes:
        file_sizes.sort(key=lambda x: x['tokens'], reverse=True)
        result['largest_files'] = file_sizes[:10]

    output_path = kwargs.get('output_path', None)
    if output_path:
        with open(output_path, 'w', encoding='utf-8') as f:
            json.dump(result, f, indent=2)
        print(f'Benchmark written to {output_path}')

    return result


def print_benchmark(result: dict):
    """Pretty-print a benchmark result dict."""
    print('=== Token-Reduction Benchmark ===')
    print(f'  Graph nodes: {result.get("node_count", 0)}')
    print(f'  Graph edges: {result.get("edge_count", 0)}')
    print(f'  Estimated graph tokens: {result.get("graph_tokens", "N/A")}')
    print(f'  Compressed graph tokens: {result.get("compressed_graph_tokens", "N/A")}')
    raw = result.get('raw_file_tokens', 'N/A')
    print(f'  Raw file tokens: {raw}')
    if isinstance(raw, int):
        print(f'  Raw-to-graph ratio: {result.get("raw_to_graph_ratio", "N/A")}x')
        print(f'  Raw-to-compressed ratio: {result.get("raw_to_compressed_ratio", "N/A")}x')
        print(f'  Savings vs raw: {result.get("savings_pct_vs_raw", "N/A")}%')
        print(f'  Compressed savings vs raw: {result.get("compressed_savings_pct_vs_raw", "N/A")}%')
    print(f'  Avg tokens/node: {result.get("avg_tokens_per_node", "N/A")}')
    print(f'  Avg tokens/edge: {result.get("avg_tokens_per_edge", "N/A")}')
