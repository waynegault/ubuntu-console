import React, { Suspense, useEffect, useState } from 'react'

const CytoscapeApp = React.lazy(() => import('./CytoscapeApp'))
const G6App = React.lazy(() => import('./G6App'))
const EMPTY_GRAPH = { nodes: [], edges: [] }

function normalizeGraph(data) {
  return {
    nodes: Array.isArray(data?.nodes) ? data.nodes : [],
    edges: Array.isArray(data?.edges) ? data.edges : [],
  }
}

export default function App() {
  const [data, setData] = useState(EMPTY_GRAPH)
  const [useG6, setUseG6] = useState(true)

  useEffect(() => {
    let isActive = true

    fetch('/graph.json')
      .then((response) => {
        if (!response.ok) {
          throw new Error(`Failed to load graph: ${response.status}`)
        }
        return response.json()
      })
      .then((graph) => {
        if (isActive) {
          setData(normalizeGraph(graph))
        }
      })
      .catch(() => {
        if (isActive) {
          setData(EMPTY_GRAPH)
        }
      })

    return () => {
      isActive = false
    }
  }, [])

  // Try G6 first; if module import or init fails, fallback to Cytoscape
  return (
    <Suspense fallback={<div>Loading editor...</div>}>
      {useG6 ? (
        <ErrorBoundary onError={() => setUseG6(false)}>
          <G6App initialData={data} onInitError={() => setUseG6(false)} />
        </ErrorBoundary>
      ) : (
        <CytoscapeApp initialData={data} />
      )}
    </Suspense>
  )
}

class ErrorBoundary extends React.Component {
  constructor(props) {
    super(props)
    this.state = { hasError: false }
  }
  static getDerivedStateFromError() { return { hasError: true } }
  componentDidCatch(err) {
    console.error('App error:', err)
    this.props.onError && this.props.onError(err)
  }
  render() {
    if (this.state.hasError) return null
    return this.props.children
  }
}
