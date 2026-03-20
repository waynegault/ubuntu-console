import React, { useEffect, useRef, useState } from 'react'

export default function CytoscapeApp() {
  const containerRef = useRef(null)
  const cyRef = useRef(null)
  const [data, setData] = useState({ nodes: [], edges: [] })

  useEffect(() => {
    fetch('/graph.json')
      .then(r => r.json())
      .then(d => setData(d))
      .catch(() => setData({ nodes: [], edges: [] }))
  }, [])

  useEffect(() => {
    if (!containerRef.current) return
    if (!window.cytoscape) {
      console.error('cytoscape not loaded')
      return
    }

    if (cyRef.current) {
      try { cyRef.current.destroy() } catch (e) {}
      cyRef.current = null
    }

    const elements = []
    ;(data.nodes || []).forEach(n => elements.push({ data: { id: String(n.id), label: n.label || '' } }))
    ;(data.edges || []).forEach((e, i) => elements.push({ data: { id: e.id || ('e' + i), source: String(e.from), target: String(e.to), label: e.label || '' } }))

    const cy = window.cytoscape({
      container: containerRef.current,
      elements,
      style: [
        { selector: 'node', style: { 'background-color': '#1976d2', 'label': 'data(label)', 'color':'#fff', 'text-valign':'center', 'text-halign':'center', 'width':56, 'height':56 } },
        { selector: 'edge', style: { 'curve-style': 'bezier', 'target-arrow-shape': 'triangle', 'label': 'data(label)', 'text-rotation':'autorotate' } },
        { selector: ':selected', style: { 'border-width': 6, 'border-color': '#ffb74d' } }
      ],
      layout: { name: 'cose', animate: false }
    })

    // simple interactions
    cy.on('dblclick', 'node', (evt) => {
      const n = evt.target
      const cur = n.data() || {}
      const nl = prompt('Edit node label', cur.label || '')
      if (nl !== null) n.data('label', nl)
    })

    // autosave
    let last = null
    const autosave = async () => {
      const nodes = cy.nodes().map(n => ({ id: n.id(), label: n.data('label') }))
      const edges = cy.edges().map(e => ({ from: e.data('source'), to: e.data('target'), label: e.data('label') }))
      const out = { nodes, edges }
      const j = JSON.stringify(out)
      if (j !== last) {
        last = j
        try { await fetch('/graph.json', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: j }) } catch (e) { console.warn('autosave failed', e) }
      }
    }
    const iv = setInterval(autosave, 5000)

    cyRef.current = cy
    const handleResize = () => { try { cy.resize(); cy.fit() } catch (e) {} }
    window.addEventListener('resize', handleResize)

    return () => {
      clearInterval(iv)
      window.removeEventListener('resize', handleResize)
      try { cy.destroy() } catch (e) {}
      cyRef.current = null
    }
  }, [data])

  const save = async () => {
    if (!cyRef.current) return
    const nodes = cyRef.current.nodes().map(n => ({ id: n.id(), label: n.data('label') }))
    const edges = cyRef.current.edges().map(e => ({ from: e.data('source'), to: e.data('target'), label: e.data('label') }))
    const out = { nodes, edges }
    await fetch('/graph.json', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(out) })
    alert('Saved')
  }

  const addNode = () => {
    if (!cyRef.current) return
    const id = 'n' + Math.floor(Math.random() * 1e9)
    const label = prompt('Node label', 'New node') || id
    const x = Math.random() * (containerRef.current.clientWidth - 200) + 100
    const y = Math.random() * (containerRef.current.clientHeight - 200) + 100
    cyRef.current.add({ group: 'nodes', data: { id, label }, position: { x, y } })
  }

  const addEdgeMode = () => {
    if (!cyRef.current) return
    alert('Click source node then target node to create edge. Esc to cancel.')
    let src = null
    const onTap = (evt) => {
      const n = evt.target
      if (!src) { src = n.id(); n.addClass('selected-temp'); return }
      const tgt = n.id(); const id = 'e' + Math.floor(Math.random() * 1e9)
      cyRef.current.add({ group: 'edges', data: { id, source: src, target: tgt, label: '' } })
      cyRef.current.nodes().removeClass('selected-temp')
      cyRef.current.off('tap', 'node', onTap)
      window.removeEventListener('keydown', onKey)
    }
    const onKey = (e) => { if (e.key === 'Escape') { cyRef.current.nodes().removeClass('selected-temp'); cyRef.current.off('tap', 'node', onTap); window.removeEventListener('keydown', onKey) } }
    cyRef.current.on('tap', 'node', onTap)
    window.addEventListener('keydown', onKey)
  }

  const editSelected = () => {
    if (!cyRef.current) return
    const sel = cyRef.current.$(':selected')
    if (!sel || sel.length === 0) return alert('Select an element first')
    if (sel.length > 1) return alert('Select a single element')
    const el = sel[0]
    if (el.isNode && el.isNode()) {
      const nl = prompt('Edit node label', el.data('label') || '')
      if (nl !== null) el.data('label', nl)
    } else if (el.isEdge && el.isEdge()) {
      const nl = prompt('Edit edge label', el.data('label') || '')
      if (nl !== null) el.data('label', nl)
    }
  }

  const deleteSelected = () => {
    if (!cyRef.current) return
    cyRef.current.$(':selected').remove()
  }

  return (
    <div>
      <div className="toolbar">
        <button onClick={save}>Save</button>
        <button onClick={() => cyRef.current && cyRef.current.fit()}>Fit</button>
        <button onClick={addNode}>Add Node</button>
        <button onClick={addEdgeMode}>Add Edge</button>
        <button onClick={deleteSelected}>Delete Selected</button>
        <button onClick={editSelected}>Edit Selected</button>
      </div>
      <div id="container" ref={containerRef} style={{ width: '100%', height: '80vh', border: '1px solid #ddd' }} />
    </div>
  )
}
