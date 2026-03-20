import React, { Suspense, useEffect, useState } from 'react'

const CytoscapeApp = React.lazy(() => import('./CytoscapeApp'))
const G6App = React.lazy(() => import('./G6App'))

export default function App() {
  const [data, setData] = useState({ nodes: [], edges: [] })
  const [useG6, setUseG6] = useState(true)

  useEffect(() => {
    fetch('/graph.json').then(r => r.json()).then(d => setData(d)).catch(() => setData({ nodes: [], edges: [] }))
  }, [])

  // Try G6 first; if module import or init fails, fallback to Cytoscape
  return (
    <Suspense fallback={<div>Loading editor...</div>}>
      {useG6 ? (
        <ErrorBoundary onError={() => setUseG6(false)}>
          <G6App initialData={data} />
        </ErrorBoundary>
      ) : (
        <CytoscapeApp />
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
