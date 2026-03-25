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
from functools import partial

try:
  from canonical_helpers import load_canonical_data, normalize_canonical_name
except Exception:
  load_canonical_data = None
  def normalize_canonical_name(text: str) -> str:
    norm = re.sub(r'\s+', ' ', str(text or '').strip().lower())
    norm = re.sub(r'[^a-z0-9\s._:-]', ' ', norm)
    norm = re.sub(r'\s+', ' ', norm).strip(' .:-')
    return norm


MEMORY_DB_CANDIDATES = [
  '~/.openclaw/memory-system/data/memory.db',
  '~/.openclaw/memory/main.sqlite',
]

GRAPH_DB_DEFAULT = '~/.openclaw/kgraph.sqlite'
LIFE_ROOT_DEFAULT = '~/.openclaw/life'
CANONICAL_CONCEPTS_DEFAULT = '~/.openclaw/life/canonical-concepts.json'


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
        <input id="semantic-threshold" type="range" min="0.75" max="0.95" step="0.01" value="0.82" />
        <span id="semantic-threshold-value">0.82</span>
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
      let currentMeta = { viewMode: 'overview', semanticThreshold: 0.82, source: 'unknown' };

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
        const semantic = document.getElementById('semantic-threshold')?.value || '0.82';
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


def project_graph(graph: dict, mode: str = 'overview', semantic_threshold: float = 0.82) -> dict:
    """Project a raw graph into a cleaner view for browsing.

    Modes:
      - overview: curated operational summary; suppress low-signal detail
      - files: keep only file-level structure
      - topics: keep topic/actor/file relationships
      - semantic: aggressively curated semantic-only view
      - raw: return graph unchanged
    """
    mode = (mode or 'overview').lower()
    if mode == 'raw':
        return graph

    nodes = graph.get('nodes', []) or []
    edges = graph.get('edges', []) or []
    node_by_id = {str(n.get('id')): dict(n) for n in nodes if n.get('id') is not None}

    curated_edge_labels = {'covers topic', 'mentions actor', 'authored by', 'references file', 'file mentions actor', 'file authored by', 'has project', 'has decision', 'has issue', 'has outcome'}
    weak_node_labels = {
        'created', 'updated', 'watched', 'watch', 'identified', 'audited', 'added', 'removed', 'fixed', 'changed',
        'summary', 'overview', 'context', 'details', 'notes', 'status', 'result', 'results', 'outcome', 'outcomes',
        'current state', 'important technical state', 'key decisions', 'next steps', 'next actions', 'open threads',
        'work', 'project', 'issue', 'decision', 'topic', 'outcome', 'memory stack', 'graph quality'
    }

    def node_visibility(node: dict) -> str:
        return str(node.get('visibility', node.get('view_visibility', 'both')) or 'both').lower()

    def node_quality(node: dict) -> str:
        return str(node.get('quality_tier', node.get('quality', 'semantic')) or 'semantic').lower()

    def edge_visibility(edge: dict) -> str:
        return str(edge.get('visibility', edge.get('view_visibility', 'both')) or 'both').lower()

    def edge_quality(edge: dict) -> str:
        return str(edge.get('quality_tier', edge.get('quality', 'semantic')) or 'semantic').lower()

    def is_weak_label(label: str) -> bool:
        return str(label or '').strip().lower() in weak_node_labels

    semantic_core_types = {'actor', 'topic', 'summary', 'project', 'decision', 'issue', 'outcome', 'person', 'organization', 'place'}

    def is_curated_node(node: dict) -> bool:
        ntype = str(node.get('type', '') or '').lower()
        label = str(node.get('label', '') or '').strip().lower()
        visibility = node_visibility(node)
        quality = node_quality(node)
        path = str(node.get('path', '') or '').lower()
        if visibility == 'raw' or quality == 'supporting':
            return False
        if ntype == 'file' and re.search(r'(?:^|/)(?:fact-|preference-|decision-|reflection-)', path):
            return False
        if ntype in semantic_core_types or ntype == 'file':
            return True
        if label and not is_weak_label(label):
            return True
        return False

    effective_semantic_threshold = max(0.58, min(0.9, 0.58 + ((semantic_threshold - 0.5) * 0.6)))

    def is_curated_edge(edge: dict) -> bool:
        label = str(edge.get('label', '') or '')
        visibility = edge_visibility(edge)
        quality = edge_quality(edge)
        if visibility == 'raw' or quality == 'supporting':
            return False
        if label in curated_edge_labels or label == 'semantic summary' or label.startswith('summarizes '):
            return True
        if label.startswith('related') and edge.get('semantic_score') is not None:
            try:
                return float(edge.get('semantic_score')) >= effective_semantic_threshold
            except (TypeError, ValueError):
                return False
        return False

    def edge_endpoints(edge: dict) -> tuple[str | None, str | None]:
        src = edge.get('from', edge.get('source'))
        dst = edge.get('to', edge.get('target'))
        return (str(src) if src is not None else None, str(dst) if dst is not None else None)

    def node_type(node_id: str | None) -> str:
        if node_id is None:
            return ''
        return str(node_by_id.get(node_id, {}).get('type', ''))

    def file_from_chunk(node_id: str | None) -> str | None:
        if node_id is None:
            return None
        for edge in edges:
            src, dst = edge_endpoints(edge)
            label = str(edge.get('label', ''))
            if label != 'contains chunk':
                continue
            if dst == node_id and node_type(src) == 'file':
                return src
        return None

    def dedupe_append(out_edges: list, seen: set, source: str | None, target: str | None, label: str, payload: dict | None = None):
        if not source or not target:
            return
        key = (source, target, label)
        if key in seen:
            return
        seen.add(key)
        item = {'from': source, 'to': target, 'label': label}
        if payload:
            item.update(payload)
        out_edges.append(item)

    def enrich_graph_payload(projected: dict, current_mode: str) -> dict:
        out = {
            'nodes': [dict(n) for n in (projected.get('nodes', []) or [])],
            'edges': [dict(e) for e in (projected.get('edges', []) or [])],
        }

        def edge_strength_value(edge: dict) -> float:
            try:
                semantic_score = float(edge.get('semantic_score', 0) or 0)
            except (TypeError, ValueError):
                semantic_score = 0.0
            try:
                cooccurrence = int(edge.get('cooccurrence_count', 0) or 0)
            except (TypeError, ValueError):
                cooccurrence = 0
            label = str(edge.get('label', '') or '').strip().lower()
            base = semantic_score
            if label in {'project decision', 'project issue', 'decision addresses issue', 'decision drives outcome'}:
                base = max(base, 0.95)
            elif label in {'project outcome', 'issue affects outcome', 'project owner'}:
                base = max(base, 0.88)
            elif label in {'project topic', 'topic decision', 'topic issue', 'topic outcome', 'actor decision', 'actor issue', 'actor outcome'}:
                base = max(base, 0.76)
            base += min(0.08, 0.02 * cooccurrence)
            return round(min(base, 0.99), 3)

        life_index = load_life_index()

        def normalized_semantic_label(node: dict) -> str:
            label = str(node.get('label', '') or '').strip().lower()
            if not label:
                return ''
            label = re.sub(r'\b(?:the|a|an)\b', ' ', label)
            label = re.sub(r'\b(?:current|important|main|primary|semantic|visual|layout)\b', ' ', label)
            label = re.sub(r'[^a-z0-9\s-]', ' ', label)
            label = re.sub(r'\s+', ' ', label).strip(' .:-')
            semantic_aliases = {
                'graph layout': 'graph quality',
                'layout quality': 'graph quality',
                'semantic graph': 'graph quality',
                'semantic threshold': 'semantic filtering',
                'semantic thresholding': 'semantic filtering',
                'topic cleanup': 'topic structure',
                'topics projection': 'topic structure',
                'topics mode': 'topic structure',
                'label cleanup': 'semantic naming',
                'naming cleanup': 'semantic naming',
            }
            for alias, canonical in semantic_aliases.items():
                if label == alias or alias in label:
                    label = canonical
                    break
            record = life_index.get('aliases', {}).get(label)
            if record:
                return str(record.get('title', label)).strip().lower()
            canonical_title = life_index.get('title_aliases', {}).get(label)
            if canonical_title:
                return str(canonical_title).strip().lower()
            return label

        def collapse_semantic_duplicates(graph_out: dict, allowed_types: set[str]) -> None:
            nodes_local = graph_out.get('nodes', []) or []
            edges_local = graph_out.get('edges', []) or []
            canonical_for = {}
            label_groups = {}
            for node in nodes_local:
                nid = str(node.get('id', '') or '')
                ntype = str(node.get('type', '') or '').lower()
                if not nid or ntype not in allowed_types:
                    continue
                norm = normalized_semantic_label(node)
                if not norm or len(norm) < 4:
                    continue
                key = (ntype, norm)
                label_groups.setdefault(key, []).append(node)
            for members in label_groups.values():
                if len(members) < 2:
                    continue
                members_sorted = sorted(
                    members,
                    key=lambda n: (
                        int(bool(n.get('inferred_type'))),
                        -float(n.get('type_confidence', 1.0) or 1.0),
                        -len(str(n.get('label', '') or '')),
                        str(n.get('id', '') or ''),
                    )
                )
                canonical = str(members_sorted[0].get('id'))
                for node in members_sorted:
                    canonical_for[str(node.get('id'))] = canonical
            if not canonical_for:
                return
            deduped_nodes = []
            seen_nodes = set()
            for node in nodes_local:
                nid = str(node.get('id', '') or '')
                cid = canonical_for.get(nid, nid)
                if cid != nid:
                    continue
                if cid in seen_nodes:
                    continue
                seen_nodes.add(cid)
                deduped_nodes.append(node)
            deduped_edges = []
            seen_edges = set()
            for edge in edges_local:
                src, dst = edge_endpoints(edge)
                src = canonical_for.get(src or '', src or '')
                dst = canonical_for.get(dst or '', dst or '')
                if not src or not dst or src == dst:
                    continue
                label = str(edge.get('label', '') or '')
                key = (src, dst, label)
                if key in seen_edges:
                    continue
                seen_edges.add(key)
                new_edge = dict(edge)
                new_edge['from'] = src
                new_edge['to'] = dst
                deduped_edges.append(new_edge)
            graph_out['nodes'] = deduped_nodes
            graph_out['edges'] = deduped_edges
        if current_mode in {'overview', 'topics', 'semantic'}:
            collapse_semantic_duplicates(out, {'topic', 'project', 'decision', 'issue', 'outcome', 'organization', 'place', 'person'})

        if current_mode in {'topics', 'semantic'}:
            canonical_anchor_types = {'project', 'decision', 'issue', 'outcome', 'workflow', 'system', 'repo'}
            canonical_anchor_labels = {
                normalized_semantic_label(n)
                for n in out['nodes']
                if str(n.get('type', '') or '').lower() in canonical_anchor_types
            }
            node_lookup = {str(n.get('id')): n for n in out['nodes'] if n.get('id') is not None}
            semantic_edges = []
            supporting_edges = []
            for edge in out['edges']:
                src, dst = edge_endpoints(edge)
                if not src or not dst or src not in node_lookup or dst not in node_lookup:
                    continue
                if edge.get('semantic_score') is not None or str(edge.get('label', '') or '').lower() in {
                    'project decision', 'project issue', 'project outcome', 'project topic', 'project owner',
                    'decision addresses issue', 'decision drives outcome', 'issue affects outcome',
                    'topic decision', 'topic issue', 'topic outcome', 'actor decision', 'actor issue', 'actor outcome'
                }:
                    semantic_edges.append(dict(edge))
                else:
                    supporting_edges.append(dict(edge))

            degree = {}
            scored_edges = []
            for edge in semantic_edges:
                src, dst = edge_endpoints(edge)
                strength = edge_strength_value(edge)
                src_node = node_lookup.get(src, {})
                dst_node = node_lookup.get(dst, {})
                src_label = normalized_semantic_label(src_node)
                dst_label = normalized_semantic_label(dst_node)
                src_type = str(src_node.get('type', '') or '').lower()
                dst_type = str(dst_node.get('type', '') or '').lower()
                label = str(edge.get('label', '') or '').lower()
                if label == 'semantic related':
                    if src_label in {'workspace', 'openclaw', 'gateway', 'engram', 'wayne', 'hal'} or dst_label in {'workspace', 'openclaw', 'gateway', 'engram', 'wayne', 'hal'}:
                        strength = min(strength, 0.52)
                    if canonical_anchor_labels and src_type not in canonical_anchor_types and dst_type not in canonical_anchor_types:
                        strength = min(strength, 0.62)
                if src_label in canonical_anchor_labels or dst_label in canonical_anchor_labels:
                    strength = min(0.99, strength + 0.06)
                edge['_strength'] = strength
                degree[src] = degree.get(src, 0) + 1
                degree[dst] = degree.get(dst, 0) + 1
                scored_edges.append(edge)

            neighbor_budget = {}
            for nid, deg in degree.items():
                if current_mode == 'semantic':
                    neighbor_budget[nid] = 4 if deg >= 10 else (5 if deg >= 7 else 6)
                else:
                    neighbor_budget[nid] = 5 if deg >= 10 else (6 if deg >= 7 else 7)

            kept_semantic = []
            kept_counts = {}
            seen_pairs = set()
            scored_edges_sorted = sorted(
                scored_edges,
                key=lambda e: (e.get('_strength', 0), e.get('cooccurrence_count', 0), str(e.get('label', ''))),
                reverse=True,
            )
            for edge in scored_edges_sorted:
                src, dst = edge_endpoints(edge)
                if not src or not dst:
                    continue
                pair = tuple(sorted((src, dst)))
                if pair in seen_pairs:
                    continue
                src_deg = degree.get(src, 0)
                dst_deg = degree.get(dst, 0)
                strength = float(edge.get('_strength', 0) or 0)
                threshold = 0.68
                if max(src_deg, dst_deg) >= 10:
                    threshold = 0.78 if current_mode == 'semantic' else 0.75
                elif max(src_deg, dst_deg) >= 7:
                    threshold = 0.73 if current_mode == 'semantic' else 0.71
                if strength < threshold:
                    continue
                if kept_counts.get(src, 0) >= neighbor_budget.get(src, 6) or kept_counts.get(dst, 0) >= neighbor_budget.get(dst, 6):
                    if strength < 0.88:
                        continue
                seen_pairs.add(pair)
                kept_counts[src] = kept_counts.get(src, 0) + 1
                kept_counts[dst] = kept_counts.get(dst, 0) + 1
                kept_semantic.append(edge)

            if current_mode == 'semantic' and len(kept_semantic) < 3 and scored_edges_sorted:
                fallback_counts = {}
                fallback_pairs = set()
                fallback_edges = []
                for edge in scored_edges_sorted[:24]:
                    src, dst = edge_endpoints(edge)
                    if not src or not dst:
                        continue
                    pair = tuple(sorted((src, dst)))
                    if pair in fallback_pairs:
                        continue
                    if fallback_counts.get(src, 0) >= 3 or fallback_counts.get(dst, 0) >= 3:
                        continue
                    fallback_pairs.add(pair)
                    fallback_counts[src] = fallback_counts.get(src, 0) + 1
                    fallback_counts[dst] = fallback_counts.get(dst, 0) + 1
                    fallback_edges.append(edge)
                    if len(fallback_edges) >= 10:
                        break
                if fallback_edges:
                    kept_semantic = fallback_edges

            connected_ids = set()
            for edge in kept_semantic:
                src, dst = edge_endpoints(edge)
                if src:
                    connected_ids.add(src)
                if dst:
                    connected_ids.add(dst)
            for nid, node in node_lookup.items():
                ntype = str(node.get('type', '') or '').lower()
                if ntype in canonical_anchor_types and normalized_semantic_label(node) in canonical_anchor_labels:
                    connected_ids.add(nid)

            filtered_nodes = []
            for node in out['nodes']:
                nid = str(node.get('id', '') or '')
                ntype = str(node.get('type', '') or '').lower()
                if nid in connected_ids or ntype in {'actor'}:
                    filtered_nodes.append(node)
                elif current_mode == 'topics' and ntype in {'topic', 'project', 'decision', 'issue', 'outcome'} and degree.get(nid, 0) > 0:
                    filtered_nodes.append(node)
                elif current_mode != 'semantic' and ntype in {'topic', 'project', 'decision', 'issue', 'outcome'} and adjacency.get(nid, 0) > 0:
                    filtered_nodes.append(node)

            out['nodes'] = filtered_nodes
            out['edges'] = [
                {k: v for k, v in edge.items() if k != '_strength'}
                for edge in (kept_semantic + supporting_edges)
                if (edge_endpoints(edge)[0] in {str(n.get('id')) for n in out['nodes']} and edge_endpoints(edge)[1] in {str(n.get('id')) for n in out['nodes']})
            ]

        adjacency = {}
        semantic_degree = {}
        type_counts = {}
        cluster_suggestions = []

        for edge in out['edges']:
            src, dst = edge_endpoints(edge)
            if src:
                adjacency[src] = adjacency.get(src, 0) + 1
            if dst:
                adjacency[dst] = adjacency.get(dst, 0) + 1
            if edge.get('semantic_score') is not None:
                if src:
                    semantic_degree[src] = semantic_degree.get(src, 0) + 1
                if dst:
                    semantic_degree[dst] = semantic_degree.get(dst, 0) + 1

        for node in out['nodes']:
            ntype = str(node.get('type', 'unknown') or 'unknown').lower()
            type_counts[ntype] = type_counts.get(ntype, 0) + 1

        importance_by_id = {}
        for node in out['nodes']:
            nid = str(node.get('id', ''))
            degree = adjacency.get(nid, 0)
            sdegree = semantic_degree.get(nid, 0)
            importance_by_id[nid] = max(1, degree + (2 * sdegree))

        top_label_nodes = set()
        if current_mode in {'topics', 'semantic'}:
            ranked_ids = sorted(importance_by_id.keys(), key=lambda nid: importance_by_id.get(nid, 0), reverse=True)
            limit = 18 if current_mode == 'semantic' else 24
            top_label_nodes = set(ranked_ids[:limit])

        for node in out['nodes']:
            nid = str(node.get('id', ''))
            ntype = str(node.get('type', '') or '').lower()
            degree = adjacency.get(nid, 0)
            sdegree = semantic_degree.get(nid, 0)
            node['degree'] = degree
            node['semantic_degree'] = sdegree
            node['importance'] = importance_by_id.get(nid, 1)
            node['display_group'] = ntype or 'unknown'
            if current_mode == 'overview':
                if ntype == 'file':
                    node['display_label'] = ''
                    node['visual_role'] = 'provenance'
                elif ntype in {'actor', 'topic', 'summary', 'project', 'decision', 'issue', 'outcome'}:
                    node['display_label'] = (node.get('label') or nid)[:56]
                else:
                    node['display_label'] = node.get('label') or nid
            elif current_mode == 'semantic':
                raw_label = str(node.get('label') or nid)
                if ntype == 'file' or re.match(r'^\d{4}-\d{2}-\d{2}\.md$', raw_label) or raw_label.lower() in {'memory.md', 'profile.md'}:
                    node['display_label'] = ''
                    node['visual_role'] = 'provenance'
                elif nid not in top_label_nodes and node['importance'] < 6:
                    node['display_label'] = ''
                elif ntype == 'summary':
                    node['display_label'] = raw_label[:40]
                elif ntype == 'topic':
                    node['display_label'] = raw_label[:22]
                elif ntype in {'project', 'decision', 'issue', 'outcome'}:
                    node['display_label'] = raw_label[:34]
                else:
                    node['display_label'] = raw_label[:26]
            elif current_mode == 'topics':
                raw_label = str(node.get('label') or nid)
                if nid not in top_label_nodes and node['importance'] < 5:
                    node['display_label'] = ''
                elif ntype == 'topic':
                    node['display_label'] = raw_label[:24]
                elif ntype in {'project', 'decision', 'issue', 'outcome'}:
                    node['display_label'] = raw_label[:32]
                else:
                    node['display_label'] = raw_label[:24]

        if current_mode == 'semantic':
            semantic_adj = {}
            semantic_nodes = {str(n.get('id')): n for n in out['nodes'] if n.get('id') is not None}
            strong_relation_labels = {
                'project decision', 'project issue', 'decision addresses issue', 'decision drives outcome',
                'project outcome', 'issue affects outcome', 'project owner'
            }
            medium_relation_labels = {
                'project topic', 'topic decision', 'topic issue', 'topic outcome',
                'actor decision', 'actor issue', 'actor outcome'
            }
            for edge in out['edges']:
                src, dst = edge_endpoints(edge)
                if not src or not dst or src not in semantic_nodes or dst not in semantic_nodes:
                    continue
                label = str(edge.get('label', '') or '').strip().lower()
                try:
                    semantic_score = float(edge.get('semantic_score', 0) or 0)
                except (TypeError, ValueError):
                    semantic_score = 0.0
                try:
                    cooccurrence = int(edge.get('cooccurrence_count', 0) or 0)
                except (TypeError, ValueError):
                    cooccurrence = 0
                edge_strength = semantic_score
                if label in strong_relation_labels:
                    edge_strength = max(edge_strength, 0.92)
                elif label in medium_relation_labels:
                    edge_strength = max(edge_strength, 0.78)
                elif cooccurrence >= 3:
                    edge_strength = max(edge_strength, 0.72)
                elif cooccurrence >= 2:
                    edge_strength = max(edge_strength, 0.66)
                if edge_strength < 0.74:
                    continue
                semantic_adj.setdefault(src, set()).add(dst)
                semantic_adj.setdefault(dst, set()).add(src)

            visited = set()
            weak_cluster_labels = {'graph quality', 'repo cleanup', 'env bridge', 'semantic filtering', 'copilot token'}
            preferred_cluster_types = ('project', 'issue', 'decision', 'outcome', 'topic', 'actor', 'person', 'organization', 'place')
            for nid in semantic_nodes:
                if nid in visited or nid not in semantic_adj:
                    continue
                stack = [nid]
                component = []
                visited.add(nid)
                while stack:
                    cur = stack.pop()
                    component.append(cur)
                    for nxt in semantic_adj.get(cur, set()):
                        if nxt not in visited:
                            visited.add(nxt)
                            stack.append(nxt)
                if len(component) < 3:
                    continue
                ranked = sorted(
                    component,
                    key=lambda cid: (
                        semantic_nodes[cid].get('semantic_degree', 0),
                        semantic_nodes[cid].get('importance', 0),
                        semantic_nodes[cid].get('degree', 0),
                        len(str(semantic_nodes[cid].get('label', '') or ''))
                    ),
                    reverse=True,
                )
                label_parts = []
                chosen_types = set()
                for preferred_type in preferred_cluster_types:
                    for cid in ranked:
                        node = semantic_nodes[cid]
                        label = str(node.get('label', '') or '').strip()
                        if not label:
                            continue
                        lowered = label.lower()
                        if lowered in weak_cluster_labels:
                            continue
                        node_type = str(node.get('type', '') or '').lower()
                        if node_type != preferred_type or node_type in chosen_types:
                            continue
                        if lowered in [x.lower() for x in label_parts]:
                            continue
                        label_parts.append(label)
                        chosen_types.add(node_type)
                        break
                    if len(label_parts) >= 2:
                        break
                if not label_parts:
                    for cid in ranked:
                        label = str(semantic_nodes[cid].get('label', '') or '').strip()
                        if not label:
                            continue
                        lowered = label.lower()
                        if lowered in weak_cluster_labels:
                            continue
                        if lowered not in [x.lower() for x in label_parts]:
                            label_parts.append(label)
                        if len(label_parts) >= 2:
                            break
                if len(label_parts) >= 2:
                    primary = label_parts[0]
                    secondary = label_parts[1]
                    cluster_label = f'{primary} · {secondary}'
                elif label_parts:
                    dominant_type = str(semantic_nodes[ranked[0]].get('type', '') or '').lower() if ranked else ''
                    type_hint = dominant_type if dominant_type and dominant_type not in {'topic', 'actor'} else 'cluster'
                    cluster_label = f'{label_parts[0]} ({type_hint})'
                else:
                    cluster_label = f'cluster {len(cluster_suggestions) + 1}'
                cluster_suggestions.append({
                    'id': f'semantic_cluster_{len(cluster_suggestions) + 1}',
                    'label': cluster_label[:64],
                    'members': component,
                    'size': len(component),
                })

        out['_meta'] = dict(out.get('_meta', {}))
        out['_meta']['typeCounts'] = type_counts
        out['_meta']['nodeCount'] = len(out['nodes'])
        out['_meta']['edgeCount'] = len(out['edges'])
        if cluster_suggestions:
            out['_meta']['clusterSuggestions'] = cluster_suggestions
        return out

    if mode == 'semantic':
        keep_edges = []
        keep_nodes = set()
        seen = set()
        concept_types = {'topic', 'project', 'decision', 'issue', 'outcome', 'actor', 'person', 'organization', 'place'}
        anchor_types = {'project', 'decision', 'issue', 'outcome'}
        preferred_semantic_types = {'project', 'decision', 'issue', 'outcome', 'actor', 'person', 'organization', 'place'}
        concept_nodes = {}
        summary_to_concepts = {}
        chunk_to_concepts = {}
        concept_to_summaries = {}
        concept_to_chunks = {}
        inferred_scores = {}

        def semantic_node_ok(node: dict) -> bool:
            if not node:
                return False
            ntype = str(node.get('type', '') or '').lower()
            if ntype not in concept_types:
                return False
            if not is_curated_node(node):
                return False
            if ntype == 'topic' and is_weak_label(node.get('label', '')):
                return False
            return True

        def apply_canonical_semantic_bias(node: dict) -> dict:
            if not node:
                return node
            updated = dict(node)
            raw_label = str(updated.get('label', '') or '').strip()
            if not raw_label:
                return updated
            norm = re.sub(r'\s+', ' ', raw_label.lower()).strip()
            record = life_index.get('aliases', {}).get(norm)
            if not record:
                return updated
            updated['label'] = str(record.get('title') or raw_label)
            record_type = str(record.get('type', '') or '').lower()
            current_type = str(updated.get('type', '') or '').lower()
            if record_type in concept_types and current_type == 'topic':
                updated['type'] = record_type
                updated['inferred_type'] = record_type
                updated['type_confidence'] = max(float(updated.get('type_confidence', 0.0) or 0.0), 0.96)
            updated['canonical_slug'] = str(record.get('slug') or '')
            updated['canonical_path'] = str(record.get('path') or '')
            return updated

        for nid, node in node_by_id.items():
            if semantic_node_ok(node):
                concept_nodes[nid] = apply_canonical_semantic_bias(node)

        direct_edges = []
        for edge in edges:
            src, dst = edge_endpoints(edge)
            src_node = node_by_id.get(src or '')
            dst_node = node_by_id.get(dst or '')
            if not src_node or not dst_node:
                continue
            src_type = str(src_node.get('type', '') or '').lower()
            dst_type = str(dst_node.get('type', '') or '').lower()

            if src in concept_nodes and dst in concept_nodes:
                payload = {}
                if edge.get('semantic_score') is not None:
                    try:
                        payload['semantic_score'] = round(float(edge.get('semantic_score') or 0), 3)
                    except (TypeError, ValueError):
                        pass
                label = str(edge.get('label', '') or '').strip().lower()
                if is_curated_edge(edge) or label in {
                    'project decision', 'project issue', 'project outcome', 'project topic', 'project owner',
                    'decision addresses issue', 'decision drives outcome', 'issue affects outcome',
                    'topic decision', 'topic issue', 'topic outcome', 'actor decision', 'actor issue', 'actor outcome'
                }:
                    direct_edges.append((src, dst, edge.get('label', 'related'), payload))
                continue

            if src_type == 'summary' and dst in concept_nodes:
                summary_to_concepts.setdefault(src, set()).add(dst)
                concept_to_summaries.setdefault(dst, set()).add(src)
                continue
            if dst_type == 'summary' and src in concept_nodes:
                summary_to_concepts.setdefault(dst, set()).add(src)
                concept_to_summaries.setdefault(src, set()).add(dst)
                continue

            if src_type == 'chunk' and dst in concept_nodes:
                chunk_to_concepts.setdefault(src, set()).add(dst)
                concept_to_chunks.setdefault(dst, set()).add(src)
                continue
            if dst_type == 'chunk' and src in concept_nodes:
                chunk_to_concepts.setdefault(dst, set()).add(src)
                concept_to_chunks.setdefault(src, set()).add(dst)
                continue

        for members in summary_to_concepts.values():
            member_list = sorted(members)
            if len(member_list) < 2:
                continue
            for i, a in enumerate(member_list):
                for b in member_list[i + 1:]:
                    pair = tuple(sorted((a, b)))
                    inferred_scores.setdefault(pair, {'summary': 0, 'chunk': 0})
                    inferred_scores[pair]['summary'] += 1

        for members in chunk_to_concepts.values():
            member_list = sorted(members)
            if len(member_list) < 2:
                continue
            for i, a in enumerate(member_list):
                for b in member_list[i + 1:]:
                    pair = tuple(sorted((a, b)))
                    inferred_scores.setdefault(pair, {'summary': 0, 'chunk': 0})
                    inferred_scores[pair]['chunk'] += 1

        node_strength = {}
        for nid, node in concept_nodes.items():
            ntype = str(node.get('type', '') or '').lower()
            strength = 1.0
            if ntype in anchor_types:
                strength += 3.0
            elif ntype in preferred_semantic_types:
                strength += 2.0
            strength += min(2.5, 0.7 * len(concept_to_summaries.get(nid, set())))
            strength += min(2.0, 0.45 * len(concept_to_chunks.get(nid, set())))
            conf = float(node.get('type_confidence', 1.0) or 1.0)
            strength += max(0.0, conf - 0.75)
            if node.get('inferred_type'):
                strength -= 0.25
            node_strength[nid] = round(strength, 3)

        direct_pairs = set()
        for src, dst, label, payload in sorted(direct_edges, key=lambda item: (
            float((item[3] or {}).get('semantic_score', 0) or 0),
            node_strength.get(item[0], 0) + node_strength.get(item[1], 0)
        ), reverse=True):
            dedupe_append(keep_edges, seen, src, dst, label, payload or None)
            direct_pairs.add(tuple(sorted((src, dst))))
            keep_nodes.add(src)
            keep_nodes.add(dst)

        inferred_edge_candidates = []
        for (a, b), support in inferred_scores.items():
            a_node = concept_nodes.get(a)
            b_node = concept_nodes.get(b)
            if not a_node or not b_node:
                continue
            a_type = str(a_node.get('type', '') or '').lower()
            b_type = str(b_node.get('type', '') or '').lower()
            summary_support = int(support.get('summary', 0) or 0)
            chunk_support = int(support.get('chunk', 0) or 0)
            if summary_support <= 0 and chunk_support <= 0:
                continue
            score = 0.0
            score += min(0.5, 0.18 * summary_support)
            score += min(0.35, 0.12 * chunk_support)
            if a_type in anchor_types or b_type in anchor_types:
                score += 0.12
            if a_type == b_type and a_type == 'topic':
                score -= 0.08
            if a_type == 'topic' or b_type == 'topic':
                score -= 0.03
            score += min(0.2, 0.02 * (node_strength.get(a, 0) + node_strength.get(b, 0)))
            if score < 0.36:
                continue
            inferred_edge_candidates.append((
                a,
                b,
                'semantic related',
                {
                    'semantic_score': round(min(score, 0.95), 3),
                    'cooccurrence_count': summary_support + chunk_support,
                    'inferred': True,
                    'support_summary_count': summary_support,
                    'support_chunk_count': chunk_support,
                }
            ))

        inferred_edge_candidates.sort(
            key=lambda item: (
                float((item[3] or {}).get('semantic_score', 0) or 0),
                (item[3] or {}).get('cooccurrence_count', 0),
                node_strength.get(item[0], 0) + node_strength.get(item[1], 0)
            ),
            reverse=True,
        )

        inferred_neighbor_counts = {}
        for src, dst, label, payload in inferred_edge_candidates:
            pair = tuple(sorted((src, dst)))
            if pair in direct_pairs:
                continue
            src_budget = 4 if node_strength.get(src, 0) >= 5.5 else 3
            dst_budget = 4 if node_strength.get(dst, 0) >= 5.5 else 3
            if inferred_neighbor_counts.get(src, 0) >= src_budget or inferred_neighbor_counts.get(dst, 0) >= dst_budget:
                if float((payload or {}).get('semantic_score', 0) or 0) < 0.72:
                    continue
            dedupe_append(keep_edges, seen, src, dst, label, payload or None)
            keep_nodes.add(src)
            keep_nodes.add(dst)
            inferred_neighbor_counts[src] = inferred_neighbor_counts.get(src, 0) + 1
            inferred_neighbor_counts[dst] = inferred_neighbor_counts.get(dst, 0) + 1

        if len(keep_edges) < 6:
            for nid, _score in sorted(node_strength.items(), key=lambda item: item[1], reverse=True)[:18]:
                keep_nodes.add(nid)
            fallback_pairs = []
            for a, b, label, payload in inferred_edge_candidates:
                fallback_pairs.append((a, b, label, payload))
                if len(fallback_pairs) >= 18:
                    break
            if not fallback_pairs:
                strong_nodes = [nid for nid, _score in sorted(node_strength.items(), key=lambda item: item[1], reverse=True)[:10]]
                for idx, src in enumerate(strong_nodes):
                    for dst in strong_nodes[idx + 1: idx + 3]:
                        if src == dst:
                            continue
                        fallback_pairs.append((src, dst, 'semantic related', {'semantic_score': 0.42, 'inferred': True, 'fallback': True}))
                        if len(fallback_pairs) >= 10:
                            break
                    if len(fallback_pairs) >= 10:
                        break
            for src, dst, label, payload in fallback_pairs:
                dedupe_append(keep_edges, seen, src, dst, label, payload or None)
                keep_nodes.add(src)
                keep_nodes.add(dst)

        if not keep_nodes:
            for nid, _score in sorted(node_strength.items(), key=lambda item: item[1], reverse=True)[:14]:
                keep_nodes.add(nid)

        return enrich_graph_payload({
            'nodes': [node_by_id[nid] for nid in keep_nodes if nid in node_by_id],
            'edges': keep_edges,
        }, mode)

    out_nodes = {}
    out_edges = []
    seen_edges = set()

    def keep_node(nid: str | None):
        if nid and nid in node_by_id:
            out_nodes[nid] = node_by_id[nid]

    if mode == 'files':
        for nid, node in node_by_id.items():
            if str(node.get('type', '')) == 'file':
                out_nodes[nid] = node
        for edge in edges:
            src, dst = edge_endpoints(edge)
            label = str(edge.get('label', ''))
            if node_type(src) == 'file' and node_type(dst) == 'file':
                dedupe_append(out_edges, seen_edges, src, dst, label)
        return enrich_graph_payload({'nodes': list(out_nodes.values()), 'edges': out_edges}, mode)

    for nid, node in node_by_id.items():
        ntype = str(node.get('type', ''))
        if mode == 'topics':
            if ntype in {'topic', 'actor', 'project', 'decision', 'issue', 'outcome', 'person', 'organization', 'place'}:
                out_nodes[nid] = node
        else:  # overview
            if ntype == 'chunk':
                continue
            if ntype in semantic_core_types:
                out_nodes[nid] = node
                continue
            if ntype == 'file':
                continue
            if is_curated_node(node) and ntype not in {'file'}:
                out_nodes[nid] = node

    for edge in edges:
        src, dst = edge_endpoints(edge)
        label = str(edge.get('label', ''))
        src_type = node_type(src)
        dst_type = node_type(dst)

        if mode == 'topics':
            if src in out_nodes and dst in out_nodes:
                if label in {'project topic', 'topic decision', 'topic issue', 'topic outcome', 'actor decision', 'actor issue', 'actor outcome', 'project owner', 'project decision', 'project issue', 'project outcome', 'decision addresses issue', 'decision drives outcome', 'issue affects outcome'}:
                    payload = {'semantic_score': edge.get('semantic_score')} if edge.get('semantic_score') is not None else None
                    dedupe_append(out_edges, seen_edges, src, dst, label, payload)
                    continue
                if label in {'covers topic', 'mentions actor', 'authored by'} and src_type != 'file' and dst_type != 'file':
                    dedupe_append(out_edges, seen_edges, src, dst, label)
                    continue
            if src_type == 'chunk' and dst in out_nodes and label in {'covers topic', 'mentions actor', 'authored by', 'has project', 'has decision', 'has issue', 'has outcome', 'has person', 'has organization', 'has place'}:
                continue
            if src in out_nodes and dst_type == 'chunk' and label == 'contains chunk':
                continue
            if src_type == 'chunk' and dst_type == 'file' and label == 'references file':
                continue
        else:  # overview
            if src in out_nodes and dst in out_nodes and label != 'contains chunk':
                if src_type == 'file' and dst_type in {'topic', 'actor', 'project', 'decision', 'issue', 'outcome'} and label in curated_edge_labels:
                    # Prefer chunk-derived lifted structure over direct file fan-out to reduce starbursts.
                    continue
                if not is_curated_edge(edge) and label not in curated_edge_labels:
                    continue
                payload = None
                if edge.get('semantic_score') is not None:
                    payload = {'semantic_score': edge.get('semantic_score')}
                dedupe_append(out_edges, seen_edges, src, dst, label, payload)
                continue
            if src_type == 'chunk' and dst in out_nodes:
                parent_file = file_from_chunk(src)
                if parent_file in out_nodes:
                    mapped_label = 'file ' + label if label not in {'references file'} else 'references file'
                    if label in {'has project', 'has decision', 'has issue', 'has outcome'}:
                        dedupe_append(out_edges, seen_edges, parent_file, dst, label)
                    elif mapped_label in curated_edge_labels or label in curated_edge_labels:
                        dedupe_append(out_edges, seen_edges, parent_file, dst, mapped_label)
                continue
            if src in out_nodes and dst_type == 'chunk' and label == 'contains chunk':
                continue

    return enrich_graph_payload({'nodes': list(out_nodes.values()), 'edges': out_edges}, mode)


def resolve_serve_target(path: str, force_embed: bool = False) -> tuple[str, str, bool]:
  """Return the directory, filename, and frontend mode used for serving."""
  repo_root = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
  static_dir = os.path.join(repo_root, 'frontend-g6', 'dist')
  use_built_frontend = (not force_embed) and os.path.isdir(static_dir)

  if use_built_frontend:
    return static_dir, 'index.html', True

  dirname = os.path.abspath(os.path.dirname(path) or '.')
  filename = os.path.basename(path)
  return dirname, filename, False


def resolve_memory_db_path(preferred: str | None = None) -> str | None:
  if preferred:
    p = os.path.expanduser(preferred)
    return p if os.path.exists(p) else None
  for candidate in MEMORY_DB_CANDIDATES:
    p = os.path.expanduser(candidate)
    if os.path.exists(p):
      return p
  return None


def resolve_life_root(preferred: str | None = None) -> str:
  root = os.path.expanduser(preferred or LIFE_ROOT_DEFAULT)
  return os.path.abspath(root)


def load_life_index(life_root: str | None = None) -> dict:
  root = resolve_life_root(life_root)
  index = {
    'by_slug': {},
    'aliases': {},
    'by_type': {},
    'title_aliases': {},
    'records': [],
  }

  canonical_json = os.path.expanduser(CANONICAL_CONCEPTS_DEFAULT)
  if os.path.isfile(canonical_json):
    try:
      payload = load_canonical_data() if load_canonical_data else json.loads(open(canonical_json, 'r', encoding='utf-8').read())
      for record in payload.get('records', []):
        rec = {
          'slug': str(record.get('slug') or '').strip().lower(),
          'title': str(record.get('title') or '').strip(),
          'type': str(record.get('type') or '').strip().lower(),
          'path': str(record.get('path') or '').strip(),
          'aliases': list(record.get('aliases') or []),
          'status': str(record.get('status') or '').strip().lower(),
        }
        if not rec['slug']:
          continue
        index['records'].append(rec)
        index['by_slug'][rec['slug']] = rec
        index['by_type'].setdefault(rec['type'], []).append(rec)
        canonical_names = [rec['slug'], rec['title']] + rec['aliases']
        for alias in canonical_names:
          norm = normalize_canonical_name(str(alias or ''))
          if norm:
            index['aliases'][norm] = rec
            index['title_aliases'][norm] = rec['title']
      if index['records']:
        return index
    except Exception:
      pass

  if not os.path.isdir(root):
    return index

  type_dirs = ('people', 'agents', 'projects', 'systems', 'repos', 'decisions', 'preferences', 'workflows')
  frontmatter_pat = re.compile(r'^-\s*([a-zA-Z0-9_]+):\s*(.*)$')

  for type_dir in type_dirs:
    base = os.path.join(root, type_dir)
    if not os.path.isdir(base):
      continue
    for name in sorted(os.listdir(base)):
      if not name.endswith('.md'):
        continue
      path = os.path.join(base, name)
      try:
        text = open(path, 'r', encoding='utf-8').read()
      except Exception:
        continue
      lines = text.splitlines()
      title = ''
      metadata = {}
      aliases = []
      in_aliases = False
      for line in lines:
        if line.startswith('# '):
          title = line[2:].strip()
          continue
        m = frontmatter_pat.match(line)
        if m:
          key = m.group(1).strip().lower()
          val = m.group(2).strip()
          metadata[key] = val
          in_aliases = key == 'aliases'
          continue
        if in_aliases and re.match(r'^\s*-\s+', line):
          aliases.append(re.sub(r'^\s*-\s+', '', line).strip())
          continue
        if line.strip() and not line.startswith('  -'):
          in_aliases = False
      slug = os.path.splitext(name)[0].strip().lower()
      rec_type = (metadata.get('type') or type_dir[:-1]).strip().lower()
      record = {
        'slug': slug,
        'title': title or slug,
        'type': rec_type,
        'path': path,
        'aliases': aliases,
        'status': (metadata.get('status') or '').strip().lower(),
      }
      index['records'].append(record)
      index['by_slug'][slug] = record
      index['by_type'].setdefault(rec_type, []).append(record)
      canonical_names = [slug, title] + aliases
      for alias in canonical_names:
        norm = normalize_canonical_name(str(alias or ''))
        if norm:
          index['aliases'][norm] = record
          index['title_aliases'][norm] = record['title']
  return index


def init_graph_db(dbpath: str):
  path = os.path.expanduser(dbpath)
  ensure_parent_dir(path)
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


def serve_file(path: str, host: str = '127.0.0.1', port: int = 0, store_path: str | None = None, force_embed: bool = False, graph_db_path: str | None = None, view_mode: str = 'overview', semantic_threshold: float = 0.82):
  serve_dir, filename, using_built_frontend = resolve_serve_target(path, force_embed=force_embed)

  _CORS_HEADERS = [
    ('Access-Control-Allow-Origin', '*'),
    ('Access-Control-Allow-Methods', 'GET, POST, OPTIONS'),
    ('Access-Control-Allow-Headers', 'Content-Type'),
  ]

  initial_view_mode = (view_mode or 'overview').lower()
  initial_semantic_threshold = float(semantic_threshold)

  class GraphRequestHandler(SimpleHTTPRequestHandler):
    def __init__(self, *args, directory=None, **kwargs):
      super().__init__(*args, directory=directory or serve_dir, **kwargs)

    store = store_path or os.path.expanduser('~/.openclaw/kgraph.json')
    graph_db = graph_db_path or os.path.expanduser(GRAPH_DB_DEFAULT)
    view_mode = initial_view_mode
    semantic_threshold = initial_semantic_threshold
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
      request_path = self.path.split('?', 1)[0]
      if request_path == '/graph.json':
        query = {}
        if '?' in self.path:
          for part in self.path.split('?', 1)[1].split('&'):
            if not part:
              continue
            key, _, value = part.partition('=')
            query[key] = value
        req_view_mode = query.get('view', self.view_mode)
        try:
          req_semantic = float(query.get('semantic', self.semantic_threshold))
        except (TypeError, ValueError):
          req_semantic = self.semantic_threshold
        try:
            graph_db_exists = bool(self.graph_db and os.path.exists(os.path.expanduser(self.graph_db)))
            memory_db_exists = bool(self.memory_db and os.path.exists(self.memory_db))

            # Semantic / overview / topics / files should project from memory-derived graph when available.
            # Raw is the place where user-edited graph DB should dominate.
            prefer_memory_projection = req_view_mode in {'semantic', 'overview', 'topics', 'files'}

            base_graph = None
            source_name = 'sample'

            if prefer_memory_projection and memory_db_exists:
              try:
                base_graph = load_from_memory_db(self.memory_db)
                source_name = 'memory-db'
              except Exception:
                base_graph = {'nodes': [], 'edges': []}
              if (not base_graph.get('nodes')) and (not base_graph.get('edges')) and graph_db_exists:
                user_graph = load_from_graph_db(self.graph_db)
                if user_graph.get('nodes') or user_graph.get('edges'):
                  base_graph = user_graph
                  source_name = 'graph-db'
              if (not base_graph.get('nodes')) and (not base_graph.get('edges')) and os.path.isfile(self.store):
                with open(self.store, 'r', encoding='utf-8') as f:
                  base_graph = json.load(f)
                source_name = 'json-store'
              if base_graph is None or ((not base_graph.get('nodes')) and (not base_graph.get('edges')) and not os.path.isfile(self.store)):
                base_graph = SAMPLE_GRAPH
                source_name = 'sample'
            elif graph_db_exists:
              user_graph = load_from_graph_db(self.graph_db)
              if user_graph.get('nodes') or user_graph.get('edges'):
                base_graph = user_graph
                source_name = 'graph-db'
              elif memory_db_exists:
                try:
                  base_graph = load_from_memory_db(self.memory_db)
                  source_name = 'memory-db'
                except Exception:
                  base_graph = {'nodes': [], 'edges': []}
                if (not base_graph.get('nodes')) and (not base_graph.get('edges')) and os.path.isfile(self.store):
                  with open(self.store, 'r', encoding='utf-8') as f:
                    base_graph = json.load(f)
                  source_name = 'json-store'
                elif (not base_graph.get('nodes')) and (not base_graph.get('edges')):
                  base_graph = SAMPLE_GRAPH
                  source_name = 'sample'
              elif os.path.isfile(self.store):
                with open(self.store, 'r', encoding='utf-8') as f:
                  base_graph = json.load(f)
                source_name = 'json-store'
              else:
                base_graph = SAMPLE_GRAPH
                source_name = 'sample'
            elif memory_db_exists:
              try:
                base_graph = load_from_memory_db(self.memory_db)
                source_name = 'memory-db'
              except Exception:
                base_graph = {'nodes': [], 'edges': []}
              if (not base_graph.get('nodes')) and (not base_graph.get('edges')) and os.path.isfile(self.store):
                with open(self.store, 'r', encoding='utf-8') as f:
                  base_graph = json.load(f)
                source_name = 'json-store'
              elif (not base_graph.get('nodes')) and (not base_graph.get('edges')):
                base_graph = SAMPLE_GRAPH
                source_name = 'sample'
            elif os.path.isfile(self.store):
              with open(self.store, 'r', encoding='utf-8') as f:
                base_graph = json.load(f)
              source_name = 'json-store'
            else:
              base_graph = SAMPLE_GRAPH
              source_name = 'sample'

            projected = project_graph(base_graph, mode=req_view_mode, semantic_threshold=req_semantic)
            meta = {
              'viewMode': req_view_mode,
              'semanticThreshold': req_semantic,
              'source': source_name
            }
            payload = dict(projected)
            payload['_meta'] = dict(payload.get('_meta', {}))
            payload['_meta'].update(meta)
            data = json.dumps(payload)
        except Exception:
            # final fallback to sample graph
            fallback = project_graph(SAMPLE_GRAPH, mode=req_view_mode, semantic_threshold=req_semantic)
            fallback['_meta'] = {
              'viewMode': req_view_mode,
              'semanticThreshold': req_semantic,
              'source': 'sample'
            }
            data = json.dumps(fallback)
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
          ensure_parent_dir(self.store)
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

  handler = partial(GraphRequestHandler, directory=serve_dir)
  httpd = HTTPServer((host, port), handler)
  addr, used_port = httpd.server_address
  # If serving the built frontend, point root to index.html
  if using_built_frontend:
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
        life_index = load_life_index()
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

        def add_topic_node(heading_text: str) -> 'str | None':
            """Create a topic node from a markdown heading; returns id or None for trivial headings."""
            clean = re.sub(r'[^\x00-\x7E]', '', heading_text).strip()
            clean = re.sub(r'\s+', ' ', clean)
            if len(clean) < 4:
                return None
            tid = f'topic:{_slug(clean[:60])}'
            add_node({
                'id': tid,
                'label': clean[:60],
                'type': 'topic',
                'content_preview': clean,
            })
            return tid

        scaffolding_labels = {
            'summary', 'overview', 'context', 'details', 'notes', 'durable notes', 'working style',
            'memory routing', 'memory architecture', 'memory layers', 'core identity', 'what changed',
            'current state', 'important technical state', 'audit findings', 'key decisions', 'rationale',
            'next actions', 'next action', 'next steps', 'next step', 'open threads', 'open thread',
            'open items', 'todo', 'todos', 'status', 'result', 'results', 'outcome', 'outcomes',
            'memory md', 'profile md', 'daily note', 'daily notes', 'semantic', 'files', 'overview', 'raw'
        }
        concept_aliases = {
            'graph quality': 'graph quality',
            'graph layout quality': 'graph quality',
            'layout quality': 'graph quality',
            'semantic graph quality': 'graph quality',
            'semantic graph': 'graph quality',
            'graph layout': 'graph quality',
            'layout readability': 'graph quality',
            'memory stack': 'memory stack',
            'repo cleanup': 'repo cleanup',
            'repository cleanup': 'repo cleanup',
            'clean repo state': 'repo cleanup',
            'history rewrite': 'repo cleanup',
            'force push': 'repo cleanup',
            'git cleanup': 'repo cleanup',
            'git history rewrite': 'repo cleanup',
            'gateway token rotation': 'gateway token rotation',
            'token rotation': 'gateway token rotation',
            'rotate gateway token': 'gateway token rotation',
            'semantic filtering': 'semantic filtering',
            'semantic suppression': 'semantic filtering',
            'semantic projection': 'semantic filtering',
            'semantic decluttering': 'semantic filtering',
            'semantic thresholding': 'semantic filtering',
            'semantic threshold': 'semantic filtering',
            'oauth secret refs': 'oauth secret refs',
            'oauth refs': 'oauth secret refs',
            'secret refs': 'oauth secret refs',
            'oauth ref support': 'oauth secret refs',
            'env bridge': 'env bridge',
            'environment bridge': 'env bridge',
            'windows env bridge': 'env bridge',
            'wsl env bridge': 'env bridge',
            'systemd env bridge': 'env bridge',
            'bridge generation': 'env bridge',
            'copilot token exchange': 'copilot token',
            'github copilot token': 'copilot token',
            'copilot token': 'copilot token',
            'copilot auth': 'copilot token',
            'profile duplication': 'profile deduplication',
            'duplicate profile bullets': 'profile deduplication',
            'profile dedupe': 'profile deduplication',
            'profile deduplication': 'profile deduplication',
            'launcher fix': 'launcher reliability',
            'launcher behavior': 'launcher reliability',
            'oc g launcher': 'launcher reliability',
            'graph source selection': 'semantic source routing',
            'semantic source bug': 'semantic source routing',
            'source routing': 'semantic source routing',
            'naming cleanup': 'semantic naming',
            'node naming': 'semantic naming',
            'label cleanup': 'semantic naming',
            'naming quality': 'semantic naming',
            'synthetic labels': 'semantic naming',
            'topic cleanup': 'topic structure',
            'topics projection': 'topic structure',
            'topics mode': 'topic structure',
        }
        low_value_semantic_concepts = {
            'workspace', 'openclaw', 'gateway', 'engram', 'wayne', 'hal',
            'linux', 'ubuntu', 'windows', 'wsl', 'wsl2', 'systemd'
        }
        canonical_wrapper_terms = {'workspace', 'openclaw', 'gateway', 'engram', 'wayne', 'hal'}

        def canonicalize_concept(kind: str, label: str) -> str | None:
            clean = re.sub(r'[^\x00-\x7E]', '', label or '').strip(' .:-')
            clean = re.sub(r'\s+', ' ', clean)
            if '|' in clean:
                parts = [p.strip() for p in clean.split('|') if p.strip()]
                preferred = []
                for part in parts:
                    lowered = part.lower().strip(' .:-')
                    if lowered.startswith(('issue:', 'decision:', 'outcome:')):
                        preferred.append(re.sub(r'^(?:issue|decision|outcome)\s*:\s*', '', part, flags=re.IGNORECASE).strip())
                    else:
                        preferred.append(part)
                clean = max(preferred, key=lambda p: (len(p.split()), len(p))) if preferred else clean
            if re.search(r'(?:^|/)(?:memory|profile|\d{4}-\d{2}-\d{2})\.md$', clean, flags=re.IGNORECASE):
                return None
            if re.match(r'^\d{4}-\d{2}-\d{2}$', clean):
                return None
            clean = re.sub(r'^(?:decision|decisions|issue|issues|problem|problems|risk|risks|blocker|blockers|concern|concerns|project|projects|workstream|workstreams|initiative|initiatives|goal|goals|focus|outcome|outcomes|result|results|status|next step|next steps)\s*[:\-]\s*', '', clean, flags=re.IGNORECASE)
            clean = clean.strip(' .:-').lower()
            if not clean or clean in scaffolding_labels:
                return None
            clean = re.sub(r'^(?:the|a|an)\s+', '', clean)
            clean = re.sub(r'^(?:work on|working on|fixing|fix|issue with|problem with|problem of|question of|question about|discussion of|notes on|notes about|update on)\s+', '', clean)
            clean = re.sub(r'\b(?:for now|currently|today|later|again|properly|correctly|carefully|really|very|fairly|quite|actual|exact|honest|remaining|new|old)\b', '', clean)
            clean = re.sub(r'\bfix launcher\b', 'launcher reliability', clean)
            clean = re.sub(r'\blauncher fix\b', 'launcher reliability', clean)
            clean = re.sub(r'\bimprove(?:d)? naming\b', 'semantic naming', clean)
            clean = re.sub(r'\bnode labels?\b', 'semantic naming', clean)
            clean = re.sub(r'\b(?:is|are|was|were|be|been|being|looks|look|seems|seem|felt|feel|using|used|showing|shows|showed|becomes|became|stays|stayed)\b', '', clean)
            clean = re.sub(r'\b(?:current|current state|important|technical|key|main|primary|secondary|future|likely|semantic|visual|layout)\b', '', clean)
            clean = re.sub(r'\b(?:that|which|still|just|basically|really)\b', '', clean)
            clean = re.sub(r'[^a-z0-9\s-]', ' ', clean)
            clean = re.sub(r'\s+', ' ', clean).strip(' .:-')
            if not clean or clean in scaffolding_labels:
                return None

            # Morphological flattening for common operational variants.
            clean = re.sub(r'\b(cleaning|cleaned)\b', 'cleanup', clean)
            clean = re.sub(r'\b(rotating|rotated)\b', 'rotation', clean)
            clean = re.sub(r'\b(duplicated|duplicate|dedupe|deduped|deduplicated)\b', 'deduplication', clean)
            clean = re.sub(r'\b(filtered|filtering)\b', 'filtering', clean)
            clean = re.sub(r'\b(layout|rendering|renderer)\b', 'layout', clean)
            clean = re.sub(r'\b(validated|validating|verify|verified|verification)\b', 'validation', clean)
            clean = re.sub(r'\b(named|naming|labels?)\b', 'naming', clean)

            words = [w for w in clean.split() if len(w) > 1 and not w.isdigit()]
            if not words:
                return None
            clean = ' '.join(words)

            # Prefer noun-phrase-like tails over action-heavy prefixes.
            clean = re.sub(r'^(?:make|making|improve|improving|improved|reduce|reducing|reduced|tighten|tightening|tightened|clean up|cleaning up|cleaned up|rewrite|rewriting|rewritten|redesign|redesigning|redesigned|rebalance|rebalancing|rebalanced|demote|demoting|demoted|collapse|collapsing|collapsed|merge|merging|merged)\s+', '', clean)
            clean = re.sub(r'^(?:carry on|continue|continuing|continued)\s+', '', clean)
            clean = re.sub(r'\b(?:too noisy|too shallow|fairly meaningless|non empty|concept led|file led|background provenance|visual hierarchy|mode specific)\b', '', clean)
            clean = re.sub(r'\s+', ' ', clean).strip(' .:-')
            if len(clean.split()) >= 3 and any(tok in clean.split() for tok in canonical_wrapper_terms):
                substantive = [w for w in clean.split() if w not in canonical_wrapper_terms]
                if len(substantive) >= 2:
                    clean = ' '.join(substantive)

            for alias, canonical in concept_aliases.items():
                if clean == alias or clean.startswith(alias + ' ') or clean.endswith(' ' + alias) or alias in clean:
                    clean = canonical
                    break

            canon_record = life_index.get('aliases', {}).get(normalize_canonical_name(clean))
            if canon_record:
                clean = str(canon_record.get('title') or clean).strip().lower()

            if clean in low_value_semantic_concepts and not canon_record and kind in {'topic', 'project', 'issue', 'decision', 'outcome', 'person', 'organization', 'place'}:
                return None

            if len(clean) < 4:
                return None
            words = clean.split()
            if len(words) > 4:
                clean = ' '.join(words[:4])
            return clean.strip(' .:-') or None

        def infer_concept_kind(kind: str, clean: str, preview: str = '') -> str:
            text = f"{clean} {preview or ''}".lower()
            canon_record = life_index.get('aliases', {}).get(normalize_canonical_name(clean))
            if canon_record and canon_record.get('type'):
                mapped = str(canon_record.get('type') or '').strip().lower()
                if mapped in {'person', 'organization', 'place', 'project', 'decision', 'issue', 'outcome', 'workflow', 'system', 'repo', 'preference', 'agent'}:
                    return mapped
            if kind == 'topic':
                if re.search(r'\b(?:decision|decided|approve|approved|choose|chose|keep|kept|replace|switched|migrate|migrated|use|using)\b', text):
                    return 'decision'
                if re.search(r'\b(?:issue|problem|risk|blocker|bug|broken|failure|failed|wrong|mismatch|noise|duplicate|duplication|shallow)\b', text):
                    return 'issue'
                if re.search(r'\b(?:result|outcome|worked|working|fixed|clean|improved|validated|verified|aligned|ready|complete|completed|passed)\b', text):
                    return 'outcome'
                if re.search(r'\b(?:repo|repository|graph|env bridge|oauth|token|memory|profile|launcher|copilot|qwen)\b', text):
                    return 'project'
            return kind

        def add_theme_node(kind: str, label: str, preview: str = '') -> str | None:
            clean = canonicalize_concept(kind, label)
            if not clean:
                return None
            canon_record = life_index.get('aliases', {}).get(normalize_canonical_name(clean))
            inferred_kind = infer_concept_kind(kind, clean, preview)
            if canon_record and canon_record.get('type'):
                canonical_type = str(canon_record.get('type') or '').strip().lower()
                if canonical_type in {'person', 'organization', 'place', 'project', 'decision', 'issue', 'outcome', 'workflow', 'system', 'repo', 'preference', 'agent'}:
                    inferred_kind = canonical_type
            inferred = inferred_kind != kind
            canonical_label = str(canon_record.get('title') or clean) if canon_record else clean
            node_id = f'{inferred_kind}:{_slug(canonical_label[:80])}'
            payload = {
                'id': node_id,
                'label': canonical_label[:80],
                'type': inferred_kind,
                'content_preview': preview or canonical_label,
                'inferred_type': inferred,
                'type_confidence': 0.96 if canon_record else (0.78 if inferred else 1.0),
            }
            if canon_record:
                payload['canonical_slug'] = str(canon_record.get('slug') or '')
                payload['canonical_path'] = str(canon_record.get('path') or '')
            add_node(payload)
            return node_id

        def concept_worthy_line(text: str) -> bool:
            line = re.sub(r'\s+', ' ', (text or '').strip())
            if not line:
                return False
            if len(line) < 10 or len(line) > 120:
                return False
            low = line.lower()
            if re.search(r'\b(?:click|button|reload|refresh|compile|py_compile|grep|sqlite|json|http|ui|screenshot|view mode|source:|semantic >=|no output|successfully replaced text)\b', low):
                return False
            if re.search(r'\b(?:\.md|/home/|kgraph\.py|graph\.json|memory-db|graph-db|json-store)\b', low):
                return False
            token_hits = [tok for tok in re.findall(r'[a-zA-Z]{3,}', low) if tok in low_value_semantic_concepts]
            alpha_words = re.findall(r'[a-zA-Z]{3,}', line)
            if token_hits and len(alpha_words) <= len(token_hits) + 1:
                return False
            return len(alpha_words) >= 2

        def extract_semantic_entities(text: str) -> list[tuple[str, str]]:
            found = []
            seen = set()
            for entity_kind, pat in (semantic_entity_patterns + canonical_entity_patterns):
                for match in pat.finditer(text or ''):
                    raw = match.group(0).strip()
                    label = canonicalize_concept(entity_kind, raw) or raw.strip().lower()
                    if not label:
                        continue
                    canon_record = life_index.get('aliases', {}).get(normalize_canonical_name(label))
                    if canon_record:
                        label = str(canon_record.get('title') or label).strip().lower()
                        entity_kind = str(canon_record.get('type') or entity_kind).strip().lower()
                    key = (entity_kind, label)
                    if key in seen:
                        continue
                    seen.add(key)
                    found.append((entity_kind, label))
            return found

        def build_chunk_semantic_summary(concept_ids: list[str], chunk_text: str) -> tuple[str, list[str], dict[str, str]]:
            buckets = {
                'project': [],
                'issue': [],
                'decision': [],
                'outcome': [],
                'actor': [],
                'organization': [],
                'place': [],
                'person': [],
            }
            seen = set()
            for cid in concept_ids:
                node = next((n for n in graph['nodes'] if str(n.get('id')) == cid), None)
                if not node:
                    continue
                label = str(node.get('label', '') or '').strip()
                ntype = str(node.get('type', '') or '').lower()
                if not label or ntype not in buckets:
                    continue
                key = (ntype, label.lower())
                if key in seen:
                    continue
                seen.add(key)
                buckets[ntype].append(label)
            typed = {}
            for key in ('project', 'issue', 'decision', 'outcome', 'actor', 'organization', 'place', 'person'):
                if buckets[key]:
                    typed[key] = buckets[key][0]
            parts = []
            if typed.get('project'):
                parts.append(typed['project'])
            if typed.get('issue'):
                parts.append(f"issue: {typed['issue']}")
            if typed.get('decision'):
                parts.append(f"decision: {typed['decision']}")
            if typed.get('outcome'):
                parts.append(f"outcome: {typed['outcome']}")
            if not parts:
                fallback = []
                for key in ('actor', 'organization', 'place', 'person'):
                    if typed.get(key):
                        fallback.append(typed[key])
                parts = fallback[:3]
            summary = ' | '.join(parts[:4]) if parts else ''
            labels = list(typed.values())[:4]
            return summary[:180], labels, typed

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
        heading_pattern = re.compile(r'^#{2,3}\s+(.+)', re.MULTILINE)
        activate_pat = re.compile(r'^#\s+([A-Z][a-z]+)-Activate\s+Report', re.MULTILINE)
        thematic_patterns = [
            ('decision', re.compile(r'^(?:[-*]\s*)?(?:decision|decided|decision made)\s*[:\-]\s*(.+)$', re.IGNORECASE | re.MULTILINE)),
            ('issue', re.compile(r'^(?:[-*]\s*)?(?:issue|problem|risk|blocker|concern)\s*[:\-]\s*(.+)$', re.IGNORECASE | re.MULTILINE)),
            ('project', re.compile(r'^(?:[-*]\s*)?(?:project|workstream|initiative|goal|focus)\s*[:\-]\s*(.+)$', re.IGNORECASE | re.MULTILINE)),
            ('outcome', re.compile(r'^(?:[-*]\s*)?(?:outcome|result|status|next step|next steps)\s*[:\-]\s*(.+)$', re.IGNORECASE | re.MULTILINE)),
        ]
        thematic_line_patterns = [
            ('decision', re.compile(r'^(?:[-*]\s*)?(?:we\s+)?(?:decided to|will|should|need to|plan to)\s+(.+)$', re.IGNORECASE)),
            ('issue', re.compile(r'^(?:[-*]\s*)?(?:the\s+)?(?:main\s+)?(?:issue|problem|risk|blocker|concern)\s+(?:is|was|remains)\s+(.+)$', re.IGNORECASE)),
            ('project', re.compile(r'^(?:[-*]\s*)?(?:work\s+on|working\s+on|focused\s+on|focus\s+on)\s+(.+)$', re.IGNORECASE)),
            ('outcome', re.compile(r'^(?:[-*]\s*)?(?:result|outcome|status|next\s+step|next\s+steps)\s+(?:is|was|remains)\s+(.+)$', re.IGNORECASE)),
        ]
        semantic_entity_patterns = [
            ('person', re.compile(r'\b(?:Wayne|Hal|Jarvis|Nexus|Marlowe|Del|Rook|Vigil|Chief|Sarah|Juno|Kai)\b')),
            ('organization', re.compile(r'\b(?:OpenClaw|Gigabrain|LCM|OpenStinger|Engram|GitHub|Tailscale|WhatsApp|Qwen|Copilot|systemd)\b', re.IGNORECASE)),
            ('place', re.compile(r'\b(?:WSL|WSL2|Windows|Ubuntu|Linux|workspace|gateway)\b', re.IGNORECASE)),
        ]
        canonical_entity_patterns = []
        for alias, record in life_index.get('aliases', {}).items():
            rtype = str(record.get('type') or '').strip().lower()
            if rtype not in {'person', 'organization', 'place', 'project', 'system', 'repo', 'workflow', 'decision', 'issue', 'outcome', 'preference', 'agent'}:
                continue
            if not alias or len(alias) < 3:
                continue
            canonical_entity_patterns.append((rtype, re.compile(rf'\b{re.escape(alias)}\b', re.IGNORECASE)))
        thematic_heading_patterns = [
            ('decision', re.compile(r'^(?:decision|decisions)\b\s*[:\-]?\s*(.+)?$', re.IGNORECASE)),
            ('issue', re.compile(r'^(?:issue|issues|problem|problems|risk|risks|blocker|blockers)\b\s*[:\-]?\s*(.+)?$', re.IGNORECASE)),
            ('project', re.compile(r'^(?:project|projects|workstream|workstreams|initiative|initiatives|focus)\b\s*[:\-]?\s*(.+)?$', re.IGNORECASE)),
            ('outcome', re.compile(r'^(?:outcome|outcomes|status|next step|next steps|result|results)\b\s*[:\-]?\s*(.+)?$', re.IGNORECASE)),
        ]
        AGENT_ROLES = {
            'Jarvis': 'Operations Director',
            'Nexus': 'Ops Director',
            'Marlowe': 'Finance Director',
            'Del': 'Sales Director',
            'Rook': 'Researcher',
            'Vigil': 'Sentinel',
            'Hal': 'CEO',
        }

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

        chunk_embeddings = []
        try:
            semantic_link_labels = {
                ('project', 'decision'): 'project decision',
                ('project', 'issue'): 'project issue',
                ('project', 'outcome'): 'project outcome',
                ('project', 'topic'): 'project topic',
                ('project', 'actor'): 'project owner',
                ('decision', 'issue'): 'decision addresses issue',
                ('decision', 'outcome'): 'decision drives outcome',
                ('issue', 'outcome'): 'issue affects outcome',
                ('topic', 'decision'): 'topic decision',
                ('topic', 'issue'): 'topic issue',
                ('topic', 'outcome'): 'topic outcome',
                ('actor', 'decision'): 'actor decision',
                ('actor', 'issue'): 'actor issue',
                ('actor', 'outcome'): 'actor outcome',
            }
            semantic_link_weights = {
                'project decision': 1.0,
                'project issue': 1.0,
                'project outcome': 0.97,
                'decision addresses issue': 1.0,
                'decision drives outcome': 0.97,
                'issue affects outcome': 0.92,
                'project owner': 0.84,
                'project topic': 0.6,
                'topic decision': 0.54,
                'topic issue': 0.52,
                'topic outcome': 0.5,
                'actor decision': 0.64,
                'actor issue': 0.6,
                'actor outcome': 0.6,
                'related concept': 0.22,
            }
            semantic_pair_stats = {}
            node_type_cache = {}

            def node_type_for(node_id: str) -> str:
                if node_id in node_type_cache:
                    return node_type_cache[node_id]
                node_type_cache[node_id] = str(next((n.get('type', '') for n in graph['nodes'] if str(n.get('id')) == node_id), '') or '')
                return node_type_cache[node_id]

            def connect_semantic_concepts(concept_ids: list[str]):
                ordered = []
                seen_ids = set()
                for cid in concept_ids:
                    if cid and cid not in seen_ids:
                        seen_ids.add(cid)
                        ordered.append(cid)
                for i in range(len(ordered)):
                    for j in range(i + 1, len(ordered)):
                        a = ordered[i]
                        b = ordered[j]
                        a_type = node_type_for(a)
                        b_type = node_type_for(b)
                        if not a_type or not b_type:
                            continue
                        label = semantic_link_labels.get((a_type, b_type)) or semantic_link_labels.get((b_type, a_type)) or 'related concept'
                        pair = tuple(sorted((a, b)))
                        stat = semantic_pair_stats.setdefault(pair, {'count': 0, 'score': 0.0, 'labels': {}})
                        stat['count'] += 1
                        stat['score'] += semantic_link_weights.get(label, 0.4)
                        stat['labels'][label] = stat['labels'].get(label, 0) + 1

            cur.execute("SELECT id, path, start_line, end_line, text, embedding FROM chunks")
            for chunk_id, path, start_line, end_line, chunk_text, emb_blob in cur.fetchall():
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

                chunk_concepts = []

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
                    chunk_concepts.append(actor_id)
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

                # Collect embedding vector for semantic similarity pass
                if emb_blob and isinstance(emb_blob, str):
                    try:
                        vec = json.loads(emb_blob)
                        if isinstance(vec, list) and len(vec) > 0:
                            mag = sum(x * x for x in vec) ** 0.5
                            if mag > 0:
                                chunk_embeddings.append((f'chunk:{chunk_key}', path or '', vec, mag))
                    except (json.JSONDecodeError, ValueError):
                        pass

                # Extract H2/H3 headings as topic nodes
                for hm in heading_pattern.finditer(chunk_text or ''):
                    topic_id = add_topic_node(hm.group(1))
                    if topic_id:
                        chunk_concepts.append(topic_id)
                        add_edge({
                            'from': f'chunk:{chunk_key}',
                            'to': topic_id,
                            'label': 'covers topic',
                        })
                        if path:
                            add_edge({
                                'from': f'file:{path}',
                                'to': topic_id,
                                'label': 'covers topic',
                            })

                # Lift higher-level semantic themes from headings and explicit summary lines
                for hm in heading_pattern.finditer(chunk_text or ''):
                    heading_text = (hm.group(1) or '').strip()
                    for kind, pat in thematic_heading_patterns:
                        m = pat.match(heading_text)
                        if not m:
                            continue
                        derived = (m.group(1) or '').strip()
                        if not derived:
                            continue
                        theme_id = add_theme_node(kind, derived, preview=heading_text)
                        if theme_id:
                            chunk_concepts.append(theme_id)
                            add_edge({
                                'from': f'chunk:{chunk_key}',
                                'to': theme_id,
                                'label': f'has {kind}',
                            })
                            if path:
                                add_edge({
                                    'from': f'file:{path}',
                                    'to': theme_id,
                                    'label': f'has {kind}',
                                })

                for kind, pat in thematic_patterns:
                    for match in pat.finditer(chunk_text or ''):
                        derived = (match.group(1) or '').strip()
                        theme_id = add_theme_node(kind, derived, preview=derived)
                        if theme_id:
                            chunk_concepts.append(theme_id)
                            add_edge({
                                'from': f'chunk:{chunk_key}',
                                'to': theme_id,
                                'label': f'has {kind}',
                            })
                            if path:
                                add_edge({
                                    'from': f'file:{path}',
                                    'to': theme_id,
                                    'label': f'has {kind}',
                                })

                for raw_line in (chunk_text or '').splitlines():
                    line = raw_line.strip()
                    if not concept_worthy_line(line):
                        continue
                    for kind, pat in thematic_line_patterns:
                        m = pat.match(line)
                        if not m:
                            continue
                        derived = (m.group(1) or '').strip(' .:-')
                        theme_id = add_theme_node(kind, derived, preview=line)
                        if theme_id:
                            chunk_concepts.append(theme_id)
                            add_edge({
                                'from': f'chunk:{chunk_key}',
                                'to': theme_id,
                                'label': f'has {kind}',
                            })
                            if path:
                                add_edge({
                                    'from': f'file:{path}',
                                    'to': theme_id,
                                    'label': f'has {kind}',
                                })
                            break

                # Detect activation-report authorship from H1 title
                for am in activate_pat.finditer(chunk_text or ''):
                    agent_name = am.group(1)
                    role = AGENT_ROLES.get(agent_name, 'Agent')
                    actor_id = add_actor_node(agent_name, role)
                    chunk_concepts.append(actor_id)
                    add_edge({
                        'from': f'chunk:{chunk_key}',
                        'to': actor_id,
                        'label': 'authored by',
                    })
                    if path:
                        add_edge({
                            'from': f'file:{path}',
                            'to': actor_id,
                            'label': 'authored by',
                        })

                for entity_kind, entity_label in extract_semantic_entities(chunk_text or ''):
                    entity_id = add_theme_node(entity_kind, entity_label, preview=entity_label)
                    if entity_id:
                        chunk_concepts.append(entity_id)
                        add_edge({
                            'from': f'chunk:{chunk_key}',
                            'to': entity_id,
                            'label': f'has {entity_kind}',
                        })

                semantic_summary, summary_labels, typed_summary = build_chunk_semantic_summary(chunk_concepts, chunk_text or '')
                if semantic_summary:
                    summary_slug = _slug(semantic_summary[:120])
                    summary_id = f'summary:{chunk_key}:{summary_slug}'
                    add_node({
                        'id': summary_id,
                        'label': semantic_summary[:180],
                        'type': 'summary',
                        'content_preview': semantic_summary,
                        'visibility': 'semantic',
                        'quality_tier': 'semantic',
                        'summary_labels': summary_labels,
                        'typed_summary': typed_summary,
                    })
                    chunk_concepts.append(summary_id)
                    add_edge({
                        'from': f'chunk:{chunk_key}',
                        'to': summary_id,
                        'label': 'semantic summary',
                        'visibility': 'semantic',
                        'quality_tier': 'semantic',
                    })
                    for summary_kind, summary_label in typed_summary.items():
                        summary_theme_id = add_theme_node(summary_kind if summary_kind != 'actor' else 'actor', summary_label, preview=semantic_summary)
                        if summary_theme_id:
                            add_edge({
                                'from': summary_id,
                                'to': summary_theme_id,
                                'label': f'summarizes {summary_kind}',
                                'visibility': 'semantic',
                                'quality_tier': 'semantic',
                            })

                connect_semantic_concepts(chunk_concepts)

            for (a, b), stat in semantic_pair_stats.items():
                best_label = max(stat['labels'].items(), key=lambda item: (item[1], semantic_link_weights.get(item[0], 0.0)))[0]
                avg_score = stat['score'] / max(stat['count'], 1)
                keep = stat['count'] >= 2 or avg_score >= 0.95
                if best_label in {'project topic', 'topic decision', 'topic issue', 'topic outcome', 'actor issue', 'actor outcome'}:
                    keep = keep and stat['count'] >= 2 and avg_score >= 0.58
                if best_label == 'related concept':
                    keep = stat['count'] >= 3 and avg_score >= 0.45
                if not keep:
                    continue
                semantic_score = round(min(0.99, 0.55 + (0.12 * min(stat['count'], 3)) + (0.18 * avg_score)), 3)
                add_edge({
                    'from': a,
                    'to': b,
                    'label': best_label,
                    'visibility': 'both',
                    'quality_tier': 'semantic',
                    'semantic_score': semantic_score,
                    'cooccurrence_count': stat['count'],
                    'label_visibility': 'visible' if semantic_score >= 0.86 or stat['count'] >= 3 else 'hover',
                })

            # Embedding-based semantic similarity (cross-file only)
            SEMANTIC_THRESHOLD = 0.75
            for i in range(len(chunk_embeddings)):
                cid_a, path_a, vec_a, mag_a = chunk_embeddings[i]
                for j in range(i + 1, len(chunk_embeddings)):
                    cid_b, path_b, vec_b, mag_b = chunk_embeddings[j]
                    if path_a == path_b:
                        continue
                    dot = sum(a * b for a, b in zip(vec_a, vec_b))
                    sim = dot / (mag_a * mag_b)
                    if sim >= SEMANTIC_THRESHOLD:
                        rounded = round(sim, 3)
                        add_edge({
                            'from': cid_a,
                            'to': cid_b,
                            'label': f'related ({sim:.2f})',
                            'semantic_score': rounded,
                        })
                        if path_a and path_b:
                            add_edge({
                                'from': f'file:{path_a}',
                                'to': f'file:{path_b}',
                                'label': f'related ({sim:.2f})',
                                'semantic_score': rounded,
                            })
        except sqlite3.Error:
            pass

    conn.close()
    return graph


if __name__ == '__main__':
    main()
