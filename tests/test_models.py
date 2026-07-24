"""Tests for kgraph Pydantic models (models.py)."""

import pytest
from pydantic import ValidationError

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(__file__)), "scripts"))

from kgraph.models import (
    ConfidenceLevel,
    Graph,
    GraphBuilder,
    GraphEdge,
    GraphNode,
    estimate_tokens,
    slugify,
)


# ── GraphNode ──────────────────────────────────────────────────────────


class TestGraphNode:
    def test_minimal_node_accepts_id_and_label_only(self):
        node = GraphNode(id="n1", label="Test")
        assert node.id == "n1"
        assert node.label == "Test"
        assert node.type == "unknown"
        assert node.content_preview == ""

    def test_integer_id_coerced_to_str(self):
        node = GraphNode(id=42, label="Numeric")
        assert node.id == "42"
        assert isinstance(node.id, str)

    def test_full_node_accepts_all_optional_fields(self):
        node = GraphNode(
            id="actor:wayne",
            label="Wayne",
            type="actor",
            role="CEO",
            content_preview="Actor: Wayne",
            inferred_type=True,
            type_confidence=0.96,
        )
        assert node.type == "actor"
        assert node.role == "CEO"
        assert node.inferred_type is True
        assert node.type_confidence == 0.96

    def test_extra_fields_allowed(self):
        node = GraphNode(id="n1", label="Test", degree=5, importance=10)
        assert node.degree == 5
        assert node.importance == 10

    def test_missing_id_raises(self):
        with pytest.raises(ValidationError):
            GraphNode(label="No ID")

    def test_missing_label_defaults_empty(self):
        node = GraphNode(id="n1")
        assert node.label == ""

    def test_serialization_round_trip(self):
        node = GraphNode(id="n1", label="Test", type="topic")
        data = node.model_dump()
        restored = GraphNode.model_validate(data)
        assert restored.id == node.id
        assert restored.label == node.label
        assert restored.type == node.type


# ── GraphEdge ──────────────────────────────────────────────────────────


class TestGraphEdge:
    def test_minimal_edge_accepts_from_and_to_only(self):
        edge = GraphEdge(source="n1", target="n2")
        assert edge.source == "n1"
        assert edge.target == "n2"
        assert edge.label == "related"

    def test_from_to_legacy_mapping(self):
        edge = GraphEdge.model_validate({"from": "a", "to": "b", "label": "links"})
        assert edge.source == "a"
        assert edge.target == "b"
        assert edge.label == "links"

    def test_source_target_preferred_over_from_to(self):
        edge = GraphEdge.model_validate({
            "source": "x", "target": "y",
            "from": "a", "to": "b",
        })
        assert edge.source == "x"
        assert edge.target == "y"

    def test_integer_endpoints_coerced(self):
        edge = GraphEdge.model_validate({"from": 1, "to": 2})
        assert edge.source == "1"
        assert edge.target == "2"

    def test_provenance_source_moved_to_origin(self):
        edge = GraphEdge.model_validate({
            "from": "n1", "to": "n2",
            "source": "ast", "label": "calls",
        })
        assert edge.source == "n1"
        assert edge.target == "n2"
        assert edge.origin == "ast"

    def test_confidence_defaults_to_extracted(self):
        edge = GraphEdge(source="a", target="b", confidence="EXTRACTED")
        assert edge.confidence == ConfidenceLevel.EXTRACTED

    def test_confidence_none_default(self):
        edge = GraphEdge(source="a", target="b")
        assert edge.confidence is None

    def test_semantic_score_optional(self):
        edge = GraphEdge(source="a", target="b", semantic_score=0.85)
        assert edge.semantic_score == 0.85

    def test_extra_fields_allowed(self):
        edge = GraphEdge(source="a", target="b", _strength=0.9)
        assert edge._strength == 0.9

    def test_missing_source_raises(self):
        with pytest.raises(ValidationError):
            GraphEdge(target="b")

    def test_missing_target_raises(self):
        with pytest.raises(ValidationError):
            GraphEdge(source="a")


# ── Graph ──────────────────────────────────────────────────────────────


class TestGraph:
    def test_empty_graph_has_no_nodes_or_edges(self):
        g = Graph()
        assert g.nodes == []
        assert g.edges == []

    def test_graph_from_dict_legacy(self):
        data = {
            "nodes": [
                {"id": 1, "label": "Node 1"},
                {"id": "n2", "label": "Node 2", "type": "topic"},
            ],
            "edges": [
                {"from": 1, "to": "n2", "label": "relates to"},
            ],
        }
        g = Graph.from_dict(data)
        assert len(g.nodes) == 2
        assert g.nodes[0].id == "1"
        assert len(g.edges) == 1
        assert g.edges[0].source == "1"
        assert g.edges[0].target == "n2"

    def test_node_by_id_returns_matching_node(self):
        g = Graph(nodes=[
            GraphNode(id="a", label="A"),
            GraphNode(id="b", label="B"),
        ])
        assert g.node_by_id("a").label == "A"
        assert g.node_by_id("z") is None

    def test_node_ids_returns_all_ids(self):
        g = Graph(nodes=[
            GraphNode(id="a", label="A"),
            GraphNode(id="b", label="B"),
        ])
        assert g.node_ids() == {"a", "b"}

    def test_to_dict_round_trip(self):
        g = Graph(
            nodes=[GraphNode(id="n1", label="Test", type="topic")],
            edges=[GraphEdge(source="n1", target="n2", label="links")],
        )
        d = g.to_dict()
        restored = Graph.from_dict(d)
        assert len(restored.nodes) == 1
        assert restored.nodes[0].id == "n1"
        assert len(restored.edges) == 1
        assert restored.edges[0].source == "n1"

    def test_meta_defaults_have_expected_keys(self):
        g = Graph()
        assert g.meta.view_mode == "overview"
        assert g.meta.semantic_threshold == 0.82


# ── GraphBuilder ───────────────────────────────────────────────────────


class TestGraphBuilder:
    def test_add_node_dedup_skips_duplicate_id(self):
        b = GraphBuilder()
        b.add_node({"id": "n1", "label": "First"})
        b.add_node({"id": "n1", "label": "Duplicate"})
        g = b.build()
        assert len(g.nodes) == 1
        assert g.nodes[0].label == "First"

    def test_add_edge_dedup_skips_duplicate_from_to(self):
        b = GraphBuilder()
        b.add_edge({"from": "a", "to": "b", "label": "links"})
        b.add_edge({"from": "a", "to": "b", "label": "links"})
        g = b.build()
        assert len(g.edges) == 1

    def test_add_edge_different_labels_not_deduped(self):
        b = GraphBuilder()
        b.add_edge({"from": "a", "to": "b", "label": "links"})
        b.add_edge({"from": "a", "to": "b", "label": "calls"})
        g = b.build()
        assert len(g.edges) == 2

    def test_merge_graphs_combines_nodes_and_edges(self):
        b = GraphBuilder()
        b.add_node({"id": "n1", "label": "Base"})
        overlay = Graph(
            nodes=[GraphNode(id="n2", label="Overlay")],
            edges=[GraphEdge(source="n1", target="n2", label="connects")],
        )
        b.merge(overlay)
        g = b.build()
        assert len(g.nodes) == 2
        assert len(g.edges) == 1

    def test_merge_dict_updates_graph_from_dict(self):
        b = GraphBuilder()
        b.merge({"nodes": [{"id": "x", "label": "X"}], "edges": []})
        g = b.build()
        assert len(g.nodes) == 1

    def test_has_node_returns_true_for_existing_id(self):
        b = GraphBuilder()
        b.add_node({"id": "n1", "label": "Test"})
        assert b.has_node("n1") is True
        assert b.has_node("n2") is False

    def test_has_edge_returns_true_for_existing_edge(self):
        b = GraphBuilder()
        b.add_edge({"from": "a", "to": "b", "label": "links"})
        assert b.has_edge("a", "b", "links") is True
        assert b.has_edge("a", "b", "calls") is False

    def test_len_returns_node_count(self):
        b = GraphBuilder()
        b.add_node({"id": "n1", "label": "A"})
        b.add_edge({"from": "n1", "to": "n2", "label": "x"})
        assert len(b) == 2

    def test_accepts_pydantic_models(self):
        b = GraphBuilder()
        b.add_node(GraphNode(id="n1", label="A"))
        b.add_edge(GraphEdge(source="n1", target="n2", label="x"))
        g = b.build()
        assert len(g.nodes) == 1
        assert len(g.edges) == 1


# ── Helpers ────────────────────────────────────────────────────────────


class TestHelpers:
    def test_slugify(self):
        assert slugify("Hello World") == "hello-world"
        assert slugify("  Spaces  ") == "spaces"
        assert slugify("special!@#chars") == "special-chars"
        assert slugify("") == ""

    def test_estimate_tokens(self):
        assert estimate_tokens("") == 1
        assert estimate_tokens("abcd") == 1
        assert estimate_tokens("a" * 100) == 25

    def test_confidence_level_values(self):
        assert ConfidenceLevel.EXTRACTED == "EXTRACTED"
        assert ConfidenceLevel.INFERRED == "INFERRED"
        assert ConfidenceLevel.AMBIGUOUS == "AMBIGUOUS"