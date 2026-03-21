#!/usr/bin/env python3
"""kgraph.py

Serve an interactive Cytoscape-based knowledge graph.

Features:
- Cytoscape.js frontend (from CDN)
- Edit/create/delete nodes and edges
- Edge labels and node labels with toggles
- Cluster by node attribute or by label prefix (creates compound parent nodes)
- Persistent store via GET/POST /graph.json (defaults to ~/.openclaw/kgraph.json)
"""
from http.server import SimpleHTTPRequestHandler, HTTPServer
import threading
import argparse
import json
import os
import re
import webbrowser
import tempfile
import shutil
import sqlite3


MEMORY_DB_CANDIDATES = [
  '~/.openclaw/memory-system/data/memory.db',
  '~/.openclaw/memory/main.sqlite',
]

GRAPH_DB_DEFAULT = '~/.openclaw/kgraph.sqlite'


HTML_TMPL = """<!doctype html>
<html>
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Knowledge Graph (Cytoscape)</title>
    <script src="https://unpkg.com/cytoscape@3.24.0/dist/cytoscape.min.js"></script>
    <style>
      html, body { height: 100%; margin: 0; font-family: system-ui, sans-serif; }
      #mynetwork { width: 100%; height: 100vh; border: 1px solid lightgray; }
      #toolbar { position: absolute; left: 12px; top: 12px; z-index: 99; background: rgba(255,255,255,0.95); padding:6px; border-radius:6px; box-shadow:0 2px 6px rgba(0,0,0,0.1); }
      #toolbar > * { margin-right:6px; }
      #detail-panel {
        position: absolute;
        right: 12px;
        top: 12px;
        width: min(420px, calc(100vw - 24px));
        max-height: calc(100vh - 24px);
        overflow: auto;
        z-index: 99;
        background: rgba(255,255,255,0.97);
        border-radius: 10px;
        box-shadow: 0 10px 28px rgba(0,0,0,0.18);
        border: 1px solid rgba(0,0,0,0.1);
        padding: 14px;
      }
      #detail-panel[hidden] { display: none; }
      #detail-header { display: flex; justify-content: space-between; align-items: center; gap: 10px; }
      #detail-title { margin: 0; font-size: 16px; line-height: 1.2; }
      #detail-meta { margin: 8px 0 10px; color: #4b5563; font-size: 12px; }
      #detail-summary {
        margin: 0 0 12px;
        color: #111827;
        font-size: 13px;
        line-height: 1.45;
        white-space: pre-wrap;
      }
      #detail-body {
        width: 100%;
        min-height: 180px;
        resize: vertical;
        box-sizing: border-box;
        border: 1px solid #d1d5db;
        border-radius: 8px;
        padding: 10px;
        font: 12px/1.45 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
        color: #111827;
        background: #f9fafb;
      }
      #detail-panel details { margin-top: 12px; }
      #detail-panel summary { cursor: pointer; font-weight: 600; }
      #detail-close {
        border: 0;
        border-radius: 6px;
        background: #e5e7eb;
        padding: 6px 10px;
        cursor: pointer;
      }
    </style>
  </head>
  <body>
    <div id="toolbar">
      <button id="save">Save JSON</button>
      <button id="zoom-in">＋</button>
      <button id="zoom-out">－</button>
      <button id="zoom-reset">Reset</button>
      <span id="zoom-level" style="margin-left:6px;font-weight:600">100%</span>
      <button id="fit">Fit</button>
      <button id="add-node">Add Node</button>
      <button id="add-edge">Add Edge</button>
      <button id="del-selected">Delete Selected</button>
      <button id="edit-selected">Edit Selected</button>
      <select id="cluster-attr">
        <option value="__label_prefix">Label prefix</option>
      </select>
      <button id="cluster">Cluster by attr</button>
      <button id="uncluster">Ungroup</button>
      <label><input id="show-node-labels" type="checkbox" checked/> Node labels</label>
      <label><input id="show-edge-labels" type="checkbox" checked/> Edge labels</label>
    </div>
    <aside id="detail-panel" hidden>
      <div id="detail-header">
        <h2 id="detail-title">Selection</h2>
        <button id="detail-close" type="button">Close</button>
      </div>
      <div id="detail-meta"></div>
      <p id="detail-summary">Select a node or edge to inspect it.</p>
      <details>
        <summary>Full details</summary>
        <textarea id="detail-body" readonly></textarea>
      </details>
    </aside>
    <div id="mynetwork"></div>
    <script>
      const embeddedData = %s;

      function shortenLabel(node) {
        if (node.short_label) return String(node.short_label);
        if (node.type === 'file') return String((node.path || node.label || '').split('/').pop() || node.label || 'file');
        if (node.type === 'chunk') {
          const file = String((node.path || '').split('/').pop() || 'chunk');
          const start = Number.isInteger(node.start_line) ? node.start_line : null;
          const end = Number.isInteger(node.end_line) ? node.end_line : null;
          if (start !== null && end !== null) return `${file} L${start}-${end}`;
          if (start !== null) return `${file} L${start}`;
          return file;
        }
        const base = String(node.label || '').trim();
        return base.length > 26 ? base.slice(0, 25) + '…' : (base || String(node.id || 'node'));
      }

      function buildNodeDetail(node) {
        const lines = [];
        lines.push(`id: ${node.id || ''}`);
        if (node.type) lines.push(`type: ${node.type}`);
        if (node.path) lines.push(`path: ${node.path}`);
        if (Number.isInteger(node.start_line)) lines.push(`start_line: ${node.start_line}`);
        if (Number.isInteger(node.end_line)) lines.push(`end_line: ${node.end_line}`);
        if (node.chunk_id) lines.push(`chunk_id: ${node.chunk_id}`);
        if (node.label) lines.push(`label: ${node.label}`);
        if (node.content_preview) {
          lines.push('');
          lines.push('content_preview:');
          lines.push(String(node.content_preview));
        }
        const extra = Object.entries(node).filter(([k]) => !['id','type','path','start_line','end_line','chunk_id','label','content_preview','display_label','short_label'].includes(k));
        if (extra.length) {
          lines.push('');
          lines.push('extra:');
          extra.forEach(([k, v]) => lines.push(`${k}: ${typeof v === 'object' ? JSON.stringify(v, null, 2) : v}`));
        }
        return lines.join('\\n');
      }

      function buildEdgeDetail(edge) {
        return [
          `id: ${edge.id || ''}`,
          `source: ${edge.source || ''}`,
          `target: ${edge.target || ''}`,
          `label: ${edge.label || ''}`,
        ].join('\\n');
      }

      async function loadGraph() {
        try {
          const r = await fetch('/graph.json');
          if (r.ok) return await r.json();
        } catch (e) { console.warn('graph.json fetch failed, using embedded data', e); }
        return embeddedData;
      }

      function toCytoscapeElements(data) {
        const els = [];
        (data.nodes || []).forEach(n => {
          const d = Object.assign({}, n);
          const id = String(d.id);
          delete d.id;
          els.push({ data: Object.assign({ id: id, label: d.label || '', display_label: shortenLabel(n) }, d) });
        });
        (data.edges || []).forEach((e, idx) => {
            const src = (e.from !== undefined && e.from !== null) ? e.from : (e.source !== undefined ? e.source : '');
            const tgt = (e.to !== undefined && e.to !== null) ? e.to : (e.target !== undefined ? e.target : '');
            const id = e.id || ('e' + idx + '_' + String(src) + '_' + String(tgt));
            els.push({ data: { id: String(id), source: String(src), target: String(tgt), label: e.label || '' } });
        });
        return els;
      }

      (async function init() {
        const data = await loadGraph();
        const elements = toCytoscapeElements(data);

        // populate cluster attribute select with keys from nodes
        const keys = new Set();
        (data.nodes || []).forEach(n => Object.keys(n).forEach(k => { if (k !== 'id' && k !== 'label') keys.add(k); }));
        const sel = document.getElementById('cluster-attr');
        // include a 'label' option and keep the Label prefix option
        const labelOpt = document.createElement('option'); labelOpt.value = 'label'; labelOpt.textContent = 'label'; sel.appendChild(labelOpt);
        Array.from(keys).forEach(k => { const o = document.createElement('option'); o.value = k; o.textContent = k; sel.appendChild(o); });

        const cy = cytoscape({ container: document.getElementById('mynetwork'), elements: elements, style: [
              { selector: 'node', style: {
                'background-color': '#1976d2',
                'label': 'data(display_label)',
                'shape': 'ellipse',
                'width': 56,
                'height': 56,
                'font-family': 'Inter, system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial',
                'font-weight': '600',
                'font-size': 10,
                'text-valign': 'center',
                'text-halign': 'center',
                'text-wrap': 'wrap',
                'text-max-width': 160,
                'color':'#ffffff',
                'text-outline-width': 2,
                'text-outline-color':'#1976d2',
                'background-image': 'none'
              } },
              { selector: 'node:selected', style: { 'border-width': 6, 'border-color': '#ffb74d' } },
              { selector: 'node[type = "file"]', style: {
                'background-color': '#2563eb',
                'text-outline-color': '#2563eb',
                'shape': 'roundrectangle',
                'width': 68,
                'height': 40
              } },
              { selector: 'node[type = "actor"]', style: {
                'background-color': '#d97706',
                'text-outline-color': '#d97706',
                'shape': 'hexagon',
                'width': 64,
                'height': 64
              } },
              { selector: 'edge:selected', style: { 'line-color': '#ffb74d', 'target-arrow-color': '#ffb74d' } },
              { selector: 'node.hide-label', style: { 'label': '' } },
            { selector: 'edge', style: {
              'curve-style': 'bezier',
              'target-arrow-shape': 'triangle',
              'label': 'data(label)',
              'text-rotation':'autorotate',
              'font-size': 10,
              'color': '#000',
              'text-wrap': 'wrap',
              'text-max-width': 160,
              'text-margin-y': -6
              } },
              { selector: 'edge.hide-label', style: { 'label': '' } },
          { selector: '.cluster', style: {
              'background-color': '#ff9800',
              'shape': 'roundrectangle',
              'label': 'data(label)',
              'text-valign': 'center',
              'color':'#000',
              'text-outline-width': 0,
              'font-size': 18,
              'font-weight': '600'
          } }
        ], layout: { name: 'cose', fit: true },
        // Improve zoom behaviour across environments
        zoom: 1.0,
        minZoom: 0.2,
        maxZoom: 3,
        wheelSensitivity: 0.2,
        userZoomingEnabled: true,
        userPanningEnabled: true
        });

        const detailPanel = document.getElementById('detail-panel');
        const detailTitle = document.getElementById('detail-title');
        const detailMeta = document.getElementById('detail-meta');
        const detailSummary = document.getElementById('detail-summary');
        const detailBody = document.getElementById('detail-body');
        const detailClose = document.getElementById('detail-close');

        function showDetailForElement(el) {
          if (!el) {
            detailPanel.hidden = true;
            return;
          }
          const data = el.data() || {};
          if (el.isNode && el.isNode()) {
            detailTitle.textContent = data.display_label || data.label || data.id || 'Node';
            detailMeta.textContent = [data.type || 'node', data.path || '', Number.isInteger(data.start_line) ? `L${data.start_line}${Number.isInteger(data.end_line) ? '-' + data.end_line : ''}` : ''].filter(Boolean).join(' | ');
            detailSummary.textContent = data.content_preview || data.label || 'No additional content available.';
            detailBody.value = buildNodeDetail(data);
          } else if (el.isEdge && el.isEdge()) {
            detailTitle.textContent = data.label || 'Edge';
            detailMeta.textContent = `${data.source || ''} -> ${data.target || ''}`;
            detailSummary.textContent = data.label || 'Relationship edge';
            detailBody.value = buildEdgeDetail(data);
          }
          detailPanel.hidden = false;
        }

        detailClose.addEventListener('click', () => {
          detailPanel.hidden = true;
          cy.elements(':selected').unselect();
        });
        // Set an initial, reasonable zoom level so the UI isn't zoomed in too far
        // on some environments. Then ensure clicking a node/edge selects it
        // (improves UX across browsers).
        cy.ready(() => {
          try {
            cy.zoom(0.94);
            cy.center();
          } catch (e) {}
        });

        // Ensure clicking a node/edge selects it (improves UX across browsers)
        cy.on('tap', 'node', (evt) => { try { evt.target.select(); } catch(e){} });
        cy.on('tap', 'edge', (evt) => { try { evt.target.select(); } catch(e){} });
        cy.on('select', 'node, edge', (evt) => showDetailForElement(evt.target));
        cy.on('unselect', 'node, edge', () => {
          if (cy.$(':selected').length === 0) detailPanel.hidden = true;
        });

        // Adjust label sizes dynamically based on current zoom level.
        // Use conservative base sizes and clamp the effective zoom multiplier
        // so labels stay readable but not oversized.
        function updateLabelSizes() {
          const z = cy.zoom();
          // clamp zoom multiplier between 0.6 and 1.4 to avoid extreme sizes
          const m = Math.min(1.4, Math.max(0.6, z));

          const nodeBase = 8; // reduced base font at zoom=1
          const edgeBase = 6;
          const outlineBase = 1;
          const minNode = 6;
          const minEdge = 5;

          const nodeSize = Math.max(minNode, Math.round(nodeBase * m));
          const edgeSize = Math.max(minEdge, Math.round(edgeBase * m));
          const outlineSize = Math.max(1, Math.round(outlineBase * m));

          cy.batch(() => {
            cy.nodes().forEach(n => {
              n.style('font-size', nodeSize);
              n.style('text-outline-width', outlineSize);
              n.style('font-weight', '500');
            });
            cy.edges().forEach(e => {
              e.style('font-size', edgeSize);
            });
          });
        }

        cy.on('zoom', updateLabelSizes);
        cy.on('layoutstop', updateLabelSizes);
        updateLabelSizes();

        // Zoom controls
        function setZoomLabel() {
          const z = Math.round(cy.zoom() * 100);
          const el = document.getElementById('zoom-level');
          if (el) el.textContent = z + '%';
        }
        setZoomLabel();
        document.getElementById('zoom-in').addEventListener('click', () => { cy.zoom({ level: Math.min(cy.zoom() * 1.2, cy.maxZoom()) }); setZoomLabel(); });
        document.getElementById('zoom-out').addEventListener('click', () => { cy.zoom({ level: Math.max(cy.zoom() / 1.2, cy.minZoom()) }); setZoomLabel(); });
        document.getElementById('zoom-reset').addEventListener('click', () => { cy.zoom(0.94); cy.center(); setZoomLabel(); });
        cy.on('zoom', setZoomLabel);

        // autosave
        let last = null;
        setInterval(async () => {
          const nodes = cy.nodes().map(n => {
            const d = Object.assign({ id: n.id() }, n.data());
            delete d.display_label;
            return d;
          });
          const edges = cy.edges().map(e => ({ from: e.data('source'), to: e.data('target'), label: e.data('label') }));
          const out = { nodes: nodes, edges: edges };
          const j = JSON.stringify(out);
          if (j !== last) { last = j; try { await fetch('/graph.json', { method: 'POST', headers: { 'Content-Type':'application/json' }, body: j }); console.log('autosaved'); } catch (e) { console.warn('autosave failed', e); } }
        }, 5000);

        // Controls
        document.getElementById('fit').addEventListener('click', () => cy.fit());

        document.getElementById('add-node').addEventListener('click', () => {
          const id = prompt('Node id (leave blank for autogenerated)');
          const label = prompt('Node label', '');
          const nid = id && id.trim() ? id.trim() : ('n' + (Math.random()*1e9|0));
          cy.add({ data: { id: String(nid), label: label || '' } });
          cy.layout({ name: 'cose' }).run();
        });

        // Interactive add-edge: click Add Edge, then click source node then target node
        document.getElementById('add-edge').addEventListener('click', () => {
          alert('Add edge: click the source node, then click the target node. Esc to cancel.');
          let src = null;
          const onTapNode = (evt) => {
            const n = evt.target;
            if (!src) {
              src = n.id();
              n.addClass('selected-temp');
              return;
            }
            const tgt = n.id();
            const lbl = prompt('Edge label (optional)', '');
            cy.add({ data: { id: 'e' + (Math.random()*1e9|0), source: String(src), target: String(tgt), label: lbl || '' } });
            cy.nodes().removeClass('selected-temp');
            cy.off('tap', 'node', onTapNode);
          };
          cy.on('tap', 'node', onTapNode);
          // allow cancel with Esc
          const escHandler = (e) => { if (e.key === 'Escape') { cy.nodes().removeClass('selected-temp'); cy.off('tap', 'node', onTapNode); window.removeEventListener('keydown', escHandler); } };
          window.addEventListener('keydown', escHandler);
        });

        document.getElementById('del-selected').addEventListener('click', () => { cy.remove(cy.$(':selected')); });

        document.getElementById('edit-selected').addEventListener('click', async () => {
          const sel = cy.$(':selected');
          if (!sel || sel.length === 0) { alert('No node or edge selected. Click an element first.'); return; }
          if (sel.length > 1) { alert('Please select a single element to edit.'); return; }
          const el = sel[0];
          if (el.isNode && el.isNode()) {
            const cur = el.data() || {};
            const nl = prompt('Edit node label', cur.label || '');
            if (nl !== null) el.data('label', nl);
            const key = prompt('Edit/add attribute key (leave blank to skip)', '');
            if (key && key.trim()) {
              const val = prompt('Value for ' + key, cur[key] || '');
              if (val !== null) {
                const d = Object.assign({}, el.data());
                d[key] = val;
                el.data(d);
              }
            }
          } else if (el.isEdge && el.isEdge()) {
            const cur = el.data() || {};
            const elab = prompt('Edit edge label', cur.label || '');
            if (elab !== null) el.data('label', elab);
          } else {
            alert('Selected element is not a node or edge');
          }
        });

        document.getElementById('cluster').addEventListener('click', () => {
          const attr = document.getElementById('cluster-attr').value;
          const groups = {};
          cy.nodes().forEach(n => {
            let v = null;
            if (attr === '__label_prefix') v = (n.data('label') || '').split(' ')[0] || 'ungrouped'; else v = n.data(attr) || 'undefined';
            groups[v] = groups[v] || [];
            groups[v].push(n);
          });
          Object.keys(groups).forEach(k => {
            if (groups[k].length > 1) {
              const cid = 'cluster_' + k.replace(/[^a-z0-9_-]/gi,'_');
              // create parent node
              cy.add({ data: { id: cid, label: k }, classes: 'cluster' });
              groups[k].forEach(n => { n.move({ parent: cid }); });
            }
          });
          cy.layout({ name: 'cose', fit: true }).run();
        });

        document.getElementById('uncluster').addEventListener('click', () => {
          cy.nodes('.cluster').forEach(cn => {
            cn.children().forEach(ch => { ch.move({ parent: null }); });
            cy.remove(cn);
          });
          cy.layout({ name: 'cose', fit: true }).run();
        });

        // Toggle node/edge labels by adding/removing a class that hides labels
        document.getElementById('show-node-labels').addEventListener('change', (e) => {
          const on = e.target.checked;
          if (on) cy.nodes().removeClass('hide-label'); else cy.nodes().addClass('hide-label');
        });

        document.getElementById('show-edge-labels').addEventListener('change', (e) => {
          const on = e.target.checked;
          if (on) cy.edges().removeClass('hide-label'); else cy.edges().addClass('hide-label');
        });

        // double tap to edit
        let lastTap = 0;
        cy.on('tap', (evt) => {
          const now = Date.now();
          if (now - lastTap < 350) {
            const e = evt.target;
            if (e && e.nonempty()) {
              if (e.isNode()) {
                const nl = prompt('Edit node label', e.data('label') || ''); if (nl !== null) e.data('label', nl);
              } else if (e.isEdge()) { const el = prompt('Edit edge label', e.data('label') || ''); if (el !== null) e.data('label', el); }
            }
          }
          lastTap = now;
        });

        // Save button
        document.getElementById('save').addEventListener('click', async () => {
          const nodes = cy.nodes().map(n => {
            const d = Object.assign({ id: n.id() }, n.data());
            delete d.display_label;
            return d;
          });
          const edges = cy.edges().map(e => ({ from: e.data('source'), to: e.data('target'), label: e.data('label') }));
          const out = { nodes: nodes, edges: edges };
          try { await fetch('/graph.json', { method: 'POST', headers: { 'Content-Type':'application/json' }, body: JSON.stringify(out) }); alert('Saved'); } catch (e) { console.warn('save failed', e); }
        });
      })();
    </script>
  </body>
</html>
"""


SAMPLE_GRAPH = {
    "nodes": [
        {"id": 1, "label": "Cluster A"},
        {"id": 2, "label": "Cluster B"},
        {"id": 3, "label": "Item 1"},
        {"id": 4, "label": "Item 2"}
    ],
    "edges": [
        {"from": 1, "to": 3},
        {"from": 1, "to": 4},
        {"from": 2, "to": 4}
    ]
}


def generate_html(graph: dict, outpath: str):
    payload = json.dumps(graph)
    html = HTML_TMPL.replace('%s', payload, 1)
    with open(outpath, 'w', encoding='utf-8') as f:
        f.write(html)


def resolve_memory_db_path(preferred: str | None = None) -> str | None:
  if preferred:
    p = os.path.expanduser(preferred)
    return p if os.path.exists(p) else None
  for candidate in MEMORY_DB_CANDIDATES:
    p = os.path.expanduser(candidate)
    if os.path.exists(p):
      return p
  return None


def init_graph_db(dbpath: str):
  path = os.path.expanduser(dbpath)
  os.makedirs(os.path.dirname(path), exist_ok=True)
  conn = sqlite3.connect(path)
  cur = conn.cursor()
  cur.execute("""
    CREATE TABLE IF NOT EXISTS graph_nodes (
      id TEXT PRIMARY KEY,
      label TEXT,
      payload TEXT
    )
  """)
  cur.execute("""
    CREATE TABLE IF NOT EXISTS graph_edges (
      source TEXT NOT NULL,
      target TEXT NOT NULL,
      label TEXT,
      payload TEXT,
      UNIQUE(source, target, label)
    )
  """)
  conn.commit()
  conn.close()


def load_from_graph_db(dbpath: str) -> dict:
  path = os.path.expanduser(dbpath)
  if not os.path.exists(path):
    return {'nodes': [], 'edges': []}

  conn = sqlite3.connect(path)
  cur = conn.cursor()
  graph = {'nodes': [], 'edges': []}

  try:
    cur.execute("SELECT id, label, payload FROM graph_nodes")
    for node_id, label, payload in cur.fetchall():
      node = {'id': str(node_id), 'label': label or ''}
      if payload:
        try:
          extra = json.loads(payload)
          if isinstance(extra, dict):
            node.update(extra)
        except Exception:
          pass
      graph['nodes'].append(node)
  except sqlite3.Error:
    pass

  try:
    cur.execute("SELECT source, target, label, payload FROM graph_edges")
    for source, target, label, payload in cur.fetchall():
      edge = {'from': str(source), 'to': str(target), 'label': label or ''}
      if payload:
        try:
          extra = json.loads(payload)
          if isinstance(extra, dict):
            edge.update(extra)
        except Exception:
          pass
      graph['edges'].append(edge)
  except sqlite3.Error:
    pass

  conn.close()
  return graph


def save_to_graph_db(dbpath: str, graph: dict):
  init_graph_db(dbpath)
  path = os.path.expanduser(dbpath)
  conn = sqlite3.connect(path)
  cur = conn.cursor()

  cur.execute("DELETE FROM graph_edges")
  cur.execute("DELETE FROM graph_nodes")

  for node in graph.get('nodes', []):
    node_id = str(node.get('id', ''))
    if not node_id:
      continue
    label = node.get('label', '')
    payload = {k: v for k, v in node.items() if k not in ('id', 'label')}
    cur.execute(
      "INSERT OR REPLACE INTO graph_nodes(id, label, payload) VALUES (?, ?, ?)",
      (node_id, label, json.dumps(payload) if payload else None),
    )

  for edge in graph.get('edges', []):
    source = edge.get('from', edge.get('source'))
    target = edge.get('to', edge.get('target'))
    if source is None or target is None:
      continue
    label = edge.get('label', '')
    payload = {k: v for k, v in edge.items() if k not in ('from', 'to', 'source', 'target', 'label')}
    cur.execute(
      "INSERT OR REPLACE INTO graph_edges(source, target, label, payload) VALUES (?, ?, ?, ?)",
      (str(source), str(target), label, json.dumps(payload) if payload else None),
    )

  conn.commit()
  conn.close()


def serve_file(path: str, host: str = '127.0.0.1', port: int = 0, store_path: str | None = None, force_embed: bool = False, graph_db_path: str | None = None):
  # Prefer serving a built frontend (frontend-g6/dist) if present in the repo.
  repo_root = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
  static_dir = os.path.join(repo_root, 'frontend-g6', 'dist')
  if (not force_embed) and os.path.isdir(static_dir):
    os.chdir(static_dir)
    filename = 'index.html'
  else:
    dirname = os.path.abspath(os.path.dirname(path))
    filename = os.path.basename(path)
    os.chdir(dirname)

  _CORS_HEADERS = [
    ('Access-Control-Allow-Origin', '*'),
    ('Access-Control-Allow-Methods', 'GET, POST, OPTIONS'),
    ('Access-Control-Allow-Headers', 'Content-Type'),
  ]

  class GraphRequestHandler(SimpleHTTPRequestHandler):
    store = store_path or os.path.expanduser('~/.openclaw/kgraph.json')
    graph_db = graph_db_path or os.path.expanduser(GRAPH_DB_DEFAULT)
    # Path to OpenClaw memory DB to use as fallback source.
    # Supports legacy and current OpenClaw layouts.
    memory_db = resolve_memory_db_path()

    def _send_cors_headers(self):
      for name, value in _CORS_HEADERS:
        self.send_header(name, value)

    def do_OPTIONS(self):
      self.send_response(204)
      self._send_cors_headers()
      self.end_headers()

    def do_GET(self):
      if self.path == '/graph.json':
        try:
            # Prefer user-edited graph DB when present and non-empty.
            if self.graph_db and os.path.exists(os.path.expanduser(self.graph_db)):
              user_graph = load_from_graph_db(self.graph_db)
              if user_graph.get('nodes') or user_graph.get('edges'):
                data = json.dumps(user_graph)
              elif self.memory_db and os.path.exists(self.memory_db):
                try:
                  db_graph = load_from_memory_db(self.memory_db)
                except Exception:
                  db_graph = {'nodes': [], 'edges': []}
                if (not db_graph.get('nodes')) and (not db_graph.get('edges')) and os.path.isfile(self.store):
                  with open(self.store, 'r', encoding='utf-8') as f:
                    data = f.read()
                else:
                  data = json.dumps(db_graph)
              elif os.path.isfile(self.store):
                with open(self.store, 'r', encoding='utf-8') as f:
                  data = f.read()
              else:
                data = json.dumps(SAMPLE_GRAPH)

            # Fall back to OpenClaw memory DB when present and non-empty.
            elif self.memory_db and os.path.exists(self.memory_db):
              try:
                db_graph = load_from_memory_db(self.memory_db)
              except Exception:
                db_graph = {'nodes': [], 'edges': []}
              # If the DB contains no nodes/edges, fall back to the configured
              # JSON store so a sensible default (or embedded sample) is used.
              if (not db_graph.get('nodes')) and (not db_graph.get('edges')) and os.path.isfile(self.store):
                with open(self.store, 'r', encoding='utf-8') as f:
                  data = f.read()
              else:
                data = json.dumps(db_graph)
            else:
              with open(self.store, 'r', encoding='utf-8') as f:
                data = f.read()
        except Exception:
            # final fallback to sample graph
            data = json.dumps(SAMPLE_GRAPH)
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self._send_cors_headers()
        self.end_headers()
        self.wfile.write(data.encode('utf-8'))
        return
      return super().do_GET()

    def do_POST(self):
      if self.path == '/graph.json':
        length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(length)
        try:
          payload = json.loads(body.decode('utf-8'))
          if not isinstance(payload, dict):
            raise ValueError('graph payload must be an object')
          payload.setdefault('nodes', [])
          payload.setdefault('edges', [])

          # Primary persistence target: dedicated SQLite graph DB.
          save_to_graph_db(self.graph_db, payload)

          # Backward-compat mirror for tooling expecting kgraph.json.
          os.makedirs(os.path.dirname(self.store), exist_ok=True)
          with open(self.store, 'w', encoding='utf-8') as f:
            json.dump(payload, f)

          self.send_response(200)
          self._send_cors_headers()
          self.end_headers()
          self.wfile.write(b'OK')
        except Exception as e:
          self.send_response(500)
          self._send_cors_headers()
          self.end_headers()
          self.wfile.write(str(e).encode())
        return
      return super().do_POST()

  handler = GraphRequestHandler
  httpd = HTTPServer((host, port), handler)
  addr, used_port = httpd.server_address
  # If serving the built frontend, point root to index.html
  if os.path.isdir(static_dir):
    url = f'http://{addr}:{used_port}/'
  else:
    url = f'http://{addr}:{used_port}/{filename}'
  # Open browser in background if available but don't block
  try:
    threading.Thread(target=webbrowser.open, args=(url,), daemon=True).start()
  except Exception:
    pass

  print('Serving', url)
  try:
    httpd.serve_forever()
  except KeyboardInterrupt:
    httpd.shutdown()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', '-o', help='Write HTML to this path')
    parser.add_argument('--serve', action='store_true', help='Serve generated page and open browser')
    parser.add_argument('--graph', help='Path to a JSON file with nodes/edges')
    parser.add_argument('--store', help='Path to persistent graph JSON (default: ~/.openclaw/kgraph.json)')
    parser.add_argument('--graph-db', help=f'Path to persistent graph SQLite DB (default: {GRAPH_DB_DEFAULT})')
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
      os.makedirs(os.path.dirname(dest), exist_ok=True)
      shutil.copy2(__file__, dest)
      os.chmod(dest, 0o755)
      print('Installed to', dest)

    if args.serve:
      serve_file(outpath, host=args.host, port=args.port, store_path=(args.store or None), force_embed=args.embed, graph_db_path=graph_db)


def load_from_memory_db(dbpath: str) -> dict:
    """Load nodes/edges from an OpenClaw memory SQLite DB into graph dict."""
    conn = sqlite3.connect(os.path.expanduser(dbpath))
    cur = conn.cursor()
    graph = {'nodes': [], 'edges': []}
    node_ids = set()
    edge_ids = set()

    def has_table(name: str) -> bool:
        cur.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1", (name,))
        return cur.fetchone() is not None

    def add_node(node: dict):
        node_id = str(node.get('id', ''))
        if not node_id or node_id in node_ids:
            return
        node_ids.add(node_id)
        graph['nodes'].append(node)

    def add_edge(edge: dict):
        source = str(edge.get('from', ''))
        target = str(edge.get('to', ''))
        label = str(edge.get('label', ''))
        edge_key = (source, target, label)
        if not source or not target or edge_key in edge_ids:
            return
        edge_ids.add(edge_key)
        graph['edges'].append(edge)

    # Legacy schema: nodes/edges tables.
    if has_table('nodes') and has_table('edges'):
        try:
            cur.execute("SELECT id, name, canonical_text FROM nodes")
            for row in cur.fetchall():
                nid, name, canonical = row
                label = name or canonical or str(nid)
                add_node({'id': str(nid), 'label': label})
        except sqlite3.Error:
            pass
        try:
            cur.execute("SELECT src_id, dst_id, rel FROM edges")
            for row in cur.fetchall():
                src, dst, rel = row
                add_edge({'from': str(src), 'to': str(dst), 'label': rel or ''})
        except sqlite3.Error:
            pass

    # Current OpenClaw memory schema: files/chunks tables.
    elif has_table('files') and has_table('chunks'):
        file_paths = set()
        file_node_ids = {}
        file_path_by_basename = {}

        def _preview_text(value: str, limit: int = 72) -> str:
            text = (value or '').replace('\n', ' ').replace('\r', ' ').strip()
            text = ' '.join(text.split())
            if len(text) > limit:
                return text[: limit - 1] + '…'
            return text

        def _slug(value: str) -> str:
            return re.sub(r'[^a-z0-9]+', '-', value.lower()).strip('-')

        def add_actor_node(name: str, role: str = '') -> str:
            actor_id = f"actor:{_slug(name)}"
            add_node({
                'id': actor_id,
                'label': name,
                'type': 'actor',
                'role': role,
                'content_preview': role or f'Actor: {name}',
            })
            return actor_id

        def iter_actor_mentions(text: str):
            if not text:
                return

            direct_pattern = re.compile(
                r'\b([A-Z][a-z]+)\s+\(([^)]+(?:Director|CEO|Ops|Researcher|Marketing|Finance|Sales|Agent))\)'
            )
            reverse_pattern = re.compile(
                r'\b((?:[A-Z][a-z]+(?:\s*&\s*[A-Z][a-z]+)?\s+)?(?:Finance|Sales|Marketing|Ops|Research|Chief|CEO)[A-Za-z\s&-]*)\s+\(([A-Z][a-z]+)\)'
            )

            for name, role in direct_pattern.findall(text):
                yield name.strip(), role.strip()
            for role, name in reverse_pattern.findall(text):
                if any(keyword in role for keyword in ('Director', 'CEO', 'Ops', 'Research', 'Finance', 'Sales', 'Marketing', 'Agent', 'Chief')):
                    yield name.strip(), role.strip()

        def resolve_file_reference(reference: str) -> str | None:
            ref = reference.strip().strip('`')
            if not ref:
                return None
            if ref in file_node_ids:
                return ref
            if ref in file_paths:
                return ref
            base = os.path.basename(ref)
            matches = file_path_by_basename.get(base, [])
            if len(matches) == 1:
                return matches[0]
            return None

        file_ref_pattern = re.compile(r'`([^`]+\.md)`|\b((?:memory/)?[A-Za-z0-9._-]+\.md)\b')

        try:
            cur.execute("SELECT path FROM files")
            for (path,) in cur.fetchall():
                if not path:
                    continue
                file_name = os.path.basename(path) or path
                file_paths.add(path)
                file_path_by_basename.setdefault(file_name, []).append(path)
                file_node_ids[path] = f'file:{path}'
                add_node({
                    'id': f'file:{path}',
                    'label': file_name,
                    'type': 'file',
                    'path': path,
                    'content_preview': f'File: {path}',
                })
        except sqlite3.Error:
            pass

        try:
            cur.execute("SELECT id, path, start_line, end_line, text FROM chunks")
            for chunk_id, path, start_line, end_line, chunk_text in cur.fetchall():
                chunk_key = str(chunk_id)
                file_name = os.path.basename(path) if path else 'chunk'

                line_range = ''
                if isinstance(start_line, int) and isinstance(end_line, int):
                    line_range = f'L{start_line}-{end_line}'
                elif isinstance(start_line, int):
                    line_range = f'L{start_line}'

                preview = _preview_text(chunk_text)
                chunk_label = f'{file_name} {line_range}'.strip() if line_range else file_name
                if preview:
                    chunk_label = f'{chunk_label}: {preview}'

                add_node({
                    'id': f'chunk:{chunk_key}',
                    'label': chunk_label,
                    'type': 'chunk',
                    'path': path or '',
                    'start_line': start_line,
                    'end_line': end_line,
                    'chunk_id': chunk_key,
                    'content_preview': preview,
                })

                if path:
                    if path not in file_paths:
                        file_paths.add(path)
                        file_name = os.path.basename(path) or path
                        file_path_by_basename.setdefault(file_name, []).append(path)
                        file_node_ids[path] = f'file:{path}'
                        add_node({
                            'id': f'file:{path}',
                            'label': file_name,
                            'type': 'file',
                            'path': path,
                            'content_preview': f'File: {path}',
                        })
                    add_edge({
                        'from': f'file:{path}',
                        'to': f'chunk:{chunk_key}',
                        'label': 'contains chunk',
                    })

                for name, role in iter_actor_mentions(chunk_text or ''):
                    actor_id = add_actor_node(name, role)
                    add_edge({
                        'from': f'chunk:{chunk_key}',
                        'to': actor_id,
                        'label': 'mentions actor',
                    })
                    if path:
                        add_edge({
                            'from': f'file:{path}',
                            'to': actor_id,
                            'label': 'mentions actor',
                        })

                for ref_a, ref_b in file_ref_pattern.findall(chunk_text or ''):
                    ref = ref_a or ref_b
                    target_path = resolve_file_reference(ref)
                    if not target_path or target_path == path:
                        continue
                    add_edge({
                        'from': f'chunk:{chunk_key}',
                        'to': f'file:{target_path}',
                        'label': 'references file',
                    })
                    if path:
                        add_edge({
                            'from': f'file:{path}',
                            'to': f'file:{target_path}',
                            'label': 'references file',
                        })
        except sqlite3.Error:
            pass

    conn.close()
    return graph


if __name__ == '__main__':
    main()
