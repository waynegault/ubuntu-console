"""Constants and import-time setup for the kgraph package."""
import json
import logging
import os
import re

logger = logging.getLogger(__name__)


def normalize_canonical_name(text: str) -> str:
    norm = re.sub(r'\s+', ' ', str(text or '').strip().lower())
    norm = re.sub(r'[^a-z0-9\s._:-]', ' ', norm)
    norm = re.sub(r'\s+', ' ', norm).strip(' .:-')
    return norm


MEMORY_DB_CANDIDATES = [
    '~/.openclaw/memory-system/data/memory.db',
    '~/.openclaw/memory/main.sqlite',
    '~/memory/registry.sqlite',
    '~/.openclaw/workspace-rook/memory/registry.sqlite',
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

# ── Concept classification data — ONE loader, ONE home ──────────────────────
# `config/concept-aliases.json` is the single source for every piece of concept
# classification.  This loader used to live in memory_import.py while models.py
# and projection.py each carried their OWN hardcoded subset, and the three had
# drifted: models.py held seven alias keys the JSON did not have at all, and
# projection.py applied a narrower set — so the same label could be classified
# differently depending on which module looked at it.  The seven keys were folded
# into the JSON on 2026-09-16 and every consumer now reads it from here
# (docs/inspection.md 11.14).  It lives in constants.py because that module
# imports nothing local, so no consumer can create an import cycle.
_CONCEPT_CONFIG_PATH = os.path.join(
    os.path.dirname(__file__), "..", "..", "config", "concept-aliases.json"
)


def load_concept_config() -> dict:
    """Load concept aliases and classification data from config/concept-aliases.json."""
    path = os.path.normpath(_CONCEPT_CONFIG_PATH)
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, json.JSONDecodeError) as exc:
        # Without this config all concept filtering (scaffolding labels, aliases,
        # low-value concepts, agent roles) is silently disabled.
        logger.warning("concept config unavailable at %s: %s — filtering disabled", path, exc)
        return {}


_concept_config = load_concept_config()
SCAFFOLDING_LABELS = frozenset(_concept_config.get("scaffolding_labels", []))
CONCEPT_ALIASES: dict[str, str] = _concept_config.get("concept_aliases", {})
LOW_VALUE_CONCEPTS = frozenset(_concept_config.get("low_value_semantic_concepts", []))
WRAPPER_TERMS = frozenset(_concept_config.get("canonical_wrapper_terms", []))
AGENT_ROLES: dict[str, str] = _concept_config.get("agent_roles", {})
STOPWORDS = frozenset(_concept_config.get("stopwords", []))
