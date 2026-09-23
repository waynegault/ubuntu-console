"""Tests for kgraph Pydantic models (models.py)."""

import pytest
from pydantic import ValidationError

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(__file__)), "scripts"))

from kgraph.models import (
    MAX_SOURCES_PER_ELEMENT,
    ConfidenceLevel,
    Graph,
    GraphBuilder,
    GraphEdge,
    GraphNode,
    estimate_tokens,
    slugify,
    source_key,
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
        node = GraphNode.model_validate({"id": 42, "label": "Numeric"})
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
        node = GraphNode.model_validate({"id": "n1", "label": "Test", "degree": 5, "importance": 10})
        extra = node.model_extra or {}
        assert extra.get("degree") == 5
        assert extra.get("importance") == 10

    def test_missing_id_raises(self):
        with pytest.raises(ValidationError):
            GraphNode.model_validate({"label": "No ID"})

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

    def test_provenance_source_without_endpoint_rejected(self):
        # source="ast" with no 'from' has no real endpoint; it must not be
        # silently kept as the endpoint (which would point at an "ast" node).
        with pytest.raises(ValidationError):
            GraphEdge.model_validate({"source": "ast", "target": "n2"})

    def test_confidence_defaults_to_extracted(self):
        edge = GraphEdge.model_validate({"source": "a", "target": "b", "confidence": "EXTRACTED"})
        assert edge.confidence == ConfidenceLevel.EXTRACTED

    def test_confidence_none_default(self):
        edge = GraphEdge(source="a", target="b")
        assert edge.confidence is None

    def test_semantic_score_optional(self):
        edge = GraphEdge(source="a", target="b", semantic_score=0.85)
        assert edge.semantic_score == 0.85

    def test_extra_fields_allowed(self):
        edge = GraphEdge.model_validate({"source": "a", "target": "b", "_strength": 0.9})
        assert (edge.model_extra or {}).get("_strength") == 0.9

    def test_missing_source_raises(self):
        with pytest.raises(ValidationError):
            GraphEdge.model_validate({"target": "b"})

    def test_missing_target_raises(self):
        with pytest.raises(ValidationError):
            GraphEdge.model_validate({"source": "a"})


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
        found = g.node_by_id("a")
        assert found is not None
        assert found.label == "A"
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


# ── Source lineage (GRAPHRAG-ARCH-007) ─────────────────────────────────


class TestSourceKey:
    def test_key_shape_is_kind_colon_locator(self):
        assert source_key("file", "scripts/foo.sh") == "file:scripts/foo.sh"
        assert source_key("memory", "abc-123") == "memory:abc-123"
        assert source_key("chunk", "c1") == "chunk:c1"

    def test_locator_is_stripped(self):
        assert source_key("file", "  scripts/foo.sh  ") == "file:scripts/foo.sh"

    def test_unknown_kind_rejected(self):
        with pytest.raises(ValueError):
            source_key("document", "x")

    def test_empty_locator_rejected(self):
        with pytest.raises(ValueError):
            source_key("file", "   ")


class TestSourceLineage:
    def test_sources_default_to_empty(self):
        assert GraphNode(id="n").sources == []
        assert GraphEdge(source="a", target="b").sources == []

    def test_sources_accepts_a_list(self):
        edge = GraphEdge.model_validate({"from": "a", "to": "b", "sources": ["file:x.md"]})
        assert edge.sources == ["file:x.md"]

    def test_non_list_sources_rejected(self):
        with pytest.raises(ValidationError):
            GraphEdge.model_validate({"from": "a", "to": "b", "sources": "file:x.md"})

    def test_merge_sources_unions_sorts_and_dedupes(self):
        node = GraphNode(id="n", sources=["file:b.md"])
        node.merge_sources(["file:a.md", "file:b.md"])
        assert node.sources == ["file:a.md", "file:b.md"]

    def test_merge_sources_bounds_the_array_and_records_the_overflow(self):
        node = GraphNode(id="n")
        node.merge_sources(f"file:f{i:03d}.md" for i in range(MAX_SOURCES_PER_ELEMENT + 6))
        assert len(node.sources) == MAX_SOURCES_PER_ELEMENT
        assert node.sources[0] == "file:f000.md"
        # The kept set is the lexicographically first N, so it is stable as more
        # sources arrive; the true count is recorded so a capped list is not
        # mistaken for the whole set.
        assert node.metadata["sources_overflow"] == MAX_SOURCES_PER_ELEMENT + 6

    def test_drop_source_leaves_an_untracked_element_alone(self):
        node = GraphNode(id="n")
        assert node.drop_source("file:x.md") is False
        assert node.sources == []

    def test_drop_source_true_only_when_the_list_empties(self):
        node = GraphNode(id="n", sources=["file:a.md", "file:b.md"])
        assert node.drop_source("file:a.md") is False
        assert node.sources == ["file:b.md"]
        assert node.drop_source("file:b.md") is True


def _node(graph: Graph, node_id: str) -> GraphNode:
    """The node with *node_id*, asserted present (and non-optional for the checker)."""
    node = graph.node_by_id(node_id)
    assert node is not None, node_id
    return node


class TestGraphBuilderSourceUnion:
    def test_add_edge_unions_sources_of_a_duplicate_edge(self):
        b = GraphBuilder()
        b.add_edge({"from": "a", "to": "b", "label": "links", "sources": ["file:one.md"]})
        b.add_edge({"from": "a", "to": "b", "label": "links", "sources": ["file:two.md"]})
        g = b.build()
        assert len(g.edges) == 1
        assert g.edges[0].sources == ["file:one.md", "file:two.md"]

    def test_add_node_unions_sources_of_a_duplicate_node(self):
        b = GraphBuilder()
        b.add_node({"id": "n", "label": "N", "sources": ["file:one.md"]})
        b.add_node({"id": "n", "label": "N", "sources": ["memory:m1"]})
        g = b.build()
        assert len(g.nodes) == 1
        assert g.nodes[0].sources == ["file:one.md", "memory:m1"]

    def test_merge_unions_rather_than_dropping_the_second_assertion(self):
        b = GraphBuilder()
        b.merge({"nodes": [{"id": "n", "label": "N", "sources": ["file:one.md"]}],
                 "edges": [{"from": "n", "to": "x", "label": "links", "sources": ["file:one.md"]}]})
        b.merge({"nodes": [{"id": "n", "label": "N", "sources": ["file:two.md"]}],
                 "edges": [{"from": "n", "to": "x", "label": "links", "sources": ["file:two.md"]}]})
        g = b.build()
        assert g.nodes[0].sources == ["file:one.md", "file:two.md"]
        assert g.edges[0].sources == ["file:one.md", "file:two.md"]

    def test_semantic_dedup_unions_sources_of_collapsed_edges(self):
        b = GraphBuilder()
        b.add_node({"id": "topic:one", "label": "Graph Layout", "type": "topic",
                    "sources": ["file:one.md"]})
        b.add_node({"id": "topic:two", "label": "Graph Layout", "type": "topic",
                    "inferred_type": True, "sources": ["file:two.md"]})
        b.add_node({"id": "topic:other", "label": "Other", "type": "topic"})
        b.add_edge({"from": "topic:one", "to": "topic:other", "label": "covers topic",
                    "sources": ["file:one.md"]})
        b.add_edge({"from": "topic:two", "to": "topic:other", "label": "covers topic",
                    "sources": ["file:two.md"]})
        b.deduplicate_semantic()
        g = b.build()
        assert [n.id for n in g.nodes] == ["topic:one", "topic:other"]
        assert len(g.edges) == 1
        assert g.edges[0].sources == ["file:one.md", "file:two.md"]
        assert _node(g, "topic:one").sources == ["file:one.md", "file:two.md"]


class TestRemoveSource:
    """The article's document-deletion protocol, end to end on the model."""

    @staticmethod
    def _graph() -> Graph:
        return Graph.from_dict({
            "nodes": [
                {"id": "n1", "label": "N1", "sources": ["file:one.md"]},
                {"id": "n2", "label": "N2", "sources": ["file:one.md", "file:two.md"]},
                {"id": "n3", "label": "N3", "sources": []},
                {"id": "n4", "label": "N4", "sources": ["file:three.md"]},
            ],
            "edges": [
                {"from": "n1", "to": "n2", "label": "links", "sources": ["file:two.md"]},
                {"from": "n2", "to": "n4", "label": "links", "sources": ["file:one.md"]},
                {"from": "n2", "to": "n3", "label": "links",
                 "sources": ["file:one.md", "file:two.md"]},
            ],
        })

    def test_subtracts_exactly_one_source_and_deletes_only_what_empties(self):
        g = self._graph()
        counts = g.remove_source("file:one.md")
        assert {n.id for n in g.nodes} == {"n2", "n3", "n4"}
        assert _node(g, "n2").sources == ["file:two.md"]
        # n1 emptied and was deleted; n3 had no lineage and n4 never carried the
        # key, so both survive untouched.
        assert _node(g, "n3").sources == []
        assert _node(g, "n4").sources == ["file:three.md"]
        # The edge that emptied was deleted; n1's incident edge went with the node;
        # the still-supported edge lost only the one key.
        edge_keys = {(e.source, e.target) for e in g.edges}
        assert edge_keys == {("n2", "n3")}
        assert g.edges[0].sources == ["file:two.md"]
        assert counts == {"nodes_removed": 1, "nodes_updated": 1,
                          "edges_removed": 2, "edges_updated": 1}

    def test_rolling_back_one_of_several_sources_removes_nothing_else(self):
        g = self._graph()
        counts = g.remove_source("file:two.md")
        assert {n.id for n in g.nodes} == {"n1", "n2", "n3", "n4"}
        assert _node(g, "n1").sources == ["file:one.md"]
        assert counts["nodes_removed"] == 0

    def test_unknown_key_is_a_no_op(self):
        g = self._graph()
        before = ([(n.id, n.sources) for n in g.nodes], [(e.source, e.target, e.sources) for e in g.edges])
        counts = g.remove_source("file:never-seen.md")
        after = ([(n.id, n.sources) for n in g.nodes], [(e.source, e.target, e.sources) for e in g.edges])
        assert before == after
        assert counts["nodes_removed"] == 0 and counts["edges_removed"] == 0
