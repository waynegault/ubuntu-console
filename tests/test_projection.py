"""Tests for kgraph.projection — node/edge helpers and the projection graph modes."""

import unittest
from unittest import mock

from _kgraph_fixtures import _AST_GRAPH, _SMALL_GRAPH
import kgraph

# Fixed life index so these tests never read the host's ~/.openclaw/life.
_PROJECTION_LIFE_INDEX = {
    "aliases": {"graph layout": {"title": "Graph Quality", "type": "project",
                                 "slug": "graph-quality", "path": "life/projects/graph-quality.md"}},
    "title_aliases": {"alpha project": "Alpha Canonical"},
    "by_slug": {}, "by_type": {}, "records": [],
}


def _n(node_id, label, node_type, **extra):
    return {"id": node_id, "label": label, "type": node_type, **extra}


def _e(source, target, label, **extra):
    return {"from": source, "to": target, "label": label, **extra}


def _project(graph, **kwargs):
    """project_graph with the host life-index load replaced by _PROJECTION_LIFE_INDEX."""
    with mock.patch("kgraph.projection.load_life_index", return_value=_PROJECTION_LIFE_INDEX):
        return kgraph.project_graph(graph, **kwargs)


class TestProjectionHelpers(unittest.TestCase):
    def test_threshold_label_and_strength_helpers(self):
        from kgraph import projection
        for given, expected in [(0.0, 0.58), (0.5, 0.58), (0.82, 0.772), (1.0, 0.88), (2.0, 0.90)]:
            self.assertAlmostEqual(projection._effective_semantic_threshold(given), expected, msg=given)
        # The normaliser moved to models.py, where the ONE implementation lives
        # (card 27b55b6f); projection's private copy is gone.
        from kgraph.models import normalize_semantic_label
        for label, want in [("The Current Graph Layout", "graph"), ("Topic cleanup", "topic structure"),
                            ("Alpha Project", "alpha canonical"), ("!!!", ""), ("", "")]:
            self.assertEqual(normalize_semantic_label(label, _PROJECTION_LIFE_INDEX),
                             want, msg=label)
        alias = {"aliases": {"widget": {"title": "Widget Canonical"}}, "title_aliases": {"gadget": "Gadget C"}}
        self.assertEqual(normalize_semantic_label("Widget", alias), "widget canonical")
        self.assertEqual(normalize_semantic_label("Gadget", alias), "gadget c")
        for edge, expected in [(_e("a", "b", "project decision", semantic_score=0.1), 0.95),
                               (_e("a", "b", "project outcome"), 0.88),
                               (_e("a", "b", "actor issue"), 0.76),
                               (_e("a", "b", "related", semantic_score=0.5, cooccurrence_count=3), 0.56),
                               (_e("a", "b", "x", semantic_score="bad", cooccurrence_count="no"), 0.0)]:
            self.assertEqual(projection._edge_strength_value(edge), expected, msg=edge["label"])
        self.assertLessEqual(projection._edge_strength_value(
            _e("a", "b", "project decision", semantic_score=0.99, cooccurrence_count=9)), 0.99)

    def test_visibility_curation_endpoint_helpers(self):
        from kgraph import projection
        self.assertEqual((projection._node_visibility({"view_visibility": "RAW"}),
                          projection._node_visibility({})), ("raw", "both"))
        self.assertEqual((projection._node_quality({"quality": "Supporting"}),
                          projection._node_quality({})), ("supporting", "semantic"))
        self.assertEqual((projection._edge_visibility({"view_visibility": "Raw"}),
                          projection._edge_quality({"quality": "SUPPORTING"})), ("raw", "supporting"))
        self.assertTrue(projection._is_weak_label("  Summary "))
        self.assertFalse(projection._is_weak_label("Real Thing"))
        for node, expected in [(_n("x", "summary", "note"), False),
                               (_n("x", "f", "file", visibility="raw"), False),
                               (_n("x", "t", "topic", quality_tier="supporting"), False),
                               (_n("x", "f", "file", path="life/decision-x.md"), False),
                               (_n("x", "anything", "topic"), True),
                               (_n("x", "f", "file", path="src/a.py"), True),
                               (_n("x", "Real Thing", "note"), True)]:
            self.assertEqual(projection._is_curated_node(node), expected, msg=str(node))
        for edge, expected in [(_e("a", "b", "covers topic"), True),
                               (_e("a", "b", "summarizes project"), True),
                               (_e("a", "b", "related (0.9)", semantic_score=0.9), True),
                               (_e("a", "b", "related (0.5)", semantic_score=0.5), False),
                               (_e("a", "b", "related x", semantic_score="nope"), False),
                               (_e("a", "b", "calls"), False),
                               (_e("a", "b", "covers topic", visibility="raw"), False)]:
            self.assertEqual(projection._is_curated_edge(edge, 0.77), expected, msg=str(edge))
        self.assertEqual(projection._edge_endpoints({"source": "s", "target": "t"}), ("s", "t"))
        self.assertEqual(projection._edge_endpoints(_e("f", "g", "x")), ("f", "g"))
        self.assertEqual(projection._edge_endpoints({}), (None, None))
        out: list = []
        seen: dict = {}
        projection._dedupe_append(out, seen, None, "b", "x")
        projection._dedupe_append(out, seen, "a", None, "x")
        projection._dedupe_append(out, seen, "a", "b", "x")
        projection._dedupe_append(out, seen, "a", "b", "x")
        projection._dedupe_append(out, seen, "a", "b", "y", {"semantic_score": 0.5})
        self.assertEqual(out, [_e("a", "b", "x"), _e("a", "b", "y", semantic_score=0.5)])
        # A dropped duplicate's source documents move to the survivor.
        out2: list = []
        seen2: dict = {}
        projection._dedupe_append(out2, seen2, "a", "b", "x", {"sources": ["file:one.md"]})
        projection._dedupe_append(out2, seen2, "a", "b", "x", {"sources": ["file:two.md"]})
        self.assertEqual(out2, [_e("a", "b", "x", sources=["file:one.md", "file:two.md"])])

    def test_set_display_label_per_mode(self):
        from kgraph import projection
        long_label = "x" * 90
        cases = [
            (_n("f1", "a.md", "file"), "f1", "file", "overview", set(), "", "provenance"),
            (_n("p1", long_label, "project"), "p1", "project", "overview", set(), long_label[:56], None),
            (_n("p1", long_label, "project", importance=9), "p1", "project", "semantic", {"p1"}, long_label[:34], None),
            (_n("p1", long_label, "project", importance=1), "p1", "project", "semantic", set(), "", None),
            (_n("s1", long_label, "summary", importance=9), "s1", "summary", "semantic", {"s1"}, long_label[:40], None),
            (_n("t1", long_label, "topic", importance=9), "t1", "topic", "semantic", {"t1"}, long_label[:22], None),
            (_n("c1", long_label, "chunk", importance=9), "c1", "chunk", "semantic", {"c1"}, long_label[:26], None),
            (_n("t1", long_label, "topic", importance=9), "t1", "topic", "topics", {"t1"}, long_label[:24], None),
            (_n("t2", long_label, "topic", importance=2), "t2", "topic", "topics", {"t1"}, "", None),
        ]
        for node, nid, ntype, mode, top, expected, role in cases:
            projection._set_display_label(node, nid, ntype, mode, top)
            self.assertEqual(node["display_label"], expected, msg=(mode, ntype))
            if role:
                self.assertEqual(node["visual_role"], role)
        for label in ("2024-01-01.md", "memory.md", "profile.md"):
            node = _n("m", label, "topic")
            projection._set_display_label(node, "m", "topic", "semantic", {"m"})
            self.assertEqual((node["display_label"], node["visual_role"]), ("", "provenance"), msg=label)

    def test_collapse_semantic_duplicates_uses_the_shared_boundary_and_bound(self):
        """The view path must apply the SAME rule as the store (card 27b55b6f).

        States the wrong outcomes: a view-only `<4` gate leaves an
        exactly-3-character concept duplicated on screen after the store collapsed
        it, and an unbounded dict union stores 80 keys with no overflow record.
        """
        from kgraph import projection
        from kgraph.models import MAX_SOURCES_PER_ELEMENT

        out = {"nodes": [_n("w1", "wsl", "topic"), _n("w2", "wsl", "topic"),
                         _n("g1", "gw", "topic"), _n("g2", "gw", "topic"),
                         _n("big1", "Big Concept", "topic",
                            sources=[f"file:a{i:03d}.md" for i in range(40)]),
                         _n("big2", "Big Concept", "topic",
                            sources=[f"file:b{i:03d}.md" for i in range(40)])],
               "edges": []}
        projection._collapse_semantic_duplicates(out, {"topic"}, _PROJECTION_LIFE_INDEX)

        self.assertEqual([n["id"] for n in out["nodes"]], ["w1", "g1", "g2", "big1"])
        big = next(n for n in out["nodes"] if n["id"] == "big1")
        self.assertEqual(len(big["sources"]), MAX_SOURCES_PER_ELEMENT)
        self.assertEqual(big["metadata"]["sources_overflow"], 80)

    def test_collapse_semantic_duplicates_merges_and_drops_self_loops(self):
        from kgraph import projection
        out = {"nodes": [_n("a1", "The Graph Layout", "topic"),
                         _n("a2", "Graph Layout", "topic", inferred_type=True),
                         _n("b1", "Other", "topic")],
               "edges": [_e("a1", "a2", "covers topic"), _e("a1", "b1", "covers topic"),
                         _e("a2", "b1", "covers topic")]}
        projection._collapse_semantic_duplicates(out, {"topic"}, _PROJECTION_LIFE_INDEX)
        # The non-inferred duplicate survives as canonical; its self-loop and the
        # parallel a2 -> b1 edge are dropped.
        self.assertEqual([n["id"] for n in out["nodes"]], ["a1", "b1"])
        self.assertEqual(out["edges"], [_e("a1", "b1", "covers topic")])

    def test_build_cluster_suggestions_labels_and_fallbacks(self):
        from kgraph import projection
        def cluster(nodes, edges):
            return projection._build_cluster_suggestions({"nodes": nodes, "edges": edges})
        bases = [_n("a", "Alpha", "project", degree=2, semantic_degree=2),
                 _n("b", "Beta", "decision", degree=2, semantic_degree=2),
                 _n("c", "Gamma", "issue", degree=2, semantic_degree=2)]
        strong = [_e("a", "b", "project decision", semantic_score=0.9),
                  _e("b", "c", "decision addresses issue", semantic_score=0.9),
                  _e("a", "c", "project issue", semantic_score=0.9)]
        self.assertEqual([(s["label"], s["size"]) for s in cluster(bases, strong)], [("Alpha · Gamma", 3)])
        # Unknown endpoints are ignored; a two-node component is not a cluster.
        self.assertEqual(len(cluster(bases, strong + [_e("a", "ghost", "project decision")])), 1)
        self.assertEqual(cluster(bases[:2], strong), [])
        # Weak labels and bad numeric fields fall through to a generic name.
        weak = [_n("w1", "Repo cleanup", "topic", degree=2), _n("w2", "Env bridge", "topic", degree=2),
                _n("w3", "Copilot token", "topic", degree=2)]
        weak_edges = [_e("w1", "w2", "related (0.9)", semantic_score=0.9),
                      _e("w2", "w3", "related (0.9)", semantic_score=0.9),
                      _e("w1", "w3", "related (0.9)", semantic_score=0.9)]
        self.assertEqual([s["label"] for s in cluster(weak, weak_edges)], ["cluster 1"])
        chunk_edges = [_e("c1", "c2", "related (0.9)", semantic_score=0.9),
                       _e("c2", "c3", "related (0.9)", semantic_score=0.9),
                       _e("c1", "c3", "related (0.9)", semantic_score=0.9)]
        chunks = [_n("c1", "Chunk one", "chunk", degree=2), _n("c2", "Chunk two", "chunk", degree=2),
                  _n("c3", "Chunk three", "chunk", degree=2)]
        self.assertEqual([s["label"] for s in cluster(chunks, chunk_edges)], ["Chunk three · Chunk one"])
        single = [_n("a", "Alpha", "project", degree=2), _n("b", "Graph quality", "topic", degree=2),
                  _n("c", "Env bridge", "decision", degree=2)]
        bad_numeric = [_e("a", "b", "project decision", semantic_score="bad", cooccurrence_count="bad"),
                       _e("b", "c", "decision addresses issue", cooccurrence_count=3),
                       _e("a", "c", "project issue", cooccurrence_count=2)]
        self.assertEqual([s["label"] for s in cluster(single, bad_numeric)], ["Alpha (cluster)"])
        repeated = [_n("a", "Same", "project", degree=2), _n("b", "Same", "decision", degree=2),
                    _n("c", "Graph quality", "issue", degree=2)]
        self.assertEqual([s["label"] for s in cluster(repeated, strong)], ["Same (issue)"])
        # Cooccurrence-only relations stay below the 0.74 cluster bar.
        self.assertEqual(cluster(single, [_e("a", "b", "related", cooccurrence_count=3),
                                          _e("b", "c", "related", cooccurrence_count=2)]), [])

    def test_filter_semantic_edges_selection_rules(self):
        from kgraph import projection
        gateway = {"nodes": [_n("s1", "Gateway", "topic"), _n("p1", "Proj", "project")],
                   "edges": [_e("s1", "p1", "semantic related", semantic_score=0.9)]}
        projection._filter_semantic_edges(gateway, "topics", _PROJECTION_LIFE_INDEX)
        # The topic->gateway cap drops the edge; topics mode keeps both nodes.
        self.assertEqual(gateway["edges"], [])
        self.assertEqual({n["id"] for n in gateway["nodes"]}, {"s1", "p1"})
        unknown = {"nodes": [_n("t1", "Topic one", "topic")], "edges": [_e("ghost", "t1", "covers topic")]}
        projection._filter_semantic_edges(unknown, "semantic", _PROJECTION_LIFE_INDEX)
        self.assertEqual(unknown["edges"], [])
        reverse = {"nodes": [_n("p1", "Proj", "project"), _n("d1", "Dec", "decision")],
                   "edges": [_e("p1", "d1", "project decision", semantic_score=0.9),
                             _e("d1", "p1", "project decision", semantic_score=0.9)]}
        projection._filter_semantic_edges(reverse, "topics", _PROJECTION_LIFE_INDEX)
        self.assertEqual(len(reverse["edges"]), 1)  # reverse pairs dedupe
        hub = [_n("h", "Hub project", "project")] + [_n(f"l{i}", f"Leaf {i}", "topic") for i in range(12)]
        budget = {"nodes": list(hub),
                  "edges": [_e("h", f"l{i}", "related", semantic_score=0.8) for i in range(12)]}
        projection._filter_semantic_edges(budget, "semantic", _PROJECTION_LIFE_INDEX)
        # Degree >= 10 gives budget 4 and strength 0.86, under the 0.88 override.
        self.assertEqual(len(budget["edges"]), 4)
        medium = {"nodes": hub[:9],
                  "edges": [_e("h", f"l{i}", "related", semantic_score=0.8) for i in range(8)]}
        projection._filter_semantic_edges(medium, "topics", _PROJECTION_LIFE_INDEX)
        self.assertEqual(len(medium["edges"]), 6)  # medium-degree budget
        sparse = {"nodes": [_n(f"t{i:02d}", f"Topic {i:02d}", "topic") for i in range(20)],
                  "edges": [_e(f"t{i:02d}", f"t{i + 1:02d}", "related (0.5)", semantic_score=0.5)
                            for i in range(0, 20, 2)] +
                           [_e("t00", "t01", "related (0.55)", semantic_score=0.55)]}
        projection._filter_semantic_edges(sparse, "semantic", _PROJECTION_LIFE_INDEX)
        # All edges are sub-threshold, so the sparse fallback rescues them: the
        # duplicate pair is skipped and the result stops at the ten-edge cap.
        pairs = [(e["from"], e["to"]) for e in sparse["edges"]]
        self.assertEqual((len(pairs), len(set(pairs))), (10, 10))
        unanchored = {"nodes": [_n("p1", "Alpha project", "project"), _n("t1", "Topic one", "topic"),
                                _n("t2", "Topic two", "topic")],
                      "edges": [_e("t1", "t2", "semantic related", semantic_score=0.9),
                                _e("t1", "p1", "project topic", semantic_score=0.9)]}
        projection._filter_semantic_edges(unanchored, "topics", _PROJECTION_LIFE_INDEX)
        self.assertEqual({(e["from"], e["to"]) for e in unanchored["edges"]}, {("t1", "p1")})


class TestProjectGraphModes(unittest.TestCase):
    def test_raw_and_empty_modes(self):
        graph = {"nodes": [_n("a", "A", "topic")], "edges": []}
        self.assertIs(kgraph.project_graph(graph, mode="raw"), graph)
        for mode in ("overview", "files", "topics", "semantic"):
            out = _project({"nodes": [], "edges": []}, mode=mode)
            self.assertEqual((out["nodes"], out["edges"], out["_meta"]["nodeCount"]), ([], [], 0), mode)

    def test_overview_filters_nodes_and_lifts_chunk_edges(self):
        out = _project({"nodes": [_n("n1", "Custom", "custom", visibility="raw"),
                                  _n("n2", "Custom2", "custom"), _n("n3", "summary", "note"),
                                  _n("n4", "T", "topic", visibility="raw"), _n("f1", "A.md", "file"),
                                  _n("c1", "chunk", "chunk"), _n("p1", "P", "project")],
                        "edges": [_e("f1", "c1", "contains chunk"), _e("c1", "p1", "has project"),
                                  _e("f1", "n4", "covers topic"), _e("n2", "p1", "links")]},
                       mode="overview")
        # Weak/raw nodes go, chunks go, the chunk edge lifts to the file, and
        # file->topic curated plus uncurated edges are dropped.
        self.assertEqual({n["id"] for n in out["nodes"]}, {"n2", "n4", "f1", "p1"})
        self.assertEqual([(e["from"], e["to"], e["label"]) for e in out["edges"]], [("f1", "p1", "has project")])
        self.assertEqual(out["_meta"]["edgeCount"], 1)

    def test_overview_keeps_ast_structure_and_reports_meta(self):
        out = _project(_AST_GRAPH, mode="overview")
        self.assertEqual({n["id"] for n in out["nodes"]}, {
            "ast_file:main_py", "ast_func:hello", "ast_class:greeter",
            "ast_module:os", "ast_call:print"})
        self.assertEqual(len(out["edges"]), 5)
        file_node = next(n for n in out["nodes"] if n["id"] == "ast_file:main_py")
        self.assertEqual((file_node["display_label"], file_node["visual_role"]), ("", "provenance"))
        self.assertEqual((out["_meta"]["nodeCount"], out["_meta"]["edgeCount"]), (5, 5))
        self.assertEqual((out["_meta"]["typeCounts"]["function"], out["_meta"]["typeCounts"]["file"]), (1, 1))

    def test_overview_edge_selection_and_lifting(self):
        scored = _project({"nodes": [_n("t1", "Topic one", "topic"), _n("t2", "Topic two", "topic")],
                           "edges": [_e("t1", "t2", "related (0.9)", semantic_score=0.9)]}, mode="overview")
        self.assertEqual([(e["from"], e["to"], e["label"], e["semantic_score"]) for e in scored["edges"]],
                         [("t1", "t2", "related (0.9)", 0.9)])
        # Without a "contains chunk" parent edge the chunk edge cannot be lifted,
        # and endpoint-less/unknown/non-curated edges are all skipped.
        dangling = _project({"nodes": [_n("c1", "chunk", "chunk"), _n("t1", "Topic one", "topic")],
                             "edges": [{"label": "covers topic"}, _e("c1", "t1", "covers topic"),
                                       _e("ghost", "t1", "covers topic")]}, mode="overview")
        self.assertEqual(dangling["edges"], [])
        self.assertEqual({n["id"] for n in dangling["nodes"]}, {"t1"})
        non_curated = _project({"nodes": [_n("t1", "Topic one", "topic"), _n("t2", "Topic two", "topic")],
                                "edges": [_e("t1", "t2", "links")]}, mode="overview")
        self.assertEqual(non_curated["edges"], [])
        lifted = _project({"nodes": [_n("f1", "a.md", "file"), _n("c1", "chunk", "chunk"),
                                     _n("a1", "Actor", "actor")],
                           "edges": [_e("f1", "c1", "contains chunk"), _e("c1", "a1", "mentions actor")]},
                          mode="overview")
        self.assertEqual([(e["from"], e["to"], e["label"]) for e in lifted["edges"]],
                         [("f1", "a1", "file mentions actor")])

    def test_files_and_topics_modes_filter_by_type(self):
        ast = dict(_AST_GRAPH)
        files = _project({"nodes": ast["nodes"] + [_n("topic:x", "T", "topic")],
                          "edges": ast["edges"] + [_e("ast_file:main_py", "topic:x", "covers topic")]},
                         mode="files")
        self.assertEqual({n["id"] for n in files["nodes"]}, {
            "ast_file:main_py", "ast_func:hello", "ast_class:greeter",
            "ast_module:os", "ast_call:print"})
        self.assertEqual(len(files["edges"]), 5)
        pair = _project({"nodes": [_n("f1", "a.py", "file"), _n("f2", "b.sh", "file")],
                         "edges": [_e("f1", "f2", "references")]}, mode="files")
        self.assertEqual([(e["from"], e["to"], e["label"]) for e in pair["edges"]],
                         [("f1", "f2", "references")])
        topics = _project({"nodes": [_n("t1", "Topic one", "topic"), _n("p1", "Proj", "project"),
                                     _n("f1", "f.py", "file"), _n("a1", "Actor", "actor")],
                           "edges": [_e("p1", "t1", "project topic", semantic_score=0.9),
                                     _e("t1", "a1", "covers topic"), _e("f1", "t1", "covers topic")]},
                          mode="topics")
        self.assertEqual({n["id"] for n in topics["nodes"]}, {"t1", "p1", "a1"})
        self.assertEqual([(e["from"], e["to"], e["label"]) for e in topics["edges"]],
                         [("p1", "t1", "project topic"), ("t1", "a1", "covers topic")])

    def test_project_graph_accepts_graph_model(self):
        from kgraph.models import Graph
        out = _project(Graph.from_dict(_AST_GRAPH), mode="overview")
        self.assertEqual((out["_meta"]["nodeCount"], out["_meta"]["edgeCount"]), (5, 5))

    def test_semantic_mode_curated_edges_and_canonical_bias(self):
        out = _project({"nodes": [_n("t1", "Graph Layout", "topic"), _n("p1", "Proj", "project")],
                        "edges": [_e("p1", "t1", "project topic", semantic_score=0.9)]}, mode="semantic")
        topic = next(n for n in out["nodes"] if n["id"] == "t1")
        # The life-index alias rewrites label/type and flags the inference.
        self.assertEqual((topic["label"], topic["type"], topic["inferred_type"]), ("Graph Quality", "project", True))
        self.assertEqual((topic["canonical_slug"], topic["canonical_path"]),
                         ("graph-quality", "life/projects/graph-quality.md"))
        self.assertEqual([(e["from"], e["to"], e["label"]) for e in out["edges"]],
                         [("p1", "t1", "project topic")])
        empty = _project({"nodes": [_n("p1", "", "project"), _n("p2", "Beta project", "project")],
                          "edges": [_e("p1", "p2", "project decision", semantic_score=0.9)]}, mode="semantic")
        self.assertEqual(({n["id"] for n in empty["nodes"]}, len(empty["edges"])), ({"p1", "p2"}, 1))

    def test_semantic_mode_infers_cooccurrence_edges(self):
        out = _project({"nodes": [_n("s1", "Weekly", "summary"), _n("p1", "Alpha project", "project"),
                                  _n("d1", "Beta decision", "decision"), _n("i1", "Gamma issue", "issue")],
                        "edges": [_e("s1", "p1", "summarizes project"),
                                  _e("s1", "d1", "summarizes decision"),
                                  _e("s1", "i1", "summarizes issue")]}, mode="semantic")
        # The summary is support, never emitted; its concepts form inferred edges.
        self.assertEqual({n["id"] for n in out["nodes"]}, {"p1", "d1", "i1"})
        for edge in out["edges"]:
            self.assertEqual((edge["label"], edge["inferred"], edge["cooccurrence_count"],
                              edge["support_summary_count"]), ("semantic related", True, 1, 1))

    def test_semantic_mode_summary_and_chunk_support(self):
        out = _project({"nodes": [_n("p1", "Alpha project", "project"), _n("p2", "Beta project", "project"),
                                  _n("p3", "Gamma project", "project"), _n("p4", "Delta project", "project"),
                                  _n("s1", "Weekly notes", "summary"), _n("c1", "summary", "chunk")],
                        "edges": [_e("s1", "p1", "summarizes project"), _e("s1", "p2", "summarizes project"),
                                  _e("c1", "p3", "covers topic"), _e("p4", "c1", "covers topic"),
                                  _e("p1", "p2", "project decision", semantic_score=0.9)]}, mode="semantic")
        self.assertEqual({n["id"] for n in out["nodes"]}, {"p1", "p2", "p3", "p4"})
        edge = next(e for e in out["edges"] if {e["from"], e["to"]} == {"p3", "p4"})
        # p3/p4 co-occur only through the chunk, traversed in both directions.
        self.assertEqual((edge["label"], edge["support_summary_count"], edge["support_chunk_count"]),
                         ("semantic related", 0, 1))
        # A concept can also be reached through the summary in either direction.
        linked = _project({"nodes": [_n("p1", "Alpha project", "project"), _n("p2", "Beta project", "project"),
                                     _n("s1", "Weekly notes", "summary")],
                           "edges": [_e("p1", "s1", "summarizes project"), _e("s1", "p2", "summarizes project"),
                                     _e("p1", "p2", "project decision", semantic_score=0.9)]}, mode="semantic")
        self.assertEqual(({n["id"] for n in linked["nodes"]}, len(linked["edges"])), ({"p1", "p2"}, 1))

    def test_semantic_mode_topic_penalty_and_unknown_endpoints(self):
        nodes = [_n("t1", "Topic one", "topic"), _n("t2", "Topic two", "topic"), _n("t3", "Topic three", "topic"),
                 _n("p1", "Alpha project", "project")] + \
                [_n(f"s{i}", f"Notes {i}", "summary") for i in range(3)]
        edges = []
        for summary in ("s0", "s1", "s2"):
            edges += [_e(summary, "t1", "summarizes topic"),
                      _e(summary, "t2", "summarizes topic"),
                      _e(summary, "p1", "summarizes project")]
        edges.append(_e("s0", "t3", "summarizes topic"))
        out = _project({"nodes": nodes, "edges": edges}, mode="semantic")
        related = {(e["from"], e["to"]): e for e in out["edges"] if e["label"] == "semantic related"}
        self.assertIn(("t1", "t2"), related)
        # Two topics cost an extra penalty, so they score below the anchor pair.
        self.assertLess(related[("t1", "t2")]["semantic_score"],
                        related[("p1", "t1")]["semantic_score"])
        bad = _project({"nodes": [_n("p1", "Alpha project", "project"), _n("d1", "Beta decision", "decision")],
                        "edges": [_e("ghost", "d1", "project decision", semantic_score=0.9),
                                  _e("p1", "d1", "project decision", semantic_score="bad")]}, mode="semantic")
        self.assertEqual([(e["from"], e["to"], e["label"]) for e in bad["edges"]],
                         [("p1", "d1", "project decision")])

    def test_semantic_mode_filters_unconnected_and_weak_nodes(self):
        out = _project({"nodes": [_n("p1", "Alpha project", "project"), _n("t1", "Topic one", "topic"),
                                  _n("p2", "Graph quality", "topic"), _n("p3", "Beta project", "project"),
                                  _n("z1", "Lonely thing", "topic"), _n("a1", "Alice Actor", "actor")],
                        "edges": [_e("p1", "t1", "project topic", semantic_score=0.9),
                                  _e("p1", "a1", "project owner", semantic_score=0.9)]}, mode="semantic")
        # p2 (weak label) and z1 (unconnected topic) go; anchors and actors stay.
        self.assertEqual({n["id"] for n in out["nodes"]}, {"p1", "t1", "p3", "a1"})

    def test_semantic_mode_fallback_and_threshold(self):
        two = {"nodes": [_n("p1", "Alpha project", "project"), _n("p2", "Beta project", "project")], "edges": []}
        low = _project(two, mode="semantic", semantic_threshold=0.4)
        self.assertEqual([(e["from"], e["to"], e["label"], e["semantic_score"], e["fallback"])
                          for e in low["edges"]], [("p1", "p2", "semantic related", 0.42, True)])
        high = _project(two, mode="semantic", semantic_threshold=0.95)
        self.assertEqual((high["edges"], {n["id"] for n in high["nodes"]}), ([], {"p1", "p2"}))
        many = _project({"nodes": [_n(f"p{i:02d}", f"Project {i:02d}", "project") for i in range(10)],
                         "edges": []}, mode="semantic", semantic_threshold=0.4)
        self.assertLessEqual(len(many["edges"]), 10)  # strong-node fallback caps pairs
        self.assertGreater(len(many["edges"]), 0)

    def test_semantic_mode_applies_inferred_neighbor_budget(self):
        nodes = [_n("p1", "Alpha project", "project")] + \
                [_n(f"d{i}", f"Decision {i}", "decision") for i in range(6)] + \
                [_n(f"s{i}", f"Notes {i}", "summary") for i in range(6)]
        edges = []
        for i in range(6):
            edges += [_e(f"s{i}", "p1", "summarizes project"), _e(f"s{i}", f"d{i}", "summarizes decision")]
        out = _project({"nodes": nodes, "edges": edges}, mode="semantic")
        # Every decision co-occurs only with p1; its inferred-neighbour budget
        # caps how many of these weak 0.5 pairs survive.
        self.assertEqual(len(out["edges"]), 3)
        self.assertTrue(all("p1" in (e["from"], e["to"]) and e["semantic_score"] == 0.5
                            for e in out["edges"]))

    def test_semantic_mode_small_graph(self):
        out = _project(_SMALL_GRAPH, mode="semantic")
        self.assertEqual({n["id"] for n in out["nodes"]}, {"a", "b", "c"})
        self.assertEqual({(e["from"], e["to"]) for e in out["edges"]}, {("a", "b"), ("b", "c")})
        self.assertTrue(all(n["importance"] >= 1 for n in out["nodes"]))
        suggestions = out["_meta"]["clusterSuggestions"]
        self.assertEqual([(s["id"], s["size"], set(s["members"])) for s in suggestions],
                         [("semantic_cluster_1", 3, {"a", "b", "c"})])


if __name__ == "__main__":
    unittest.main()
