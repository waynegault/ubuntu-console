"""Constants and import-time setup for the kgraph package."""
import re

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
