"""Token-reduction benchmark for kgraph.

Compares raw token count of source files against kgraph query token
count, reports savings ratio, and generates a benchmark report.

Benchmark modes:
1. Raw text tokenization of source files
2. kgraph query-based token estimation (nodes + edges + labels)
3. Savings ratio = (raw - kgraph) / raw * 100

CLI integration:
    kgraph --benchmark [--output benchmark.json]
"""

import json
import math
import os
import sys
import time
from datetime import datetime
from pathlib import Path


# ── Token estimation ────────────────────────────────────────────────────

def estimate_tokens(text: str) -> int:
    """Estimate token count for a string using a rough heuristic.

    Uses ~4 characters per token (common English/ code average).
    More accurate per-language tokenizers would use tiktoken or similar;
    this provides a reasonable approximation for comparison purposes.
    """
    if not text:
        return 0
    # Rough heuristic: ~4 chars per token, 1 token per word for short text
    words = len(text.split())
    chars = len(text)
    return max(words, chars // 4)


# ── Source file scanning ────────────────────────────────────────────────

def scan_source_files(directory: str, extensions: tuple[str, ...] = (".py",)) -> list[dict]:
    """Scan directory for source files and return their contents and sizes."""
    files = []
    dir_path = Path(directory).expanduser().resolve()

    for ext in extensions:
        for fpath in dir_path.rglob(f"*{ext}"):
            if "__pycache__" in str(fpath):
                continue
            try:
                with open(fpath, "r", encoding="utf-8", errors="replace") as f:
                    content = f.read()
                files.append({
                    "path": str(fpath),
                    "relative_path": str(fpath.relative_to(dir_path)),
                    "content": content,
                    "raw_tokens": estimate_tokens(content),
                    "char_count": len(content),
                    "line_count": len(content.splitlines()),
                })
            except Exception as e:
                print(f"  [warn] Skipping {fpath}: {e}")

    return files


# ── Graph token estimation ──────────────────────────────────────────────

def estimate_graph_tokens(graph: dict) -> dict:
    """Estimate the token cost of representing data via the kgraph.

    Returns dict with keys:
        node_tokens: token count for node labels + types
        edge_tokens: token count for edge labels + types
        total_tokens: sum of all graph-representation tokens
        node_count: number of nodes
        edge_count: number of edges
    """
    nodes = graph.get("nodes", [])
    edges = graph.get("edges", [])

    node_tokens = 0
    node_count = len(nodes)
    for node in nodes:
        label = str(node.get("label", ""))
        node_type = str(node.get("type", ""))
        description = str(node.get("description", ""))
        node_tokens += estimate_tokens(label)
        node_tokens += estimate_tokens(node_type)
        node_tokens += estimate_tokens(description)
        # Each connection mentioned adds token cost
        conn_text = str(node.get("connections", ""))
        node_tokens += estimate_tokens(conn_text)

    edge_tokens = 0
    edge_count = len(edges)
    for edge in edges:
        label = str(edge.get("label", ""))
        edge_type = str(edge.get("type", ""))
        src = str(edge.get("from", edge.get("source", "")))
        tgt = str(edge.get("to", edge.get("target", "")))
        edge_tokens += estimate_tokens(label)
        edge_tokens += estimate_tokens(edge_type)
        edge_tokens += estimate_tokens(src)
        edge_tokens += estimate_tokens(tgt)

    total_tokens = node_tokens + edge_tokens

    return {
        "node_tokens": node_tokens,
        "edge_tokens": edge_tokens,
        "total_tokens": total_tokens,
        "node_count": node_count,
        "edge_count": edge_count,
    }


# ── Benchmark runner ───────────────────────────────────────────────────

def run_benchmark(source_dir: str, graph: dict | None = None) -> dict:
    """Run a token-reduction benchmark.

    Args:
        source_dir: Directory to scan for source files.
        graph: Optional pre-loaded graph dict. If None, uses minimal graph.

    Returns:
        A benchmark report dict.
    """
    start_time = time.time()

    # Scan source files
    if graph is None:
        graph = {"nodes": [], "edges": []}

    files = scan_source_files(source_dir)
    if not files:
        # Fall back to scanning the kgraph package itself
        kgraph_dir = os.path.join(os.path.dirname(__file__))
        files = scan_source_files(kgraph_dir)

    # If still no files in package dir, use cwd
    if not files:
        files = scan_source_files(os.getcwd())

    # Sum raw tokens across all files
    total_raw_tokens = sum(f["raw_tokens"] for f in files)
    total_char_count = sum(f["char_count"] for f in files)
    total_line_count = sum(f["line_count"] for f in files)

    # Estimate graph tokens
    graph_stats = estimate_graph_tokens(graph)

    # Compute savings
    raw_for_graph = total_raw_tokens
    graph_tokens = graph_stats["total_tokens"]

    if raw_for_graph > 0:
        savings_pct = round((raw_for_graph - graph_tokens) / raw_for_graph * 100, 2)
        reduction_ratio = round(raw_for_graph / graph_tokens, 2) if graph_tokens > 0 else float("inf")
    else:
        savings_pct = 0.0
        reduction_ratio = 0.0

    end_time = time.time()
    duration_ms = round((end_time - start_time) * 1000, 2)

    report = {
        "benchmark_timestamp": datetime.now().isoformat(),
        "source_dir": source_dir,
        "duration_ms": duration_ms,
        "files_scanned": len(files),
        "total_char_count": total_char_count,
        "total_line_count": total_line_count,
        "total_raw_tokens": total_raw_tokens,
        "graph_stats": graph_stats,
        "savings": {
            "raw_tokens": total_raw_tokens,
            "graph_tokens": graph_tokens,
            "savings_tokens": total_raw_tokens - graph_tokens,
            "savings_percent": savings_pct,
            "reduction_ratio": reduction_ratio,
        },
        "files": sorted(
            [{"path": f["relative_path"], "raw_tokens": f["raw_tokens"],
              "lines": f["line_count"]} for f in files],
            key=lambda x: x["raw_tokens"],
            reverse=True,
        ),
    }

    return report


# ── Report formatting ──────────────────────────────────────────────────

def format_benchmark_report(report: dict) -> str:
    """Format a benchmark report as a human-readable string."""
    lines = []
    lines.append("=" * 60)
    lines.append("kgraph Token-Reduction Benchmark Report")
    lines.append("=" * 60)
    lines.append(f"Generated: {report.get('benchmark_timestamp', '')}")
    lines.append(f"Source directory: {report.get('source_dir', '')}")
    lines.append(f"Duration: {report.get('duration_ms', 0)} ms")
    lines.append("")

    lines.append("── Source Files ──")
    lines.append(f"  Files scanned: {report.get('files_scanned', 0)}")
    lines.append(f"  Total chars:   {report.get('total_char_count', 0):,}")
    lines.append(f"  Total lines:   {report.get('total_line_count', 0):,}")
    lines.append(f"  Raw tokens:    {report.get('total_raw_tokens', 0):,}")
    lines.append("")

    graph_stats = report.get("graph_stats", {})
    lines.append("── Graph Representation ──")
    lines.append(f"  Nodes:          {graph_stats.get('node_count', 0):,}")
    lines.append(f"  Edges:          {graph_stats.get('edge_count', 0):,}")
    lines.append(f"  Node tokens:    {graph_stats.get('node_tokens', 0):,}")
    lines.append(f"  Edge tokens:    {graph_stats.get('edge_tokens', 0):,}")
    lines.append(f"  Graph tokens:   {graph_stats.get('total_tokens', 0):,}")
    lines.append("")

    savings = report.get("savings", {})
    lines.append("── Savings ──")
    lines.append(f"  Raw tokens:     {savings.get('raw_tokens', 0):,}")
    lines.append(f"  Graph tokens:   {savings.get('graph_tokens', 0):,}")
    lines.append(f"  Tokens saved:   {savings.get('savings_tokens', 0):,}")
    lines.append(f"  Savings ratio:  {savings.get('savings_percent', 0):.2f}%")
    lines.append(f"  Reduction:      {savings.get('reduction_ratio', 0):.1f}×")

    pct = savings.get("savings_percent", 0)
    if pct > 95:
        verdict = "🟢 Excellent — kgraph provides dramatic token reduction"
    elif pct > 80:
        verdict = "🟢 Good — kgraph provides significant token savings"
    elif pct > 50:
        verdict = "🟡 Moderate — kgraph provides moderate token savings"
    elif pct > 0:
        verdict = "🔴 Minimal — kgraph provides little token reduction for this corpus"
    else:
        verdict = "⚪ No benchmark data"

    lines.append("")
    lines.append(f"Verdict: {verdict}")
    lines.append("")
    lines.append("── Top Files by Token Count ──")

    top_files = report.get("files", [])[:10]
    for i, f in enumerate(top_files, 1):
        lines.append(f"  {i:2d}. {f['path']:<50s} {f['raw_tokens']:>8,} tokens ({f['lines']} lines)")

    lines.append("=" * 60)
    return "\n".join(lines)


def generate_html_report(report: dict) -> str:
    """Generate an HTML benchmark report from the data."""
    savings = report.get("savings", {})
    pct = savings.get("savings_percent", 0)
    if pct > 95:
        color = "#4ade80"
        verdict = "Excellent"
    elif pct > 80:
        color = "#4ade80"
        verdict = "Good"
    elif pct > 50:
        color = "#fb923c"
        verdict = "Moderate"
    elif pct > 0:
        color = "#f87171"
        verdict = "Minimal"
    else:
        color = "#94a3b8"
        verdict = "N/A"

    files_rows = "".join(
        f"<tr><td>{f['path']}</td><td>{f['raw_tokens']:,}</td><td>{f['lines']}</td></tr>"
        for f in report.get("files", [])[:25]
    )

    gs = report.get("graph_stats", {})
    sv = report.get("savings", {})

    return f"""\
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>kgraph Token-Reduction Benchmark</title>
<style>
  :root {{ --bg: #0f172a; --surface: #1e293b; --border: #334155; --text: #e2e8f0; --dim: #94a3b8; }}
  * {{ box-sizing: border-box; margin: 0; padding: 0; }}
  body {{ background: var(--bg); color: var(--text); font-family: system-ui, sans-serif; padding: 24px; }}
  h1 {{ font-size: 1.6rem; margin-bottom: 4px; }}
  .subtitle {{ color: var(--dim); font-size: 0.85rem; margin-bottom: 20px; }}
  .grid {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 12px; margin-bottom: 24px; }}
  .card {{ background: var(--surface); border: 1px solid var(--border); border-radius: 8px; padding: 16px; text-align: center; }}
  .card-num {{ font-size: 1.8rem; font-weight: 700; }}
  .card-label {{ font-size: 0.75rem; color: var(--dim); text-transform: uppercase; margin-top: 4px; }}
  h2 {{ font-size: 1.2rem; margin: 24px 0 12px; color: #38bdf8; }}
  table {{ width: 100%; border-collapse: collapse; }}
  th, td {{ padding: 8px 12px; text-align: left; border-bottom: 1px solid var(--border); font-size: 0.85rem; }}
  th {{ color: var(--dim); text-transform: uppercase; font-size: 0.75rem; }}
  tr:hover {{ background: rgba(255,255,255,0.03); }}
  .verdict {{ font-size: 1.2rem; font-weight: 700; }}
  .savings-bar {{ height: 24px; background: var(--border); border-radius: 4px; overflow: hidden; margin: 8px 0; }}
  .savings-fill {{ height: 100%; background: {color}; width: {min(pct, 100):.1f}%; }}
</style>
</head>
<body>
<h1>📊 kgraph Token-Reduction Benchmark</h1>
<p class="subtitle">{report.get('benchmark_timestamp', '')} — Source: {report.get('source_dir', '')}</p>

<div class="grid">
  <div class="card"><div class="card-num">{report.get('files_scanned', 0)}</div><div class="card-label">Files Scanned</div></div>
  <div class="card"><div class="card-num">{report.get('total_char_count', 0):,}</div><div class="card-label">Total Characters</div></div>
  <div class="card"><div class="card-num">{sv.get('raw_tokens', 0):,}</div><div class="card-label">Raw Tokens</div></div>
  <div class="card"><div class="card-num">{sv.get('graph_tokens', 0):,}</div><div class="card-label">Graph Tokens</div></div>
  <div class="card"><div class="card-num" style="color:{color}">{sv.get('savings_percent', 0):.1f}%</div><div class="card-label">Savings</div></div>
  <div class="card"><div class="card-num">{sv.get('reduction_ratio', 0):.1f}×</div><div class="card-label">Reduction Ratio</div></div>
</div>

<div class="savings-bar"><div class="savings-fill"></div></div>
<p class="verdict" style="color:{color}">{verdict}: {sv.get('graph_tokens', 0):,} tokens vs {sv.get('raw_tokens', 0):,} raw tokens</p>

<h2>Graph Stats</h2>
<div class="grid">
  <div class="card"><div class="card-num">{gs.get('node_count', 0):,}</div><div class="card-label">Nodes</div></div>
  <div class="card"><div class="card-num">{gs.get('edge_count', 0):,}</div><div class="card-label">Edges</div></div>
  <div class="card"><div class="card-num">{gs.get('node_tokens', 0):,}</div><div class="card-label">Node Tokens</div></div>
  <div class="card"><div class="card-num">{gs.get('edge_tokens', 0):,}</div><div class="card-label">Edge Tokens</div></div>
</div>

<h2>Top Files</h2>
<table>
<thead><tr><th>File</th><th>Raw Tokens</th><th>Lines</th></tr></thead>
<tbody>{files_rows}</tbody>
</table>
</body>
</html>
"""


# ── Main ────────────────────────────────────────────────────────────────

def main():
    """CLI entry point: kgraph-benchmark [--output benchmark.json] [source_dir]"""
    import argparse

    parser = argparse.ArgumentParser(description="kgraph token-reduction benchmark")
    parser.add_argument("source_dir", nargs="?", default=None,
                        help="Directory to scan for source files (default: kgraph package dir)")
    parser.add_argument("--output", "-o", default=None,
                        help="Output report file (.json or .html)")
    args = parser.parse_args()

    source_dir = args.source_dir or os.path.dirname(__file__)

    # Load existing graph from default location if available
    graph = None
    db_path = os.path.expanduser("~/.openclaw/kgraph.sqlite")
    if os.path.exists(db_path):
        try:
            from .graph_db import load_from_graph_db
            graph = load_from_graph_db(db_path)
        except Exception:
            pass

    report = run_benchmark(source_dir, graph=graph)

    # Output
    output_path = args.output
    if not output_path:
        print(format_benchmark_report(report))
    elif output_path.endswith(".html") or output_path.endswith(".htm"):
        html = generate_html_report(report)
        with open(output_path, "w", encoding="utf-8") as f:
            f.write(html)
        print(f"HTML benchmark report written to {output_path}")
    else:
        with open(output_path, "w", encoding="utf-8") as f:
            json.dump(report, f, indent=2)
        print(f"JSON benchmark report written to {output_path}")
        print(format_benchmark_report(report))


if __name__ == "__main__":
    main()
