"""HTML template generation for the knowledge graph viewer.

Exports HTML_TMPL (the full embedded HTML page with Cytoscape.js),
ensure_parent_dir(), and generate_html().
"""
import json
import os


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
      <label>View
        <select id="view-mode">
          <option value="overview">Overview</option>
          <option value="topics">Topics</option>
          <option value="files">Files</option>
          <option value="semantic">Semantic</option>
          <option value="raw">Raw</option>
        </select>
      </label>
      <label>Semantic ≥
        <input id="semantic-threshold" type="range" min="0.80" max="0.95" step="0.01" value="0.85" />
        <span id="semantic-threshold-value">0.85</span>
      </label>
      <span id="graph-meta" style="margin-left:6px;color:#4b5563;font-size:12px;"></span>
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
      let currentMeta = { viewMode: 'overview', semanticThreshold: 0.85, source: 'unknown' };

      function shortenLabel(node) {
        if (node.display_label !== undefined && node.display_label !== null) return String(node.display_label);
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
        const lines = [
          `id: ${edge.id || ''}`,
          `source: ${edge.source || ''}`,
          `target: ${edge.target || ''}`,
          `label: ${edge.label || ''}`,
        ];
        if (edge.semantic_score !== undefined) lines.push(`semantic_score: ${edge.semantic_score}`);
        return lines.join('\\n');
      }

      function serializeNode(node) {
        return Object.assign({}, node.data(), {
          id: node.id(),
          label: node.data('label') || '',
        });
      }

      function serializeEdge(edge) {
        const data = Object.assign({}, edge.data());
        const source = edge.data('source');
        const target = edge.data('target');
        delete data.source;
        delete data.target;
        return Object.assign(data, {
          id: edge.id(),
          from: source,
          to: target,
          label: edge.data('label') || '',
        });
      }

      function serializeGraph(cy) {
        return {
          nodes: cy.nodes().map(serializeNode),
          edges: cy.edges().map(serializeEdge),
        };
      }

      function updateGraphMeta(meta) {
        currentMeta = Object.assign({}, currentMeta, meta || {});
        const metaEl = document.getElementById('graph-meta');
        if (!metaEl) return;
        metaEl.textContent = `source: ${currentMeta.source || 'unknown'} | view: ${currentMeta.viewMode || 'overview'} | semantic ≥ ${Number(currentMeta.semanticThreshold || 0).toFixed(2)}`;
      }

      async function loadGraph() {
        const view = document.getElementById('view-mode')?.value || 'overview';
        const semantic = document.getElementById('semantic-threshold')?.value || '0.85';
        const url = `/graph.json?view=${encodeURIComponent(view)}&semantic=${encodeURIComponent(semantic)}`;
        try {
          const r = await fetch(url);
          if (r.ok) {
            const payload = await r.json();
            if (payload && payload._meta) updateGraphMeta(payload._meta);
            return payload;
          }
        } catch (e) { console.warn('graph.json fetch failed, using embedded data', e); }
        updateGraphMeta(embeddedData._meta || {});
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
            const edata = Object.assign({}, e, { id: String(id), source: String(src), target: String(tgt), label: e.label || '' });
            edata.display_label = (edata.label_visibility === 'hover') ? '' : (edata.label || '');
            delete edata.from; delete edata.to;
            delete edata.displayLabel;
            els.push({ data: edata });
        });
        return els;
      }

      (async function init() {
        const data = await loadGraph();
        const elements = toCytoscapeElements(data);

        function populateClusterOptions(graphData) {
          const keys = new Set();
          (graphData.nodes || []).forEach(n => Object.keys(n).forEach(k => { if (k !== 'id' && k !== 'label') keys.add(k); }));
          const sel = document.getElementById('cluster-attr');
          if (!sel) return;
          sel.innerHTML = '<option value="__label_prefix">Label prefix</option>';
          const labelOpt = document.createElement('option'); labelOpt.value = 'label'; labelOpt.textContent = 'label'; sel.appendChild(labelOpt);
          Array.from(keys).sort().forEach(k => { const o = document.createElement('option'); o.value = k; o.textContent = k; sel.appendChild(o); });
        }

        function clearSuggestedClusters() {
          cy.nodes('.cluster.suggested').forEach(cn => {
            cn.children().forEach(ch => { ch.move({ parent: null }); });
            cy.remove(cn);
          });
        }

        function applySuggestedClusters(graphData) {
          clearSuggestedClusters();
          const suggestions = ((graphData || {})._meta || {}).clusterSuggestions || [];
          suggestions.forEach((cluster, idx) => {
            const members = (cluster.members || []).filter(id => cy.getElementById(String(id)).nonempty());
            if (members.length < 3) return;
            const cid = String(cluster.id || ('suggested_cluster_' + idx));
            if (cy.getElementById(cid).nonempty()) cy.remove(cy.getElementById(cid));
            cy.add({ data: { id: cid, label: cluster.label || ('Cluster ' + (idx + 1)) }, classes: 'cluster suggested' });
            members.forEach(id => {
              const node = cy.getElementById(String(id));
              if (node.nonempty()) node.move({ parent: cid });
            });
          });
        }

        populateClusterOptions(data);

        function layoutForMode(mode) {
          const m = String(mode || 'overview').toLowerCase();
          if (m === 'semantic') {
            return {
              name: 'cose',
              fit: true,
              animate: false,
              randomize: true,
              padding: 86,
              nodeRepulsion: 560000,
              idealEdgeLength: 260,
              edgeElasticity: 28,
              nestingFactor: 0.45,
              gravity: 0.14,
              gravityCompound: 0.1,
              componentSpacing: 220,
              numIter: 2200,
              initialTemp: 180,
              coolingFactor: 0.95,
              minTemp: 0.8,
            };
          }
          if (m === 'files') {
            return {
              name: 'cose',
              fit: true,
              animate: false,
              randomize: true,
              padding: 32,
              nodeRepulsion: 52000,
              idealEdgeLength: 82,
              edgeElasticity: 130,
              nestingFactor: 0.95,
              gravity: 0.52,
              componentSpacing: 70,
              numIter: 1100,
            };
          }
          if (m === 'topics') {
            return {
              name: 'cose',
              fit: true,
              animate: false,
              randomize: true,
              padding: 54,
              nodeRepulsion: 260000,
              idealEdgeLength: 170,
              edgeElasticity: 56,
              nestingFactor: 0.72,
              gravity: 0.24,
              componentSpacing: 130,
              numIter: 1500,
            };
          }
          return {
            name: 'cose',
            fit: true,
            animate: false,
            randomize: true,
            padding: 58,
            nodeRepulsion: 240000,
            idealEdgeLength: 160,
            edgeElasticity: 60,
            nestingFactor: 0.7,
            gravity: 0.22,
            componentSpacing: 120,
            numIter: 1400,
          };
        }

        const currentMode = (document.getElementById('view-mode') || {}).value || 'overview';
        const cy = cytoscape({ container: document.getElementById('mynetwork'), elements: elements, style: [
              { selector: 'node', style: {
                'background-color': '#1976d2',
                'label': 'data(display_label)',
                'shape': 'ellipse',
                'width': 'mapData(importance, 1, 12, 22, 46)',
                'height': 'mapData(importance, 1, 12, 22, 46)',
                'font-family': 'Inter, system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial',
                'font-weight': '500',
                'font-size': 'mapData(importance, 1, 12, 6, 9)',
                'text-valign': 'center',
                'text-halign': 'center',
                'text-wrap': 'wrap',
                'text-max-width': 96,
                'color':'#ffffff',
                'text-outline-width': 1,
                'text-outline-color':'#1976d2',
                'background-image': 'none'
              } },
              { selector: 'node:selected', style: { 'border-width': 6, 'border-color': '#ffb74d' } },
              { selector: 'node[type = "file"]', style: {
                'background-color': '#94a3b8',
                'text-outline-color': '#94a3b8',
                'shape': 'roundrectangle',
                'width': 24,
                'height': 12,
                'font-size': 4,
                'text-max-width': 56,
                'opacity': 0.22
              } },
              { selector: 'node[visual_role = "provenance"]', style: {
                'opacity': 0.14,
                'width': 18,
                'height': 10,
                'font-size': 0,
                'text-outline-width': 0
              } },
              { selector: 'node[type = "summary"]', style: {
                'background-color': '#2563eb',
                'text-outline-color': '#2563eb',
                'shape': 'round-rectangle',
                'width': 'mapData(importance, 1, 12, 18, 30)',
                'height': 'mapData(importance, 1, 12, 18, 30)',
                'font-size': 6,
                'opacity': 0.72,
                'text-max-width': 80
              } },
              { selector: 'node[type = "actor"]', style: {
                'background-color': '#d97706',
                'text-outline-color': '#d97706',
                'shape': 'hexagon',
                'width': 64,
                'height': 64
              } },
              { selector: 'node[type = "topic"]', style: {
                'background-color': '#16a34a',
                'text-outline-color': '#16a34a',
                'shape': 'diamond'
              } },
              { selector: 'node[type = "project"]', style: {
                'background-color': '#7c3aed',
                'text-outline-color': '#7c3aed',
                'shape': 'round-rectangle'
              } },
              { selector: 'node[type = "decision"]', style: {
                'background-color': '#dc2626',
                'text-outline-color': '#dc2626',
                'shape': 'vee'
              } },
              { selector: 'node[type = "issue"]', style: {
                'background-color': '#ea580c',
                'text-outline-color': '#ea580c',
                'shape': 'tag'
              } },
              { selector: 'node[type = "outcome"]', style: {
                'background-color': '#0f766e',
                'text-outline-color': '#0f766e',
                'shape': 'star'
              } },
              { selector: 'edge:selected', style: { 'line-color': '#ffb74d', 'target-arrow-color': '#ffb74d' } },
              { selector: 'node.hide-label', style: { 'label': '' } },
            { selector: 'edge', style: {
              'curve-style': 'bezier',
              'target-arrow-shape': 'triangle',
              'arrow-scale': 0.34,
              'label': 'data(display_label)',
              'text-rotation':'autorotate',
              'font-size': 5,
              'color': '#64748b',
              'text-wrap': 'wrap',
              'text-max-width': 80,
              'text-margin-y': -2,
              'line-color': '#cbd5e1',
              'target-arrow-color': '#cbd5e1',
              'opacity': 0.32,
              'width': 'mapData(semantic_score, 0.72, 0.98, 0.7, 1.8)'
              } },
              { selector: 'edge.hide-label', style: { 'label': '' } },
              { selector: 'edge[semantic_score]', style: {
                'line-style': 'dashed',
                'line-color': '#8b5cf6',
                'target-arrow-color': '#8b5cf6',
                'opacity': 'mapData(semantic_score, 0.55, 0.99, 0.12, 0.62)',
                'width': 'mapData(semantic_score, 0.55, 0.99, 0.7, 2.1)'
              } },
              { selector: 'edge[semantic_score < 0.88]', style: {
                'label': '',
                'target-arrow-shape': 'none'
              } },
              { selector: 'edge[label ^= "summarizes "]', style: {
                'line-color': '#cbd5e1',
                'target-arrow-color': '#cbd5e1',
                'opacity': 0.16,
                'width': 0.8,
                'arrow-scale': 0.22,
                'font-size': 4
              } },
              { selector: 'edge[label = "semantic summary"]', style: {
                'line-color': '#93c5fd',
                'target-arrow-color': '#93c5fd',
                'opacity': 0.22,
                'width': 1.0,
                'arrow-scale': 0.24,
                'font-size': 4
              } },
              { selector: 'edge[label = "covers topic"]', style: {
                'line-color': '#16a34a',
                'target-arrow-color': '#16a34a',
              } },
              { selector: 'edge[label = "authored by"]', style: {
                'line-color': '#b45309',
                'target-arrow-color': '#b45309',
              } },
              { selector: 'edge[label = "references file"]', style: {
                'line-color': '#94a3b8',
                'target-arrow-color': '#94a3b8',
                'opacity': 0.22,
                'arrow-scale': 0.32,
                'font-size': 5,
                'text-max-width': 72
              } },
          { selector: '.cluster', style: {
              'background-color': '#ff9800',
              'shape': 'roundrectangle',
              'label': 'data(label)',
              'text-valign': 'center',
              'color':'#000',
              'text-outline-width': 0,
              'font-size': 18,
              'font-weight': '600'
          } },
          { selector: '.cluster.suggested', style: {
              'background-color': '#cbd5e1',
              'opacity': 0.2,
              'border-width': 1,
              'border-color': '#64748b',
              'font-size': 12,
              'color': '#1e293b',
              'min-zoomed-font-size': 10
          } }
        ], layout: layoutForMode(currentMode),
        // Improve zoom behaviour across environments
        zoom: 1.0,
        minZoom: 0.2,
        maxZoom: 3,
        wheelSensitivity: 0.2,
        userZoomingEnabled: true,
        userPanningEnabled: true
        });

        function clearSuggestedClusters() {
          cy.nodes('.cluster.suggested').forEach(cn => {
            cn.children().forEach(ch => { ch.move({ parent: null }); });
            cy.remove(cn);
          });
        }

        function applySuggestedClusters(graphData) {
          clearSuggestedClusters();
          const suggestions = ((graphData || {})._meta || {}).clusterSuggestions || [];
          suggestions.forEach((cluster, idx) => {
            const members = (cluster.members || []).filter(id => cy.getElementById(String(id)).nonempty());
            if (members.length < 3) return;
            const cid = String(cluster.id || ('suggested_cluster_' + idx));
            if (cy.getElementById(cid).nonempty()) cy.remove(cy.getElementById(cid));
            cy.add({ data: { id: cid, label: cluster.label || ('Cluster ' + (idx + 1)) }, classes: 'cluster suggested' });
            members.forEach(id => {
              const node = cy.getElementById(String(id));
              if (node.nonempty()) node.move({ parent: cid });
            });
          });
        }

        if (currentMode === 'semantic') {
          applySuggestedClusters(data);
          cy.layout(layoutForMode(currentMode)).run();
        }

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
          const m = Math.min(1.35, Math.max(0.55, z));

          const nodeBase = 7;
          const edgeBase = 5;
          const outlineBase = 1;
          const minNode = 5;
          const minEdge = 4;

          const nodeSize = Math.max(minNode, Math.round(nodeBase * m));
          const edgeSize = Math.max(minEdge, Math.round(edgeBase * m));
          const outlineSize = Math.max(1, Math.round(outlineBase * m));
          const semanticLabelOn = z >= 1.02;
          const summaryLabelOn = z >= 0.96;
          const fileLabelOn = z >= 1.45;

          cy.batch(() => {
            cy.nodes().forEach(n => {
              const type = String(n.data('type') || '');
              const role = String(n.data('visual_role') || '');
              n.style('font-size', role === 'provenance' ? 0 : nodeSize);
              n.style('text-outline-width', role === 'provenance' ? 0 : outlineSize);
              n.style('font-weight', type === 'summary' ? '400' : '500');
              if (type === 'summary' && !summaryLabelOn) {
                n.style('label', '');
              } else if (role === 'provenance' && !fileLabelOn) {
                n.style('label', '');
              } else {
                n.style('label', n.data('display_label') || '');
              }
            });
            cy.edges().forEach(e => {
              e.style('font-size', edgeSize);
              const hasSemantic = e.data('semantic_score') !== undefined && e.data('semantic_score') !== null && e.data('semantic_score') !== '';
              const label = e.data('display_label') || '';
              const isSummaryEdge = label === 'semantic summary' || String(e.data('label') || '').startsWith('summarizes ');
              if ((hasSemantic || isSummaryEdge) && !semanticLabelOn) {
                e.style('label', '');
              } else if (label === 'references file' && !fileLabelOn) {
                e.style('label', '');
              } else {
                e.style('label', label);
              }
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
          const out = serializeGraph(cy);
          out.nodes.forEach(n => delete n.display_label);
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
          cy.layout(layoutForMode((document.getElementById('view-mode') || {}).value || 'overview')).run();
        });

        document.getElementById('uncluster').addEventListener('click', () => {
          cy.nodes('.cluster').forEach(cn => {
            cn.children().forEach(ch => { ch.move({ parent: null }); });
            cy.remove(cn);
          });
          cy.layout(layoutForMode((document.getElementById('view-mode') || {}).value || 'overview')).run();
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

        async function reloadGraphView() {
          const payload = await loadGraph();
          const nextMode = (document.getElementById('view-mode') || {}).value || 'overview';
          const nextElements = toCytoscapeElements(payload);
          cy.elements().remove();
          cy.add(nextElements);
          populateClusterOptions(payload);
          if (nextMode === 'semantic') {
            applySuggestedClusters(payload);
          } else {
            clearSuggestedClusters();
          }
          cy.layout(layoutForMode(nextMode)).run();
          updateLabelSizes();
          setZoomLabel();
        }

        const viewModeEl = document.getElementById('view-mode');
        const semanticThresholdEl = document.getElementById('semantic-threshold');
        const semanticThresholdValueEl = document.getElementById('semantic-threshold-value');
        if (semanticThresholdEl && semanticThresholdValueEl) {
          semanticThresholdValueEl.textContent = Number(semanticThresholdEl.value).toFixed(2);
          semanticThresholdEl.addEventListener('input', () => {
            semanticThresholdValueEl.textContent = Number(semanticThresholdEl.value).toFixed(2);
          });
          semanticThresholdEl.addEventListener('change', reloadGraphView);
        }
        if (viewModeEl) {
          viewModeEl.addEventListener('change', reloadGraphView);
        }

        // Save button
        document.getElementById('save').addEventListener('click', async () => {
          const out = serializeGraph(cy);
          out.nodes.forEach(n => delete n.display_label);
          try { await fetch('/graph.json', { method: 'POST', headers: { 'Content-Type':'application/json' }, body: JSON.stringify(out) }); alert('Saved'); } catch (e) { console.warn('save failed', e); }
        });
      })();
    </script>
  </body>
</html>
"""


def ensure_parent_dir(path: str):
    parent = os.path.dirname(os.path.abspath(os.path.expanduser(path)))
    if parent:
      os.makedirs(parent, exist_ok=True)


def generate_html(graph: dict, outpath: str):
    payload = json.dumps(graph)
    html = HTML_TMPL.replace('%s', payload, 1)
    ensure_parent_dir(outpath)
    with open(outpath, 'w', encoding='utf-8') as f:
        f.write(html)
