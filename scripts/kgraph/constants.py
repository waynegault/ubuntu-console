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

# ── Node/edge vocabulary — ONE declaration, ONE home ────────────────────────
# REF: "GraphRAG: A Practitioner's Guide to 6 Advanced Architectural Patterns"
#      (Partha Sarkar, TDS, 2026-09-20) — https://towardsdatascience.com/graphrag-a-practitioners-guide-to-6-advanced-architectural-patterns/
#
# The article's Challenge 2 discipline is "a minimal, rigid ontology ... version
# control and strict governance ... the LLM should be restricted from inventing
# new node labels on the fly".  The console had the algorithm and none of the
# governance: CURATED_EDGE_LABELS, AST_EDGE_LABELS and AST_NODE_TYPES lived in
# projection.py while label literals sat in memory_import.py, confidence.py and
# query.py, and nothing checked membership.  That is the same shape that already
# cost a real drift incident here — the concept-alias sets were duplicated across
# models.py, projection.py and memory_import.py and diverged by seven keys (see
# the loader note above; docs/inspection.md 11.14).
#
# Declared in constants.py for the same reason the alias loader is: this module
# imports nothing local, so no consumer can create an import cycle.  validate.py
# now checks membership against these sets, so a fourth consumer or a new
# extractor path cannot introduce a label that no other module understands and
# have the node silently drop out of derived views.
#
# Bump VOCABULARY_VERSION whenever a member is added or removed, and write it
# into the graph DB at build time, so a graph built under an older label set is
# identifiable rather than merely wrong.
VOCABULARY_VERSION = "1"

CURATED_EDGE_LABELS = frozenset({
    "covers topic", "mentions actor", "authored by", "references file",
    "file mentions actor", "file authored by", "has project", "has decision",
    "has issue", "has outcome",
})

AST_EDGE_LABELS = frozenset({"defines", "calls", "imports", "resolves_to"})
AST_NODE_TYPES = frozenset({"function", "class", "call", "module", "variable"})

# Node types seen in the projected graph: the curated memory-derived set, the
# AST set, and "unknown" — which models.py assigns by default, so it is a
# member rather than a finding (a node with no type is worth seeing, but it is
# expected, and flagging every one would bury the labels that are not).
NODE_TYPES = frozenset({
    "actor", "chunk", "decision", "file", "issue", "memory", "organization",
    "outcome", "person", "place", "project", "topic", "unknown",
}) | AST_NODE_TYPES

# Labels that are families rather than fixed strings, e.g. "summarizes <topic>".
# Kept separate from EDGE_LABELS because a prefix cannot be a set member, but it
# still has to be declared or every summarises-edge reads as unknown.
EDGE_LABEL_PREFIXES = ("summarizes ",)

# Everything an edge label may be: the curated set, the AST set, and the two
# literals projection/confidence match by name.
EDGE_LABELS = frozenset(
    CURATED_EDGE_LABELS | AST_EDGE_LABELS | {"semantic summary", "semantic related"}
)

