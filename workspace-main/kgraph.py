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
import webbrowser
import tempfile
import shutil
import sqlite3


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
    </style>
  </head>
  <body>
    <div id="toolbar">
      <button id="save">Save JSON</button>
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
    <div id="mynetwork"></div>
    <script>
      const embeddedData = %s;

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
          els.push({ data: Object.assign({ id: id, label: d.label || '' }, d) });
        });
        (data.edges || []).forEach((e, idx) => {
          const id = e.id || ('e' + idx + '_' + e.from + '_' + e.to);
          els.push({ data: { id: String(id), source: String(e.from), target: String(e.to), label: e.label || '' } });
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
                'label': 'data(label)',
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
        ], layout: { name: 'cose', fit: true } });

        // Ensure clicking a node/edge selects it (improves UX across browsers)
        cy.on('tap', 'node', (evt) => { try { evt.target.select(); } catch(e){} });
        cy.on('tap', 'edge', (evt) => { try { evt.target.select(); } catch(e){} });

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

        // autosave
        let last = null;
        setInterval(async () => {
          const nodes = cy.nodes().map(n => Object.assign({ id: n.id() }, n.data()));
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
          const nodes = cy.nodes().map(n => Object.assign({ id: n.id() }, n.data()));
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


def serve_file(path: str, host: str = '127.0.0.1', port: int = 0, store_path: str | None = None):
  dirname = os.path.abspath(os.path.dirname(path))
  filename = os.path.basename(path)
  os.chdir(dirname)

  class GraphRequestHandler(SimpleHTTPRequestHandler):
    store = store_path or os.path.expanduser('~/.openclaw/kgraph.json')

    def do_GET(self):
      if self.path == '/graph.json':
        try:
          with open(self.store, 'r', encoding='utf-8') as f:
            data = f.read()
        except Exception:
          data = json.dumps(SAMPLE_GRAPH)
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        # Allow local browser fetches
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(data.encode('utf-8'))
        return
      return super().do_GET()

    def do_POST(self):
      if self.path == '/graph.json':
        length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(length)
        try:
          os.makedirs(os.path.dirname(self.store), exist_ok=True)
          with open(self.store, 'wb') as f:
            f.write(body)
          self.send_response(200)
          self.send_header('Access-Control-Allow-Origin', '*')
          self.end_headers()
          self.wfile.write(b'OK')
        except Exception as e:
          self.send_response(500)
          self.end_headers()
          self.wfile.write(str(e).encode())
        return
      return super().do_POST()

  handler = GraphRequestHandler
  httpd = HTTPServer((host, port), handler)
  addr, used_port = httpd.server_address
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
    parser.add_argument('--host', help='Host to bind server to (default 127.0.0.1)', default='127.0.0.1')
    parser.add_argument('--port', type=int, help='Port to bind server to (default ephemeral)', default=0)
    parser.add_argument('--import-db', help='Import nodes/edges from SQLite memory DB and use as graph')
    parser.add_argument('--install', nargs='?', const='~/.openclaw/workspace-main/kgraph.py', help='Copy this script to target path and make executable')
    args = parser.parse_args()

    graph = SAMPLE_GRAPH
    if args.graph:
      with open(args.graph, 'r', encoding='utf-8') as gf:
        graph = json.load(gf)

    if args.import_db:
      try:
        graph = load_from_memory_db(args.import_db)
        print('Imported graph from', args.import_db)
      except Exception as e:
        print('Failed to import DB:', e)

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
      serve_file(outpath, host=args.host, port=args.port, store_path=(args.store or None))


def load_from_memory_db(dbpath: str) -> dict:
    """Load nodes/edges from an OpenClaw memory SQLite DB into graph dict."""
    conn = sqlite3.connect(os.path.expanduser(dbpath))
    cur = conn.cursor()
    graph = {'nodes': [], 'edges': []}
    # nodes table: id (TEXT), name, canonical_text
    try:
        cur.execute("SELECT id, name, canonical_text FROM nodes")
        for row in cur.fetchall():
            nid, name, canonical = row
            label = name or canonical or str(nid)
            graph['nodes'].append({'id': str(nid), 'label': label})
    except sqlite3.Error:
        pass
    try:
        cur.execute("SELECT src_id, dst_id, rel FROM edges")
        for row in cur.fetchall():
            src, dst, rel = row
            graph['edges'].append({'from': str(src), 'to': str(dst), 'label': rel or ''})
    except sqlite3.Error:
        pass
    conn.close()
    return graph


if __name__ == '__main__':
    main()
