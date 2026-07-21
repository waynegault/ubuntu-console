"""PR Dashboard generator for ubuntu-console repo.

Analyzes GitHub-style PR and commit metadata from the repository
and generates an HTML dashboard showing recent work, file changes,
and how they connect to the knowledge graph.
"""

import logging
import os
import subprocess
from datetime import datetime, timezone

logger = logging.getLogger(__name__)


def generate_pr_dashboard(repo_root: str, **kwargs) -> str:
    """Generate a PR dashboard HTML page for a local git repo.

    Scans git log, branches, and recent commits, correlating them
    with graph data from kgraph.

    Args:
        repo_root: Path to git repository root.
        days: Number of days of history to include (default 30).
        graph_data: Optional graph dict to correlate changes with nodes.
        author: Filter to one author.
        max_prs: Max PR-like merge commits (default 30).

    Returns:
        Full HTML string.
    """
    days = kwargs.get('days', 30)
    author_filter = kwargs.get('author', None)
    max_prs = kwargs.get('max_prs', 30)
    graph_data = kwargs.get('graph_data', None)
    output_path = kwargs.get('output_path', None)

    if not os.path.isdir(os.path.join(repo_root, '.git')):
        return '<html><body><h1>Error</h1><p>Not a git repository</p></body></html>'

    # Gather git data
    git_data = _gather_git_data(repo_root, days, author_filter, max_prs)

    # If graph data available, correlate
    graph_correlations = _correlate_with_graph(git_data, graph_data) if graph_data else []

    # Build HTML
    html = _build_dashboard_html(git_data, graph_correlations, repo_root, days)

    if output_path:
        os.makedirs(os.path.dirname(os.path.abspath(output_path)) or '.', exist_ok=True)
        with open(output_path, 'w', encoding='utf-8') as f:
            f.write(html)
        print(f'PR dashboard written to {output_path}')

    return html


def _gather_git_data(repo_root: str, days: int, author: str | None, max_prs: int) -> dict:
    """Run git commands to gather PR/merge/commit data."""
    since = f'--since={days}.days.ago'

    # Merge commits (PR-like merges)
    merge_cmd = [
        'git', 'log', since, '--merges', '--first-parent',
        '--format=%H|%an|%ae|%ai|%s',
        f'--max-count={max_prs}',
    ]

    merges = []
    try:
        result = subprocess.run(merge_cmd, capture_output=True, text=True,
                                cwd=repo_root, check=False)
        for line in result.stdout.strip().split('\n'):
            if not line.strip():
                continue
            parts = line.split('|', 4)
            if len(parts) >= 5:
                merges.append({
                    'hash': parts[0],
                    'author_name': parts[1],
                    'author_email': parts[2],
                    'date': parts[3],
                    'subject': parts[4],
                })
    except Exception as e:
        merges = [{'error': str(e)}]

    # Recent commits (non-merge)
    commit_cmd = [
        'git', 'log', since,
        '--format=%H|%an|%ae|%ai|%s',
        '--max-count=100',
    ]
    if author:
        commit_cmd.append(f'--author={author}')

    commits = []
    try:
        result = subprocess.run(commit_cmd, capture_output=True, text=True,
                                cwd=repo_root, check=False)
        for line in result.stdout.strip().split('\n'):
            if not line.strip():
                continue
            parts = line.split('|', 4)
            if len(parts) >= 5:
                commits.append({
                    'hash': parts[0],
                    'author_name': parts[1],
                    'author_email': parts[2],
                    'date': parts[3],
                    'subject': parts[4],
                })
    except Exception as exc:
        logger.warning("Failed to parse recent merges for dashboard: %s", exc)

    # Files changed recently
    diff_cmd = [
        'git', 'diff', '--name-status',
        f'@{days}.days.ago',
    ]
    recent_files = []
    try:
        result = subprocess.run(diff_cmd, capture_output=True, text=True,
                                cwd=repo_root, check=False)
        for line in result.stdout.strip().split('\n'):
            if not line.strip():
                continue
            parts = line.split('\t', 1)
            if len(parts) == 2:
                recent_files.append({
                    'status': parts[0],
                    'path': parts[1],
                })
    except Exception as exc:
        logger.warning("Failed to list recently changed files: %s", exc)

    # Active branches
    branch_cmd = ['git', 'branch', '-a', '--sort=-committerdate']
    branches = []
    try:
        result = subprocess.run(branch_cmd, capture_output=True, text=True,
                                cwd=repo_root, check=False)
        for line in result.stdout.strip().split('\n'):
            line = line.strip()
            if line:
                is_current = line.startswith('* ')
                branches.append({
                    'name': line.lstrip('* ').strip(),
                    'current': is_current,
                })
    except Exception as exc:
        logger.warning("Failed to list active branches: %s", exc)

    # Authors
    author_cmd = [
        'git', 'shortlog', since, '-sne',
        '--format=%an|%ae',
    ]
    authors = {}
    try:
        result = subprocess.run(author_cmd, capture_output=True, text=True,
                                cwd=repo_root, check=False)
        for line in result.stdout.strip().split('\n'):
            if not line.strip():
                continue
            parts = line.strip().split('|', 1)
            if len(parts) >= 1:
                name = parts[0].strip()
                email = parts[1].strip() if len(parts) > 1 else ''
                authors[name] = email
    except Exception as exc:
        logger.warning("Failed to get authors list: %s", exc)

    return {
        'merges': merges,
        'commits': commits,
        'recent_files': recent_files,
        'branches': branches,
        'authors': authors,
        'total_commits': len(commits),
        'total_merges': len(merges),
        'total_files_changed': len(recent_files),
        'total_branches': len(branches),
    }


def _correlate_with_graph(git_data: dict, graph: dict) -> list[dict]:
    """Correlate changed files with graph nodes."""
    correlations = []
    graph_nodes = graph.get('nodes', []) if graph else []

    for node in graph_nodes:
        path = str(node.get('path', node.get('rel_path', '')))
        if not path:
            continue
        # Check if any recent file matches this node
        for rf in git_data.get('recent_files', []):
            if path in rf['path'] or rf['path'] in path:
                correlations.append({
                    'file': rf['path'],
                    'node_id': node.get('id', ''),
                    'node_label': node.get('label', ''),
                    'node_type': node.get('type', ''),
                    'node_importance': node.get('importance', node.get('degree', 0)),
                })

    # Deduplicate
    seen = set()
    deduped = []
    for c in correlations:
        key = (c['file'], c['node_id'])
        if key not in seen:
            seen.add(key)
            deduped.append(c)

    return deduped[:50]


def _build_dashboard_html(git_data: dict, correlations: list, repo_root: str, days: int) -> str:
    """Generate the full HTML dashboard."""
    repo_name = os.path.basename(repo_root)
    now = datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')

    merges_table = ''
    for m in git_data.get('merges', [])[:20]:
        merges_table += f'''
        <tr>
            <td><code>{m.get('hash', '')[:8]}</code></td>
            <td>{m.get('author_name', '')}</td>
            <td>{m.get('subject', '')[:80]}</td>
            <td>{m.get('date', '')[:10]}</td>
        </tr>'''

    commits_table = ''
    for c in git_data.get('commits', [])[:30]:
        commits_table += f'''
        <tr>
            <td><code>{c.get('hash', '')[:8]}</code></td>
            <td>{c.get('author_name', '')}</td>
            <td>{c.get('subject', '')[:80]}</td>
            <td>{c.get('date', '')[:10]}</td>
        </tr>'''

    files_list = ''
    for f in git_data.get('recent_files', [])[:40]:
        status_class = f.get('status', 'M')
        if status_class == 'A':
            badge = '<span class="badge added">+</span>'
        elif status_class == 'D':
            badge = '<span class="badge deleted">−</span>'
        elif status_class == 'M':
            badge = '<span class="badge modified">~</span>'
        elif status_class.startswith('R'):
            badge = '<span class="badge renamed">→</span>'
        else:
            badge = f'<span class="badge">{status_class}</span>'
        files_list += f'<li>{badge} {f.get("path", "")}</li>'

    branches_list = ''
    for b in git_data.get('branches', [])[:15]:
        marker = '<strong>▶</strong> ' if b.get('current') else ''
        branches_list += f'<li>{marker}{b.get("name", "")}</li>'

    correlations_table = ''
    for c in correlations[:20]:
        correlations_table += f'''
        <tr>
            <td><code>{c.get('file', '')}</code></td>
            <td>{c.get('node_label', '')}</td>
            <td>{c.get('node_type', '')}</td>
        </tr>'''

    authors_list = ''
    for name, email in git_data.get('authors', {}).items():
        authors_list += f'<li>{name} &lt;{email}&gt;</li>'

    html = f'''<!doctype html>
<html>
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>PR Dashboard — {repo_name}</title>
    <style>
        * {{ margin: 0; padding: 0; box-sizing: border-box; }}
        body {{ font-family: system-ui, -apple-system, sans-serif; background: #f8fafc; color: #1e293b; padding: 24px; }}
        header {{ margin-bottom: 24px; }}
        h1 {{ font-size: 22px; color: #0f172a; }}
        .subtitle {{ color: #64748b; font-size: 13px; }}
        .stats {{ display: flex; gap: 16px; flex-wrap: wrap; margin: 16px 0; }}
        .stat {{ background: #fff; border-radius: 8px; padding: 16px 20px; box-shadow: 0 1px 3px rgba(0,0,0,0.08); min-width: 120px; }}
        .stat-value {{ font-size: 28px; font-weight: 700; color: #0f172a; }}
        .stat-label {{ font-size: 12px; color: #64748b; text-transform: uppercase; letter-spacing: 0.05em; }}
        .grid {{ display: grid; grid-template-columns: 1fr 1fr; gap: 16px; }}
        @media (max-width: 800px) {{ .grid {{ grid-template-columns: 1fr; }} }}
        .card {{ background: #fff; border-radius: 10px; padding: 16px; box-shadow: 0 1px 3px rgba(0,0,0,0.08); }}
        .card h2 {{ font-size: 15px; color: #334155; margin-bottom: 10px; padding-bottom: 6px; border-bottom: 1px solid #f1f5f9; }}
        table {{ width: 100%; border-collapse: collapse; font-size: 12px; }}
        th, td {{ text-align: left; padding: 6px 8px; border-bottom: 1px solid #f1f5f9; }}
        th {{ background: #f8fafc; font-weight: 600; color: #64748b; font-size: 11px; text-transform: uppercase; }}
        td code {{ font-size: 11px; background: #f1f5f9; padding: 1px 4px; border-radius: 3px; }}
        ul {{ list-style: none; padding: 0; }}
        li {{ padding: 4px 0; font-size: 13px; }}
        .badge {{ display: inline-block; width: 20px; height: 20px; text-align: center; line-height: 20px; border-radius: 4px; font-size: 11px; font-weight: 700; margin-right: 6px; }}
        .badge.added {{ background: #d1fae5; color: #065f46; }}
        .badge.deleted {{ background: #fee2e2; color: #991b1b; }}
        .badge.modified {{ background: #fef3c7; color: #92400e; }}
        .badge.renamed {{ background: #e0e7ff; color: #3730a3; }}
        .tab {{ display: inline-block; padding: 6px 14px; font-size: 13px; cursor: pointer; border-radius: 6px 6px 0 0; background: #f1f5f9; color: #64748b; margin-right: 2px; }}
        .tab.active {{ background: #fff; color: #0f172a; font-weight: 600; }}
        .tab-content {{ display: none; }}
        .tab-content.active {{ display: block; }}
        .scroll {{ max-height: 400px; overflow: auto; }}
    </style>
</head>
<body>
<header>
    <h1>📊 PR Dashboard — {repo_name}</h1>
    <p class="subtitle">Last {days} days · Generated {now}</p>
</header>

<div class="stats">
    <div class="stat">
        <div class="stat-value">{git_data.get('total_merges', 0)}</div>
        <div class="stat-label">Merges</div>
    </div>
    <div class="stat">
        <div class="stat-value">{git_data.get('total_commits', 0)}</div>
        <div class="stat-label">Commits</div>
    </div>
    <div class="stat">
        <div class="stat-value">{git_data.get('total_files_changed', 0)}</div>
        <div class="stat-label">Files Changed</div>
    </div>
    <div class="stat">
        <div class="stat-value">{git_data.get('total_branches', 0)}</div>
        <div class="stat-label">Branches</div>
    </div>
</div>

<div class="grid">
    <div class="card">
        <h2>Recent Merges</h2>
        <div class="scroll">
        <table>
            <tr><th>Hash</th><th>Author</th><th>Subject</th><th>Date</th></tr>
            {merges_table}
        </table>
        </div>
    </div>
    <div class="card">
        <h2>Recent Commits</h2>
        <div class="scroll">
        <table>
            <tr><th>Hash</th><th>Author</th><th>Subject</th><th>Date</th></tr>
            {commits_table}
        </table>
        </div>
    </div>
    <div class="card">
        <h2>Files Changed</h2>
        <div class="scroll"><ul>{files_list}</ul></div>
    </div>
    <div class="card">
        <h2>Active Branches</h2>
        <div class="scroll"><ul>{branches_list}</ul></div>
    </div>
</div>

<div class="card" style="margin-top:16px;">
    <h2>Authors ({len(git_data.get('authors', {}))})</h2>
    <ul>{authors_list}</ul>
</div>

<div class="card" style="margin-top:16px;">
    <h2>Graph Correlations ({len(correlations)})</h2>
    <p style="font-size:12px;color:#64748b;margin-bottom:8px;">Recent file changes linked to kgraph nodes</p>
    <div class="scroll">
    <table>
        <tr><th>File</th><th>Node Label</th><th>Type</th></tr>
        {correlations_table}
    </table>
    </div>
</div>
</body>
</html>'''

    return html
