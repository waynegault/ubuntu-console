"""PR dashboard for ubuntu-console repo.

Uses GitHub CLI (`gh`) to fetch open/merged PRs, groups them by
affected kgraph modules, and generates an HTML report showing
impact analysis.

CLI integration:
    kgraph --pr-dashboard [--output prs.html]
"""

import json
import os
import subprocess
import sys
import tempfile
from datetime import datetime
from pathlib import Path


DEFAULT_REPO = "wayne/ubuntu-console"
KGRAPH_MODULES = [
    "kgraph/__init__",
    "kgraph/__main__",
    "kgraph/cli",
    "kgraph/constants",
    "kgraph/graph_db",
    "kgraph/html",
    "kgraph/projection",
    "kgraph/life_index",
    "kgraph/server",
    "kgraph/memory_import",
    "kgraph/ast_extractor",
    "kgraph/community",
    "kgraph/confidence",
    "kgraph/report",
    "kgraph/query",
    "kgraph/call_flow",
    "kgraph/update",
    "kgraph/mcp_server",
    "kgraph/validate",
    "kgraph/git_hook",
    "kgraph/security",
    "kgraph/security_audit",
    "kgraph/benchmark",
    "kgraph/pr_dashboard",
]

DASHBOARD_TMPL = """\
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>kgraph PR Dashboard — ubuntu-console</title>
<style>
  :root {{
    --bg: #0f172a;
    --surface: #1e293b;
    --border: #334155;
    --text: #e2e8f0;
    --text-dim: #94a3b8;
    --accent: #38bdf8;
    --green: #4ade80;
    --purple: #c084fc;
    --orange: #fb923c;
    --red: #f87171;
  }}
  * {{ box-sizing: border-box; margin: 0; padding: 0; }}
  body {{ background: var(--bg); color: var(--text); font-family: system-ui, -apple-system, sans-serif; padding: 24px; }}
  h1 {{ font-size: 1.8rem; margin-bottom: 4px; }}
  h2 {{ font-size: 1.3rem; margin: 24px 0 12px; color: var(--accent); }}
  .subtitle {{ color: var(--text-dim); margin-bottom: 20px; font-size: 0.9rem; }}
  .summary {{ display: flex; gap: 12px; flex-wrap: wrap; margin-bottom: 24px; }}
  .stat {{ background: var(--surface); border: 1px solid var(--border); border-radius: 8px; padding: 12px 20px; text-align: center; flex: 1; min-width: 120px; }}
  .stat-num {{ font-size: 1.6rem; font-weight: 700; }}
  .stat-label {{ font-size: 0.75rem; color: var(--text-dim); text-transform: uppercase; letter-spacing: 0.5px; }}
  .module-group {{ background: var(--surface); border: 1px solid var(--border); border-radius: 8px; margin-bottom: 12px; overflow: hidden; }}
  .module-header {{ padding: 10px 16px; background: rgba(255,255,255,0.03); border-bottom: 1px solid var(--border); font-weight: 600; cursor: pointer; }}
  .module-header:hover {{ background: rgba(255,255,255,0.06); }}
  .module-count {{ float: right; font-size: 0.8rem; color: var(--text-dim); }}
  .pr-card {{ padding: 12px 16px; border-bottom: 1px solid rgba(255,255,255,0.05); display: flex; gap: 12px; align-items: flex-start; }}
  .pr-card:last-child {{ border-bottom: none; }}
  .pr-title {{ font-size: 0.95rem; margin-bottom: 4px; }}
  .pr-title a {{ color: var(--text); text-decoration: none; }}
  .pr-title a:hover {{ color: var(--accent); text-decoration: underline; }}
  .pr-meta {{ font-size: 0.8rem; color: var(--text-dim); display: flex; gap: 12px; flex-wrap: wrap; }}
  .badge {{ display: inline-block; padding: 2px 8px; border-radius: 4px; font-size: 0.7rem; font-weight: 600; text-transform: uppercase; }}
  .badge-open {{ background: rgba(56,189,248,0.15); color: var(--accent); }}
  .badge-merged {{ background: rgba(74,222,128,0.15); color: var(--green); }}
  .badge-closed {{ background: rgba(248,113,113,0.15); color: var(--red); }}
  .files {{ margin-top: 6px; font-size: 0.78rem; color: var(--text-dim); }}
  .files span {{ display: inline-block; margin-right: 6px; font-family: monospace; }}
  .legend {{ display: flex; gap: 16px; margin-bottom: 16px; flex-wrap: wrap; font-size: 0.85rem; }}
  .legend-item {{ display: flex; align-items: center; gap: 6px; }}
  .legend-dot {{ width: 10px; height: 10px; border-radius: 50%; display: inline-block; }}
  .no-prs {{ padding: 20px; text-align: center; color: var(--text-dim); font-style: italic; }}
</style>
</head>
<body>
<h1>📊 kgraph PR Dashboard</h1>
<p class="subtitle">{repo} — generated {generated_at}</p>

<div class="summary">
  <div class="stat">
    <div class="stat-num" style="color: var(--accent);">{total_prs}</div>
    <div class="stat-label">Total PRs</div>
  </div>
  <div class="stat">
    <div class="stat-num" style="color: var(--green);">{merged_prs}</div>
    <div class="stat-label">Merged</div>
  </div>
  <div class="stat">
    <div class="stat-num" style="color: var(--accent);">{open_prs}</div>
    <div class="stat-label">Open</div>
  </div>
  <div class="stat">
    <div class="stat-num" style="color: var(--orange);">{affected_modules}</div>
    <div class="stat-label">Modules Affected</div>
  </div>
</div>

{module_sections}

<div style="margin-top: 32px; font-size: 0.8rem; color: var(--text-dim); border-top: 1px solid var(--border); padding-top: 12px;">
  <p>Dashboard auto-generated. PR data fetched via <code>gh pr list</code> and <code>gh pr view</code>.</p>
</div>
</body>
</html>
"""


def _run_gh(args: list[str]) -> str | None:
    """Run gh CLI and return stdout, or None on failure."""
    try:
        result = subprocess.run(
            ["gh"] + args,
            capture_output=True, text=True, timeout=30,
        )
        if result.returncode == 0:
            return result.stdout
        return None
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None


def fetch_prs(repo: str = DEFAULT_REPO) -> list[dict]:
    """Fetch open and merged PRs from the repo using gh CLI.

    Returns a list of PR dicts with keys:
        number, title, state, author, created_at, merged_at, url, files, modules
    """
    all_prs = []

    # Fetch open PRs
    stdout = _run_gh([
        "pr", "list",
        "--repo", repo,
        "--state", "open",
        "--json", "number,title,state,author,createdAt,url,labels,headRefName",
        "--limit", "50",
    ])
    if stdout:
        try:
            all_prs.extend(json.loads(stdout))
        except json.JSONDecodeError:
            pass

    # Fetch recently merged PRs (last 30 days worth)
    stdout = _run_gh([
        "pr", "list",
        "--repo", repo,
        "--state", "merged",
        "--json", "number,title,state,author,createdAt,mergedAt,url,labels,headRefName",
        "--limit", "50",
    ])
    if stdout:
        try:
            all_prs.extend(json.loads(stdout))
        except json.JSONDecodeError:
            pass

    # Enrich each PR with file list and module classification
    enriched = []
    for pr in all_prs:
        num = pr.get("number", 0)
        files_stdout = _run_gh([
            "pr", "view", str(num),
            "--repo", repo,
            "--json", "files",
        ])
        changed_files = []
        modules_affected = set()
        if files_stdout:
            try:
                data = json.loads(files_stdout)
                changed_files = [f.get("path", "") for f in data.get("files", [])]
                for fpath in changed_files:
                    for mod in KGRAPH_MODULES:
                        if f"scripts/{mod}" in fpath or f"kgraph/{mod}" in fpath:
                            modules_affected.add(mod)
            except (json.JSONDecodeError, KeyError):
                pass

        enriched.append({
            "number": num,
            "title": pr.get("title", ""),
            "state": pr.get("state", "OPEN").lower(),
            "author": pr.get("author", {}).get("login", "unknown"),
            "created_at": pr.get("createdAt", ""),
            "merged_at": pr.get("mergedAt", ""),
            "url": pr.get("url", f"https://github.com/{repo}/pull/{num}"),
            "labels": [l.get("name", "") for l in pr.get("labels", [])],
            "branch": pr.get("headRefName", ""),
            "files": changed_files,
            "modules": sorted(modules_affected),
        })

    # Deduplicate by number
    seen = set()
    deduped = []
    for pr in enriched:
        if pr["number"] not in seen:
            seen.add(pr["number"])
            deduped.append(pr)

    return deduped


def generate_dashboard(prs: list[dict], output: str):
    """Group PRs by affected kgraph module and generate HTML."""
    # Group PRs by module
    by_module: dict[str, list[dict]] = {}
    unclassified: list[dict] = []

    for pr in prs:
        if pr["modules"]:
            for mod in pr["modules"]:
                by_module.setdefault(mod, []).append(pr)
        else:
            unclassified.append(pr)

    # Sort modules by PR count
    sorted_modules = sorted(by_module.keys(), key=lambda m: len(by_module[m]), reverse=True)

    # Build module sections HTML
    module_sections = ""
    for mod in sorted_modules:
        prs_in_mod = by_module[mod]
        count = len(prs_in_mod)
        cards = ""
        for pr in prs_in_mod:
            state_badge = pr["state"]
            if state_badge == "open":
                badge_class = "badge-open"
            elif state_badge == "merged":
                badge_class = "badge-merged"
            else:
                badge_class = "badge-closed"

            files_html = ""
            if pr["files"]:
                file_items = "".join(
                    f'<span>{f}</span>' for f in pr["files"][:8]
                )
                if len(pr["files"]) > 8:
                    file_items += f'<span>+{len(pr["files"])-8} more</span>'
                files_html = f'<div class="files">{file_items}</div>'

            cards += f"""\
<div class="pr-card">
  <div>
    <div class="pr-title">
      <a href="{pr["url"]}" target="_blank" rel="noopener">
        <strong>#{pr["number"]}</strong> — {pr["title"]}
      </a>
    </div>
    <div class="pr-meta">
      <span class="badge {badge_class}">{pr["state"]}</span>
      <span>👤 {pr["author"]}</span>
      <span>📅 {pr["created_at"][:10]}</span>
      {f'<span>🔀 merged {pr["merged_at"][:10]}</span>' if pr.get("merged_at") else ''}
    </div>
    {files_html}
  </div>
</div>"""

        module_sections += f"""\
<div class="module-group">
  <div class="module-header">📁 {mod} <span class="module-count">{count} PR(s)</span></div>
  {cards}
</div>"""

    # Unclassified section
    if unclassified:
        cards = ""
        for pr in unclassified:
            cards += f"""\
<div class="pr-card">
  <div>
    <div class="pr-title">
      <a href="{pr["url"]}" target="_blank" rel="noopener">
        <strong>#{pr["number"]}</strong> — {pr["title"]}
      </a>
    </div>
    <div class="pr-meta">
      <span class="badge badge-{pr["state"]}">{pr["state"]}</span>
      <span>👤 {pr["author"]}</span>
      <span>📅 {pr["created_at"][:10]}</span>
    </div>
  </div>
</div>"""
        module_sections += f"""\
<div class="module-group">
  <div class="module-header">📁 Other / Unclassified <span class="module-count">{len(unclassified)} PR(s)</span></div>
  {cards}
</div>"""

    if not module_sections:
        module_sections = '<div class="no-prs">No PRs found affecting kgraph modules.</div>'

    # Stats
    total_prs = len(prs)
    merged_prs = sum(1 for p in prs if p["state"] == "merged")
    open_prs = sum(1 for p in prs if p["state"] == "open")
    affected_modules = len(sorted_modules)

    generated_at = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    html = DASHBOARD_TMPL.format(
        repo=DEFAULT_REPO,
        generated_at=generated_at,
        total_prs=total_prs,
        merged_prs=merged_prs,
        open_prs=open_prs,
        affected_modules=affected_modules,
        module_sections=module_sections,
    )

    with open(output, "w", encoding="utf-8") as f:
        f.write(html)

    print(f"PR dashboard written to {output}")
    print(f"  {total_prs} PRs total, {merged_prs} merged, {open_prs} open, {affected_modules} modules affected")


def main():
    """CLI entry point: kgraph-pr-dashboard [--output prs.html]"""
    output = "kgraph_pr_dashboard.html"
    if len(sys.argv) > 1:
        for i, arg in enumerate(sys.argv[1:]):
            if arg == "--output" and i + 2 < len(sys.argv):
                output = sys.argv[i + 2]
            elif arg.startswith("--output="):
                output = arg.split("=", 1)[1]

    prs = fetch_prs()
    generate_dashboard(prs, output)


if __name__ == "__main__":
    main()
