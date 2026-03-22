import React, { useEffect, useRef } from 'react'

function applyGraphData(graph, data) {
  if (!graph) return

  if (typeof graph.changeData === 'function') {
    graph.changeData(data)
  } else if (typeof graph.data === 'function') {
    graph.data(data)
    if (typeof graph.render === 'function') {
      graph.render()
    }
  } else if (typeof graph.read === 'function') {
    graph.read(data)
  }
}

export default function G6App({ initialData, onInitError }) {
  const containerRef = useRef(null)
  const graphRef = useRef(null)

  useEffect(() => {
    let mounted = true
    let handleResize = null

    ;(async () => {
      try {
        const G6 = await import('@antv/g6')
        if (!mounted || !containerRef.current) return
        const { Graph } = G6
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

        graph.on('node:click', (evt) => { /* noop */ })

        graphRef.current = graph
        applyGraphData(graph, initialData)

        handleResize = () => {
          if (!containerRef.current || !graphRef.current || graphRef.current.get('destroyed')) {
            return
          }
          graphRef.current.changeSize(containerRef.current.clientWidth, containerRef.current.clientHeight)
        }
        window.addEventListener('resize', handleResize)
      } catch (e) {
        console.error('G6 init failed', e)
        if (mounted) {
          onInitError?.(e)
        }
      }
    })()

    return () => {
      mounted = false
      if (handleResize) {
        window.removeEventListener('resize', handleResize)
      }
      try {
        if (graphRef.current && !graphRef.current.get('destroyed')) {
          graphRef.current.destroy()
        }
      } catch (e) {}
      graphRef.current = null
    }
  }, [onInitError])

  useEffect(() => {
    applyGraphData(graphRef.current, initialData)
  }, [initialData])

  return (
    <div style={{ width: '100%', height: '80vh' }} ref={containerRef} />
  )
}
