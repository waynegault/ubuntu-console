import React, { useEffect, useRef } from 'react'

export default function G6App({ initialData }) {
  const containerRef = useRef(null)
  const graphRef = useRef(null)

  useEffect(() => {
    let mounted = true
    ;(async () => {
      try {
        const G6 = await import('@antv/g6')
        if (!mounted) return
        const { Graph, Minimap } = G6
        const width = containerRef.current.clientWidth
        const height = containerRef.current.clientHeight
        const graph = new Graph({
          container: containerRef.current,
          width,
          height,
          renderer: 'canvas',
          modes: { default: ['drag-canvas', 'zoom-canvas', 'drag-node', 'click-select'] },
          plugins: [],
          defaultNode: { type: 'circle', size: 56, style: { fill: '#5B8FF9', lineWidth: 0 }, labelCfg: { style: { fill: '#fff', fontSize: 12 } } },
          defaultEdge: { style: { stroke: '#bfbfbf' }, type: 'line' },
          layout: { type: 'force', preventOverlap: true }
        })

        // set data safely
        if (typeof graph.changeData === 'function') graph.changeData(initialData)
        else if (typeof graph.data === 'function') { graph.data(initialData); if (typeof graph.render === 'function') graph.render() }
        else if (typeof graph.read === 'function') graph.read(initialData)

        graph.on('node:click', (evt) => { /* noop */ })

        graphRef.current = graph
      } catch (e) {
        console.error('G6 init failed', e)
        // throw to allow fallback
        throw e
      }
    })()

    return () => { mounted = false; try { if (graphRef.current && !graphRef.current.get('destroyed')) graphRef.current.destroy() } catch (e) {} }
  }, [initialData])

  return (
    <div style={{ width: '100%', height: '80vh' }} ref={containerRef} />
  )
}
