import React, { useEffect, useRef, useState } from 'react'
import G6 from '@antv/g6'

export default function App() {
  const containerRef = useRef(null)
  const graphRef = useRef(null)
  const [data, setData] = useState({ nodes: [], edges: [] })
  const [edgeMode, setEdgeMode] = useState(false)
  const edgeSrcRef = useRef(null)

  useEffect(() => {
    fetch('/graph.json')
      .then((r) => r.json())
      .then((d) => {
        setData(d)
      })
      .catch(() => {
        setData({ nodes: [], edges: [] })
      })
  }, [])

  useEffect(() => {
    if (!containerRef.current) return
    if (graphRef.current) {
      graphRef.current.destroy()
      graphRef.current = null
    }

    const width = containerRef.current.clientWidth
    const height = containerRef.current.clientHeight

    const graph = new G6.Graph({
      container: containerRef.current,
      width,
      height,
      renderer: 'canvas',
      modes: {
        default: ['drag-canvas', 'zoom-canvas', 'drag-node', 'click-select']
      },
      plugins: [new G6.Minimap({ size: [200, 100], className: 'g6-minimap' })],
      defaultNode: {
        type: 'circle',
        size: 56,
        style: { fill: '#5B8FF9', lineWidth: 0 },
        labelCfg: { style: { fill: '#fff', fontSize: 12 } }
      },
      defaultEdge: { style: { stroke: '#bfbfbf' }, type: 'line' },
      layout: { type: 'force', preventOverlap: true }
    })

    graph.data(data)
    graph.render()

    graph.on('node:click', (evt) => {
      const node = evt.item
      if (edgeMode) {
        if (!edgeSrcRef.current) {
          edgeSrcRef.current = node.getID()
          graph.setItemState(node, 'selected', true)
          return
        }
        const src = edgeSrcRef.current
        const tgt = node.getID()
        const id = 'e' + Math.floor(Math.random() * 1e9)
        graph.addItem('edge', { id, source: src, target: tgt, label: '' })
        edgeSrcRef.current = null
        setEdgeMode(false)
        graph.getNodes().forEach(n => graph.setItemState(n, 'selected', false))
        return
      }

      // normal click-select handled by mode; we additionally show a console hint
      // select is visible; editing will be provided via toolbar
    })

    graph.on('edge:click', (evt) => {
      // clicked edge; selection handled by graph
    })

    // double-click to edit node label
    graph.on('node:dblclick', (evt) => {
      const node = evt.item
      const cur = node.getModel()
      const nl = prompt('Edit node label', cur.label || '')
      if (nl !== null) graph.updateItem(node, { label: nl })
    })

    // context menu on node to edit or delete
    graph.on('node:contextmenu', (evt) => {
      evt.preventDefault && evt.preventDefault()
      const node = evt.item
      const action = prompt('Node action: edit / delete', 'edit')
      if (!action) return
      if (action.toLowerCase().startsWith('e')) {
        const cur = node.getModel()
        const nl = prompt('Edit node label', cur.label || '')
        if (nl !== null) graph.updateItem(node, { label: nl })
      } else if (action.toLowerCase().startsWith('d')) {
        graph.removeItem(node)
      }
    })

    graph.on('edge:contextmenu', (evt) => {
      evt.preventDefault && evt.preventDefault()
      const edge = evt.item
      const action = prompt('Edge action: edit / delete', 'edit')
      if (!action) return
      if (action.toLowerCase().startsWith('e')) {
        const cur = edge.getModel()
        const el = prompt('Edit edge label', cur.label || '')
        if (el !== null) graph.updateItem(edge, { label: el })
      } else if (action.toLowerCase().startsWith('d')) {
        graph.removeItem(edge)
      }
    })

    graphRef.current = graph

    const handleResize = () => {
      if (!graph || graph.get('destroyed')) return
      graph.changeSize(containerRef.current.clientWidth, containerRef.current.clientHeight)
    }
    window.addEventListener('resize', handleResize)
    return () => {
      window.removeEventListener('resize', handleResize)
      if (graph && !graph.get('destroyed')) graph.destroy()
    }

  }, [data])

  const save = async () => {
    if (!graphRef.current) return
    const nodes = graphRef.current.getNodes().map(n => ({ id: n.getID(), label: n.getModel().label }))
    const edges = graphRef.current.getEdges().map(e => ({ id: e.getID(), from: e.getModel().source, to: e.getModel().target, label: e.getModel().label }))
    const out = { nodes, edges }
    await fetch('/graph.json', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(out) })
    alert('Saved')
  }

  const addNode = () => {
    if (!graphRef.current) return
    const id = 'n' + Math.floor(Math.random() * 1e9)
    const label = prompt('Node label', 'New node')
    const x = Math.random() * (containerRef.current.clientWidth - 200) + 100
    const y = Math.random() * (containerRef.current.clientHeight - 200) + 100
    graphRef.current.addItem('node', { id, label: label || id, x, y })
  }

  const startAddEdge = () => {
    setEdgeMode(true)
    edgeSrcRef.current = null
    alert('Click source node, then click target node to create edge. ESC to cancel.')
    const onKey = (e) => { if (e.key === 'Escape') { setEdgeMode(false); edgeSrcRef.current = null; window.removeEventListener('keydown', onKey) } }
    window.addEventListener('keydown', onKey)
  }

  const editSelected = () => {
    if (!graphRef.current) return
    const selected = graphRef.current.findAllByState('node', 'selected')
    const selectedEdges = graphRef.current.findAllByState('edge', 'selected')
    if (selected.length + selectedEdges.length === 0) return alert('Select a node or edge first')
    if (selected.length === 1) {
      const node = selected[0]
      const cur = node.getModel()
      const nl = prompt('Edit node label', cur.label || '')
      if (nl !== null) graphRef.current.updateItem(node, { label: nl })
      return
    }
    if (selectedEdges.length === 1) {
      const e = selectedEdges[0]
      const cur = e.getModel()
      const el = prompt('Edit edge label', cur.label || '')
      if (el !== null) graphRef.current.updateItem(e, { label: el })
      return
    }
    alert('Please select a single element to edit')
  }

  const deleteSelected = () => {
    if (!graphRef.current) return
    const selNodes = graphRef.current.findAllByState('node', 'selected')
    const selEdges = graphRef.current.findAllByState('edge', 'selected')
    selNodes.forEach(n => graphRef.current.removeItem(n))
    selEdges.forEach(e => graphRef.current.removeItem(e))
  }

  return (
    <div>
      <div className="toolbar">
        <button onClick={save}>Save</button>
        <button onClick={() => graphRef.current && graphRef.current.fitView()}>Fit</button>
        <button onClick={addNode}>Add Node</button>
        <button onClick={startAddEdge}>Add Edge</button>
        <button onClick={deleteSelected}>Delete Selected</button>
        <button onClick={editSelected}>Edit Selected</button>
        <span style={{ marginLeft: 8 }}>{edgeMode ? 'Edge mode: select src → tgt' : ''}</span>
      </div>
      <div id="container" ref={containerRef} />
    </div>
  )
}
