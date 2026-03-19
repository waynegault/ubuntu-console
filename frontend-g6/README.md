G6 React demo (lightweight scaffold)

Quick start:

1. cd frontend-g6
2. npm install
3. npm run dev

The app will run on Vite (default port 5173). It expects the backend to provide `/graph.json` for GET and POST. The existing `kgraph.py` in this repo already serves `/graph.json` so you can run both during development.

Notes:
- This is a minimal scaffold using G6 directly inside React. It implements:
  - load from `/graph.json` on startup
  - add node, interactive add edge (click source then target)
  - select/drag nodes
  - save back to `/graph.json`

To integrate into a production UI, consider using Graphin (React wrapper) or add more G6 plugins for context menus and HTML labels.
