"""Tests for kgraph.memory_import — connection lifecycle, store and registry imports."""

import os
import tempfile
import unittest
from unittest import mock

from _paths import SCRIPT_DIR

# `_paths` puts the repo's scripts/ on sys.path; assert the bootstrap ran
# rather than letting a later `import kgraph` fail with a confusing ImportError.
if not os.path.isdir(SCRIPT_DIR):
    raise RuntimeError(f"kgraph scripts/ dir not found: {SCRIPT_DIR}")


class TestMemoryImportConnection(unittest.TestCase):
    def test_connection_closed_when_import_raises(self):
        from kgraph import memory_import

        fake_conn = mock.MagicMock()
        fake_sqlite = mock.MagicMock()
        fake_sqlite.connect.return_value = fake_conn
        with (
            mock.patch.object(memory_import, "sqlite3", fake_sqlite),
            mock.patch.object(
                memory_import, "_load_from_memory_db_conn",
                side_effect=RuntimeError("boom"),
            ),
        ):
            with self.assertRaises(RuntimeError):
                memory_import.load_from_memory_db("/tmp/whatever.db")
        fake_conn.close.assert_called_once()


# Synthetic life index pinned into the module so the import never reads the
# host's ~/.openclaw/life tree.  "openclaw" proves canonical-type mapping,
# "gateway token rotation" proves alias → canonical record resolution, and the
# last two entries prove non-entity types and sub-3-char aliases never become
# canonical entity patterns.
_LIFE_INDEX = {
    "by_slug": {}, "by_type": {}, "records": [], "title_aliases": {},
    "aliases": {
        "openclaw": {"slug": "openclaw", "title": "OpenClaw", "type": "organization",
                     "path": "/life/organizations/openclaw.md", "aliases": [], "status": "active"},
        "gateway token rotation": {"slug": "gateway-token-rotation",
                                   "title": "Gateway Token Rotation", "type": "system",
                                   "path": "/life/systems/gateway-token-rotation.md",
                                   "aliases": [], "status": "active"},
        "notes": {"slug": "notes", "title": "Notes", "type": "note",
                  "path": "/life/notes/notes.md", "aliases": [], "status": "active"},
        "gw": {"slug": "gw", "title": "Gateway Watch", "type": "system",
               "path": "/life/systems/gateway-watch.md", "aliases": [], "status": "active"},
    },
}


_STORE_NOTES = """# Operations Notes
## Project: Launcher reliability
Project: Launcher reliability
Decision: token rotation
Decision: issue: gateway flapping | resolve by rotation
Jarvis (Operations Director) reviewed the launcher.
Finance Director (Marlowe) approved the budget.
We decided to keep the semantic naming.
Issue: duplicated nodes in graph
Outcome: launcher reliability validated
Work on gateway token rotation
The main issue is shallow topic labels
Result was launcher reliability validated
See `memory/notes.md` for details and also unknown/thing.md.
gateway openclaw wsl2 ubuntu linux
OpenClaw runs the registry here.
"""


_STORE_REPORT = """# Hal-Activate Report
## A
## Notes
## Status
We decided to rotate the gateway token
"""


_STORE_LINKS = "Links back to `memory/notes.md` for context.\nVigil (Sentinel) monitors the desk.\n"


_STORE_TERMS = """Decision: status
Project: profile.md
Decision: 2026-01-02
Issue: gateway
Outcome: results
Decision: raw!
Decision: 1 2 3 4
Decision: alpha bravo charlie delta echo
grep -n foo bar
gw

This line is deliberately made far longer than one hundred and twenty characters so that the concept_worthy_line length guard rejects it outright.
Sarah (Marketing) owns the launch.
See other.md and notes.md for context.
"""


_STORE_ACTIVATION = "# Lyra-Activate Report\nNothing much to report today.\n"


_STORE_FILES = ["memory/notes.md", "/abs/docs/other.md", "/docs/notes.md", None, ""]


# (id, path, start_line, end_line, text, embedding)
_STORE_CHUNKS = [
    ("c1", "memory/notes.md", 1, 5, _STORE_NOTES, "[1.0, 0.0, 0.0]"),
    ("c2", "memory/notes.md", 7, None, _STORE_REPORT, "[1.0, 0.0, 0.0]"),
    ("c3", "/abs/docs/other.md", None, None, _STORE_LINKS, "[1.0, 0.0, 0.0]"),
    ("c4", None, None, None, None, None),
    ("c5", "/abs/docs/third.md", 3, None, _STORE_TERMS, "not-json"),
    ("c6", "/abs/docs/fourth.md", None, None, "nothing to see", "[1.0, 0.0]"),
    ("c7", "/abs/docs/fifth.md", None, None, "zero vector", "[0.0, 0.0]"),
    ("c8", "/abs/docs/sixth.md", None, None, "bad element", '[1.0, "x"]'),
    ("c9", "/abs/docs/seventh.md", None, None, _STORE_ACTIVATION, '{"a": 1}'),
    ("c10", "/abs/docs/eighth.md", None, None, "empty vector", "[]"),
]


def _create_store_db(path):
    """Create a synthetic files/chunks memory-store DB with the live schema."""
    import sqlite3

    conn = sqlite3.connect(path)
    try:
        cur = conn.cursor()
        cur.execute("CREATE TABLE files (path TEXT)")
        cur.execute("CREATE TABLE chunks (id TEXT, path TEXT, start_line INT,"
                    " end_line INT, text TEXT, embedding TEXT)")
        cur.executemany("INSERT INTO files VALUES (?)", [(p,) for p in _STORE_FILES])
        cur.executemany("INSERT INTO chunks VALUES (?,?,?,?,?,?)", _STORE_CHUNKS)
        conn.commit()
    finally:
        conn.close()


def _node_ids(graph):
    return {n.id for n in graph.nodes}


def _edge_keys(graph):
    return {(e.source, e.target, e.label) for e in graph.edges}


def _node(graph, node_id):
    return next(n for n in graph.nodes if n.id == node_id)


class TestMemoryImportStore(unittest.TestCase):
    """files/chunks memory-store import against a real synthetic SQLite DB."""

    def _graph(self, include_all=False):
        """Import the standard synthetic store DB, cleaning up the temp DB."""
        from kgraph import memory_import

        with tempfile.TemporaryDirectory() as td:
            db = os.path.join(td, "store.db")
            _create_store_db(db)
            with mock.patch("kgraph.memory_import.load_life_index", return_value=_LIFE_INDEX):
                return memory_import.load_from_memory_db(db, include_all=include_all)

    def test_records_and_their_edges_carry_the_asserting_document(self):
        """GRAPHRAG-ARCH-007: the files/chunks ingest path populates sources."""
        graph = self._graph()
        nodes = {n.id: n for n in graph.nodes}
        # A file node and a chunk node each name themselves as their source.
        self.assertEqual(nodes["file:memory/notes.md"].sources, ["file:memory/notes.md"])
        self.assertEqual(nodes["chunk:c1"].sources, ["chunk:c1"])

        edges = {(e.source, e.target, e.label): e for e in graph.edges}
        # A file-level roll-up carries both the file and the chunk that asserted it.
        self.assertEqual(sorted(edges[("file:memory/notes.md", "chunk:c1",
                                       "contains chunk")].sources),
                         ["chunk:c1", "file:memory/notes.md"])
        # A chunk-anchored edge is asserted by that chunk (and, for the chunk-to-
        # chunk similarity edges, by the other chunk it joins as well).
        chunk_edges = [e for (src, _dst, _lbl), e in edges.items() if src == "chunk:c1"]
        self.assertTrue(chunk_edges)
        for edge in chunk_edges:
            self.assertIn("chunk:c1", edge.sources, edge.label)
        similarity = edges[("chunk:c1", "chunk:c3", "related (1.00)")]
        self.assertEqual(similarity.sources, ["chunk:c1", "chunk:c3"])
        # Every edge from this branch has lineage; none was missed at an emission site.
        self.assertTrue(all(e.sources for e in graph.edges))

    def test_derived_concept_nodes_carry_no_lineage_of_their_own(self):
        """A topic/actor node is an aggregate; its evidence is the edges into it."""
        graph = self._graph()
        derived = [n for n in graph.nodes if n.type in ("topic", "actor")]
        self.assertTrue(derived)
        for node in derived:
            self.assertEqual(node.sources, [], node.id)

    def test_files_chunks_nodes_containment_and_references(self):
        graph = self._graph()
        ids = _node_ids(graph)
        edges = _edge_keys(graph)

        self.assertIn("file:memory/notes.md", ids)
        self.assertIn("file:/abs/docs/other.md", ids)
        self.assertNotIn("file:", ids)  # NULL/blank paths are skipped, not nodes
        # Label carries file + line range + whitespace-collapsed preview.
        c1 = _node(graph, "chunk:c1")
        self.assertTrue(c1.label.startswith("notes.md L1-5: # Operations Notes"))
        self.assertTrue(c1.label.endswith("…"), c1.label)
        # Only start_line is an int → single-ended range.
        self.assertTrue(_node(graph, "chunk:c2").label.startswith("notes.md L7:"))
        # No path and no text → bare "chunk" label, still a node.
        self.assertEqual(_node(graph, "chunk:c4").label, "chunk")
        self.assertIn(("file:memory/notes.md", "chunk:c1", "contains chunk"), edges)
        # A chunk path absent from `files` still gets a containing file node.
        self.assertIn("file:/abs/docs/third.md", ids)
        self.assertIn(("file:/abs/docs/third.md", "chunk:c5", "contains chunk"), edges)
        # File references: explicit path, unique basename, ambiguous, self, unknown.
        self.assertIn(("chunk:c3", "file:memory/notes.md", "references file"), edges)
        self.assertIn(("file:/abs/docs/other.md", "file:memory/notes.md", "references file"), edges)
        self.assertIn(("chunk:c5", "file:/abs/docs/other.md", "references file"), edges)
        self.assertNotIn(("chunk:c5", "file:memory/notes.md", "references file"), edges)
        self.assertNotIn(("chunk:c1", "file:memory/notes.md", "references file"), edges)
        self.assertNotIn("file:unknown/thing.md", ids)

    def test_every_emitted_node_type_is_classified_for_label_redaction(self):
        # audit_security.md residual: the GET read path redacts a node's LABEL
        # only when its type is in server._REDACTED_LABEL_TYPES, because for
        # those types label IS a preview of the node's own content
        # (memory_import sets label = _preview_text(content)).  A future
        # importer type that is content-derived but not listed there would leak
        # it.  This drives the real importer and requires every type it emits to
        # be classified — content-derived (redacted) or explicitly not — so a
        # new type fails here until someone decides.
        from kgraph import server as kgraph_server

        redacted = set(kgraph_server._REDACTED_LABEL_TYPES)
        # Types whose label cannot reconstruct their content (file paths, ids,
        # slugs, display names, short editorial titles).
        label_is_not_content = {
            "actor", "chunk", "decision", "file", "issue", "organization",
            "outcome", "person", "project", "system", "topic",
        }

        # The known content-derived types must stay redacted, and the two
        # classifications must not overlap.
        self.assertIn("memory", redacted)
        self.assertIn("summary", redacted)
        self.assertEqual(redacted & label_is_not_content, set())

        emitted = {
            str(getattr(n, "type", "") or "").lower()
            for n in self._graph(include_all=True).nodes
        }
        unclassified = sorted(emitted - redacted - label_is_not_content)
        self.assertEqual(
            unclassified, [],
            "importer node type(s) not classified for label redaction: "
            f"{unclassified} — add to server._REDACTED_LABEL_TYPES if the label "
            "is content-derived, otherwise to label_is_not_content here",
        )

    def test_actor_mentions_and_activation_authorship(self):
        graph = self._graph()
        edges = _edge_keys(graph)

        self.assertEqual(_node(graph, "actor:jarvis").role, "Operations Director")
        # Reverse pattern "Finance Director (Marlowe)" also yields an actor.
        self.assertEqual(_node(graph, "actor:marlowe").label, "Marlowe")
        # "# Hal-Activate Report" → role from AGENT_ROLES; unknown H1 → 'Agent'.
        self.assertEqual(_node(graph, "actor:hal").role, "CEO")
        self.assertEqual(_node(graph, "actor:lyra").role, "Agent")
        self.assertIn(("chunk:c1", "actor:jarvis", "mentions actor"), edges)
        self.assertIn(("file:memory/notes.md", "actor:jarvis", "mentions actor"), edges)
        self.assertIn(("chunk:c2", "actor:hal", "authored by"), edges)

    def test_theme_canonicalization_aliases_and_rejections(self):
        graph = self._graph()
        ids = _node_ids(graph)

        self.assertEqual(_node(graph, "project:launcher-reliability").label, "launcher reliability")
        # CONCEPT_ALIASES maps "token rotation" → "gateway token rotation", and
        # the life index remaps it to a system node with canonical provenance.
        gw = _node(graph, "system:gateway-token-rotation")
        self.assertEqual(gw.label, "Gateway Token Rotation")
        self.assertEqual(gw.canonical_slug, "gateway-token-rotation")
        self.assertEqual(gw.type_confidence, 0.96)
        # Pipe alternatives, morphological flattening, stopword stripping,
        # 4-word truncation, and heading-derived topic nodes.
        for present in ("decision:resolve-by-rotation", "issue:deduplication-nodes-in-graph",
                        "decision:keep-the-naming", "issue:shallow-topic-naming",
                        "decision:alpha-bravo-charlie-delta", "topic:project-launcher-reliability"):
            self.assertIn(present, ids)
        self.assertNotIn("topic:a", ids)  # 1-char heading produces no topic
        # Rejected: scaffolding, file/date labels, numeric-only labels, low-value
        # concepts, and aliases excluded from entity patterns by type/length.
        for absent in ("issue:gateway", "decision:raw", "decision:1-2-3-4",
                       "note:notes", "system:gateway-watch"):
            self.assertNotIn(absent, ids)
        labels = {n.label for n in graph.nodes}
        for rejected in ("status", "results", "gateway", "profile.md", "2026-01-02"):
            self.assertNotIn(rejected, labels)

    def test_semantic_summary_and_scored_pair_edges(self):
        graph = self._graph()

        summaries = [n for n in graph.nodes if n.id.startswith("summary:c1:")]
        self.assertEqual(len(summaries), 1)
        summary = summaries[0]
        self.assertEqual(
            summary.label,
            "launcher reliability | issue: deduplication nodes in graph | "
            "decision: resolve by rotation | outcome: launcher reliability validation",
        )
        self.assertEqual(summary.visibility, "semantic")
        summary_extra = summary.model_extra
        assert summary_extra is not None, "summary must carry model_extra"
        self.assertEqual(summary_extra["summary_labels"][0], "launcher reliability")
        summary_edges = [e for e in graph.edges if e.source == summary.id]
        self.assertIn("summarizes project", {e.label for e in summary_edges})
        self.assertTrue(all(e.visibility == "semantic" for e in summary_edges))
        semantic = [e for e in graph.edges if e.source == "chunk:c1" and e.label == "semantic summary"]
        self.assertEqual([(e.visibility, e.quality_tier) for e in semantic],
                         [("semantic", "semantic")])
        # Fallback path: an actor-only chunk still summarises from its actor.
        fallback = [n for n in graph.nodes if n.id.startswith("summary:c3:")]
        self.assertEqual([n.label for n in fallback], ["vigil"])
        # A single co-occurrence of strongly-linked types is scored and kept.
        scored = [e for e in graph.edges if e.source == "decision:resolve-by-rotation"
                  and e.target == "project:launcher-reliability"]
        self.assertEqual([(e.label, e.semantic_score, e.cooccurrence_count) for e in scored],
                         [("project decision", 0.85, 1)])
        scored_extra = scored[0].model_extra
        assert scored_extra is not None, "scored edge must carry model_extra"
        self.assertEqual(scored_extra["label_visibility"], "hover")

    def test_embedding_similarity_links_cross_file_chunks_only(self):
        graph = self._graph()
        edges = _edge_keys(graph)

        self.assertIn(("chunk:c1", "chunk:c3", "related (1.00)"), edges)
        self.assertIn(("file:memory/notes.md", "file:/abs/docs/other.md", "related (1.00)"), edges)
        sim = next(e for e in graph.edges if e.source == "chunk:c1" and e.target == "chunk:c3")
        self.assertEqual(sim.semantic_score, 1.0)
        # Same file → no similarity edge, even at identical vectors.
        self.assertNotIn(("chunk:c1", "chunk:c2", "related (1.00)"), edges)
        # Malformed ('not-json', '[1.0, "x"]'), non-list ('{"a": 1}'), empty
        # ('[]'), zero-magnitude and mismatched-dimension vectors are skipped
        # without aborting the import.
        skipped = {"chunk:c5", "chunk:c6", "chunk:c7", "chunk:c8", "chunk:c9", "chunk:c10"}
        similarity = [e for e in graph.edges if e.label.startswith("related (")
                      and (e.source in skipped or e.target in skipped)]
        self.assertEqual(similarity, [])
        self.assertIn("chunk:c8", _node_ids(graph))

    def test_unmigrated_store_schema_degrades_to_empty_graph(self):
        import sqlite3

        from kgraph import memory_import

        with tempfile.TemporaryDirectory() as td:
            db = os.path.join(td, "unmigrated.db")
            conn = sqlite3.connect(db)
            conn.execute("CREATE TABLE files (name TEXT)")
            conn.execute("CREATE TABLE chunks (id TEXT)")
            conn.commit()
            conn.close()
            with (
                mock.patch("kgraph.memory_import.load_life_index", return_value=_LIFE_INDEX),
                self.assertLogs("kgraph.memory_import", level="WARNING") as logs,
            ):
                graph = memory_import.load_from_memory_db(db)
        self.assertEqual(graph.nodes, [])
        self.assertEqual(graph.edges, [])
        self.assertTrue(any("Failed to read 'files' table" in line for line in logs.output),
                        logs.output)
        self.assertTrue(any("Failed to import chunks" in line for line in logs.output),
                        logs.output)


class TestMemoryImportPhases(unittest.TestCase):
    """Card 1c8dcf62: the phases split out of the 810-line importer.

    Each case drives ONE phase directly with fixture rows, so a phase that only
    works when the others ran first — or that quietly drops its input — fails
    here instead of being hidden behind the end-to-end import.
    """

    def test_detect_schema_distinguishes_the_two_schemas_and_an_unrelated_db(self):
        import sqlite3

        from kgraph import memory_import

        with tempfile.TemporaryDirectory() as td:
            def schema_for(name, ddl):
                db = os.path.join(td, name)
                conn = sqlite3.connect(db)
                try:
                    for statement in ddl:
                        conn.execute(statement)
                    conn.commit()
                    return memory_import._detect_schema(conn.cursor())
                finally:
                    conn.close()

            self.assertEqual(
                schema_for("store.db", ["CREATE TABLE files (path TEXT)",
                                        "CREATE TABLE chunks (id TEXT)"]),
                "files-chunks")
            self.assertEqual(
                schema_for("registry.db", ["CREATE TABLE memories (id TEXT)",
                                           "CREATE TABLE memory_entities (entity_id TEXT)"]),
                "registry")
            self.assertEqual(schema_for("other.db", ["CREATE TABLE notes (x TEXT)"]), "unknown")
            # Half a pair is NOT a schema: a probe that keyed on one table would
            # send that branch's SQL at the other schema's columns.
            self.assertEqual(schema_for("half-a.db", ["CREATE TABLE files (path TEXT)"]), "unknown")
            self.assertEqual(schema_for("half-b.db", ["CREATE TABLE memories (id TEXT)"]), "unknown")

    def test_ingest_files_emits_file_nodes_and_builds_the_reference_index(self):
        """Catches a file phase that emits the node but leaves the index empty —
        every later `references file` edge then silently stops resolving."""
        import sqlite3

        from kgraph import memory_import
        from kgraph.models import GraphBuilder

        with tempfile.TemporaryDirectory() as td:
            db = os.path.join(td, "files.db")
            conn = sqlite3.connect(db)
            try:
                conn.execute("CREATE TABLE files (path TEXT)")
                conn.executemany("INSERT INTO files VALUES (?)",
                                 [("memory/notes.md",), (None,), ("",)])
                conn.commit()
                with mock.patch("kgraph.memory_import.load_life_index", return_value=_LIFE_INDEX):
                    ingest = memory_import._MemoryStoreIngest(GraphBuilder())
                ingest.ingest_files(conn.cursor())
            finally:
                conn.close()

            graph = ingest.builder.build()
            self.assertEqual(_node_ids(graph), {"file:memory/notes.md"})
            self.assertEqual(_node(graph, "file:memory/notes.md").sources, ["file:memory/notes.md"])
            # The lookup tables are the phase's other output.
            self.assertEqual(ingest.file_node_ids, {"memory/notes.md": "file:memory/notes.md"})
            self.assertEqual(ingest.file_path_by_basename, {"notes.md": ["memory/notes.md"]})
            self.assertEqual(
                memory_import._resolve_file_reference(
                    "notes.md",
                    file_node_ids=ingest.file_node_ids,
                    file_paths=ingest.file_paths,
                    file_path_by_basename=ingest.file_path_by_basename),
                "memory/notes.md")

    def test_ingest_chunks_emits_the_chunk_node_its_containment_edge_and_a_topic(self):
        """Catches a chunk phase that skips the file roll-up edge, drops the
        heading topic, or never hands its embedding to the similarity pass."""
        import sqlite3

        from kgraph import memory_import
        from kgraph.models import GraphBuilder

        with tempfile.TemporaryDirectory() as td:
            db = os.path.join(td, "chunks.db")
            conn = sqlite3.connect(db)
            try:
                conn.execute("CREATE TABLE chunks (id TEXT, path TEXT, start_line INT,"
                             " end_line INT, text TEXT, embedding TEXT)")
                conn.execute("INSERT INTO chunks VALUES (?,?,?,?,?,?)",
                             ("c1", "/docs/notes.md", 1, 2,
                              "## Project: Launcher reliability\nProject: Launcher reliability\n",
                              "[1.0, 0.0]"))
                conn.commit()
                with mock.patch("kgraph.memory_import.load_life_index", return_value=_LIFE_INDEX):
                    ingest = memory_import._MemoryStoreIngest(GraphBuilder())
                embeddings = ingest.ingest_chunks(conn.cursor())
            finally:
                conn.close()

            graph = ingest.builder.build()
            ids = _node_ids(graph)
            self.assertIn("chunk:c1", ids)
            # The containing file node is created even though the `files` table
            # was never read, and the containment edge records the roll-up.
            self.assertIn("file:/docs/notes.md", ids)
            self.assertIn(("file:/docs/notes.md", "chunk:c1", "contains chunk"), _edge_keys(graph))
            # Heading → topic node, and the heading's theme → typed project node.
            self.assertIn("topic:project-launcher-reliability", ids)
            self.assertIn("project:launcher-reliability", ids)
            # The vector is COLLECTED for the similarity pass, not dropped.
            self.assertEqual([(cid, vec) for cid, _path, vec, _mag in embeddings],
                             [("chunk:c1", [1.0, 0.0])])

    def test_emit_semantic_edges_keeps_the_strong_pair_and_drops_the_weak_one(self):
        """Catches an emitter with no cut-off (every co-occurring pair becomes an
        edge, making the semantic layer noise) or one that mis-scores the pair."""
        from kgraph import memory_import
        from kgraph.models import GraphBuilder

        builder = GraphBuilder()
        for node_id, ntype in (("decision:rotate-token", "decision"),
                               ("project:launcher", "project"),
                               ("topic:shallow-labels", "topic"),
                               ("outcome:validated", "outcome")):
            builder.add_node({"id": node_id, "label": node_id, "type": ntype})

        with mock.patch("kgraph.memory_import.load_life_index", return_value=_LIFE_INDEX):
            ingest = memory_import._MemoryStoreIngest(builder)
        ingest.connect_semantic_concepts(["decision:rotate-token", "project:launcher"], "chunk:c1")
        ingest.connect_semantic_concepts(["topic:shallow-labels", "outcome:validated"], "chunk:c1")
        ingest.emit_semantic_edges()

        graph = builder.build()
        scored = next(e for e in graph.edges
                      if e.source == "decision:rotate-token" and e.target == "project:launcher")
        self.assertEqual((scored.label, scored.semantic_score, scored.cooccurrence_count),
                         ("project decision", 0.85, 1))
        scored_extra = scored.model_extra
        assert scored_extra is not None, "scored edge must carry model_extra"
        self.assertEqual(scored_extra["label_visibility"], "hover")
        # A single weak co-occurrence (weight 0.5) does not clear the cut.
        labels = {(e.source, e.target, e.label) for e in graph.edges}
        self.assertNotIn(("outcome:validated", "topic:shallow-labels", "topic outcome"), labels)
        self.assertNotIn(("topic:shallow-labels", "outcome:validated", "topic outcome"), labels)

    def test_end_to_end_import_still_works_through_the_phases(self):
        """The orchestrator still drives every phase for a real store DB."""
        from kgraph import memory_import

        with tempfile.TemporaryDirectory() as td:
            db = os.path.join(td, "store.db")
            _create_store_db(db)
            with mock.patch("kgraph.memory_import.load_life_index", return_value=_LIFE_INDEX):
                graph = memory_import.load_from_memory_db(db)
        ids = _node_ids(graph)
        self.assertIn("file:memory/notes.md", ids)
        self.assertIn("chunk:c1", ids)
        self.assertIn(("chunk:c3", "file:memory/notes.md", "references file"), _edge_keys(graph))


class TestMemoryImportSchemaDetection(unittest.TestCase):
    """Behaviour on DBs that are not a memory registry at all."""

    def _load(self, db):
        from kgraph import memory_import

        with mock.patch("kgraph.memory_import.load_life_index", return_value=_LIFE_INDEX):
            return memory_import.load_from_memory_db(db)

    def test_empty_or_missing_db_yields_empty_graph(self):
        import sqlite3

        with tempfile.TemporaryDirectory() as td:
            empty = os.path.join(td, "empty.db")
            with open(empty, "w", encoding="utf-8"):
                pass
            missing = os.path.join(td, "does-not-exist.db")
            for db in (empty, missing):
                graph = self._load(db)
                self.assertEqual(graph.nodes, [], db)
                self.assertEqual(graph.edges, [], db)
            # sqlite3.connect() creates the file; a bogus path is not an error.
            self.assertTrue(os.path.exists(missing))
            # A directory is not an openable database.
            with self.assertRaises(sqlite3.OperationalError):
                self._load(td)

    def test_partial_schema_needs_both_files_and_chunks(self):
        import sqlite3

        with tempfile.TemporaryDirectory() as td:
            for name, ddl, insert in (
                ("only_files.db", "CREATE TABLE files (path TEXT)",
                 "INSERT INTO files VALUES ('memory/notes.md')"),
                ("only_chunks.db", "CREATE TABLE chunks (id TEXT)",
                 "INSERT INTO chunks VALUES ('c1')"),
            ):
                db = os.path.join(td, name)
                conn = sqlite3.connect(db)
                conn.execute(ddl)
                conn.execute(insert)
                conn.commit()
                conn.close()
                graph = self._load(db)
                self.assertEqual(graph.nodes, [], name)
                self.assertEqual(graph.edges, [], name)


class TestMemoryImportConceptConfig(unittest.TestCase):
    """_load_concept_config() must warn loudly, not fail silently."""

    def test_unreadable_or_malformed_config_warns_and_disables_filtering(self):
        from kgraph import memory_import

        with tempfile.TemporaryDirectory() as td:
            bad = os.path.join(td, "concept-aliases.json")
            with open(bad, "w", encoding="utf-8") as fh:
                fh.write('{"scaffolding_labels": [')
            for path in (os.path.join(td, "absent.json"), bad):
                with (
                    # The loader now lives in constants.py, which owns the single
                    # source for concept classification (item 11.14) — so the path
                    # to patch and the logger to watch moved there with it.
                    mock.patch("kgraph.constants._CONCEPT_CONFIG_PATH", path),
                    self.assertLogs("kgraph.constants", level="WARNING") as logs,
                ):
                    self.assertEqual(memory_import._load_concept_config(), {})
                self.assertIn("concept config unavailable", logs.output[0])


_LONG_MEMORY_CONTENT = "Long " + ("memory content " * 8)


_REGISTRY_DDL = [
    "CREATE TABLE memories (id TEXT, type TEXT, content TEXT, source_agent TEXT, scope TEXT, tags TEXT, confidence REAL, created_at TEXT, concept TEXT, value_score REAL, value_label TEXT, source_layer TEXT, status TEXT)",
    "CREATE TABLE memory_native_chunks (chunk_id TEXT, source_path TEXT, source_kind TEXT, section TEXT, line_start TEXT, line_end TEXT, content TEXT, scope TEXT, status TEXT)",
    "CREATE TABLE memory_entities (entity_id TEXT, kind TEXT, display_name TEXT, normalized_name TEXT, status TEXT, confidence REAL, aliases TEXT)",
    "CREATE TABLE memory_entity_mentions (memory_id TEXT, entity_key TEXT, entity_display TEXT, role TEXT, confidence REAL, scope TEXT)",
    "CREATE TABLE memory_entity_relationships (entity_id_a TEXT, entity_id_b TEXT, relationship_type TEXT, evidence_count INT, source_memory_ids TEXT, confidence REAL)",
    "CREATE TABLE memory_syntheses (synthesis_id TEXT, kind TEXT, subject_type TEXT, subject_id TEXT, content TEXT, stale INT, confidence REAL, generated_at TEXT)",
    "CREATE TABLE memory_claims (memory_id TEXT, memory_tier TEXT, claim_slot TEXT, consolidation_op TEXT, source_strength REAL, surface_candidate TEXT)",
    "CREATE TABLE memory_beliefs (belief_id TEXT, entity_id TEXT, type TEXT, content TEXT, status TEXT, confidence REAL, source_memory_id TEXT, source_layer TEXT)",
    "CREATE TABLE memory_open_loops (loop_id TEXT, kind TEXT, title TEXT, status TEXT, priority TEXT, related_entity_id TEXT)",
    "CREATE TABLE memory_events (event_id TEXT, timestamp TEXT, component TEXT, action TEXT, reason_codes TEXT, memory_id TEXT, payload TEXT)",
]


_REGISTRY_ROWS: list[tuple[str, list[tuple]]] = [
    ("INSERT INTO memories VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)", [
        ("mem-1", "FACT", "Live memory", "jarvis", "jarvis", "[]", 0.9, "2026-04-01", None, None, None, "registry", "active"),
        ("mem-2", "FACT", "Archived memory", "jarvis", "jarvis", "[]", 0.9, "2026-04-01", None, None, None, "registry", "archived"),
        ("mem-3", "FACT", "Odd score memory", "jarvis", "jarvis", "[]", 0.9, "2026-04-01", None, "high", None, "registry", "active"),
        ("mem-4", "FACT", None, "jarvis", "jarvis", "[]", 0.9, "2026-04-01", None, None, None, "registry", "active"),
        ("mem-5", "FACT", "Low value memory", "jarvis", "jarvis", "[]", 0.9, "2026-04-01", None, 0.3, None, "registry", "active"),
        ("mem-6", "FACT", _LONG_MEMORY_CONTENT, "jarvis", "jarvis", "[]", 0.9, "2026-04-01", None, None, None, "registry", "active"),
    ]),
    ("INSERT INTO memory_native_chunks VALUES (?,?,?,?,?,?,?,?,?)", [
        ("chunk-1", "/mem/MEMORY.md", "memory_md", "KG", "4", "4", "Native fact", "profile:main", "active"),
        ("chunk-2", "/mem/MEMORY.md", "memory_md", "KG", "5", "5", "Archived native fact", "profile:main", "archived"),
        ("chunk-3", "/mem/MEMORY.md", "memory_md", "KG", "6", "6", "Live memory", "profile:main", "active"),
    ]),
    ("INSERT INTO memory_entities VALUES (?,?,?,?,?,?,?)", [
        ("e-blank", "person", None, "blank", "active", 0.5, "[]"),
        ("e-1", "person", "Rook", "rook", "active", 0.9, "[]"),
    ]),
    ("INSERT INTO memory_entity_mentions VALUES (?,?,?,?,?,?)", [
        (None, None, None, "general", 0.8, "profile:main"),
        ("mem-1", "database", "database", "general", 0.8, "profile:main"),
        ("mem-1", "rook", "Rook", "general", 0.9, "profile:main"),
        ("mem-1", "vigil", "Vigil", "general", 0.9, "profile:main"),
        ("native:chunk-1", "juno", "Juno", "general", 0.9, "profile:main"),
    ]),
    ("INSERT INTO memory_entity_relationships VALUES (?,?,?,?,?,?)", [
        ("a", "b", "depends_on", 2, '["mem-1"]', 0.8),
        (None, "b", "depends_on", 1, None, 0.5),
        ("c", None, "depends_on", 1, None, 0.5),
    ]),
    ("INSERT INTO memory_syntheses VALUES (?,?,?,?,?,?,?,?)", [
        ("synth-ok", "current_state", "global", "global", "Current State", 0, 0.9, "2026-04-01"),
        ("synth-stale", "old_report", "global", "global", "Old", 1, 0.8, "2026-04-01"),
    ]),
    ("INSERT INTO memory_claims VALUES (?,?,?,?,?,?)", [
        ("mem-1", "durable", "slot-1", "op", 0.9, "Claim text"),
        ("mem-missing", "durable", "slot-2", "op", 0.9, None),
    ]),
    ("INSERT INTO memory_beliefs VALUES (?,?,?,?,?,?,?,?)", [
        ("bel-1", "e-1", "fact", "Live belief", "current", 0.9, "mem-1", "registry"),
        ("bel-2", "e-1", "fact", "Superseded belief", "superseded", 0.9, "mem-1", "registry"),
    ]),
    ("INSERT INTO memory_open_loops VALUES (?,?,?,?,?,?)", [
        ("loop-1", "followup", "Rotate gateway token", "open", "high", None),
        ("loop-2", "followup", "Old closed item", "closed", "low", None),
    ]),
    ("INSERT INTO memory_events VALUES (?,?,?,?,?,?,?)", [
        ("evt-1", "2026-04-01", "capture", "capture_inserted", "[]", "mem-1", "{}"),
        ("evt-2", "2026-04-01", "capture", "capture_inserted", "[]", "mem-1", "{}"),
    ]),
]


def _create_registry_db(path):
    """Synthetic memory-registry DB exercising every filter/skip path."""
    import sqlite3

    conn = sqlite3.connect(path)
    try:
        cur = conn.cursor()
        for statement in _REGISTRY_DDL:
            cur.execute(statement)
        for statement, rows in _REGISTRY_ROWS:
            cur.executemany(statement, rows)
        conn.commit()
    finally:
        conn.close()


class TestMemoryImportRegistryRows(unittest.TestCase):
    """Registry rows: status/value filters, entity resolution, provenance."""

    def _graph(self, include_all=False, subdir="registry.db"):
        from kgraph import memory_import

        with tempfile.TemporaryDirectory() as td:
            db = os.path.join(td, subdir)
            os.makedirs(os.path.dirname(db), exist_ok=True)
            _create_registry_db(db)
            with mock.patch("kgraph.memory_import.load_life_index", return_value=_LIFE_INDEX):
                return memory_import.load_from_memory_db(db, include_all=include_all)

    def test_filters_drop_non_live_rows(self):
        with self.assertLogs("kgraph.memory_import", level="INFO") as logs:
            graph = self._graph()
        ids = _node_ids(graph)

        # status != 'active' drops memories and native chunks; a native chunk
        # duplicating an imported memory is suppressed; low value_score drops;
        # stale syntheses, superseded beliefs and closed loops drop.
        for present in ("memory:mem-1", "memory:native:chunk-1", "memory:mem-3",
                        "synthesis:synth-ok", "belief:bel-1", "open_loop:loop-1"):
            self.assertIn(present, ids)
        for absent in ("memory:mem-2", "memory:native:chunk-2", "memory:native:chunk-3",
                       "memory:mem-5", "synthesis:synth-stale", "belief:bel-2",
                       "open_loop:loop-2"):
            self.assertNotIn(absent, ids)
        # Blank content becomes an empty label without crashing.
        self.assertEqual(_node(graph, "memory:mem-4").label, "")
        # Long content is truncated to 72 chars including the ellipsis.
        long_label = _node(graph, "memory:mem-6").label
        self.assertEqual(len(long_label), 72)
        self.assertTrue(long_label.endswith("…"))
        self.assertTrue(any("2 events skipped" in line for line in logs.output), logs.output)

    def test_include_all_keeps_filtered_rows(self):
        graph = self._graph(include_all=True)
        ids = _node_ids(graph)

        for node_id in ("memory:mem-2", "memory:mem-5", "memory:native:chunk-2",
                        "synthesis:synth-stale", "belief:bel-2", "open_loop:loop-2"):
            self.assertIn(node_id, ids)
        # Promoted-content suppression is unconditional, not a status filter.
        self.assertNotIn("memory:native:chunk-3", ids)

    def test_entity_and_claim_resolution(self):
        graph = self._graph()
        ids = _node_ids(graph)

        # memory_entities with a blank display name creates no node; the noise
        # keyword mention is dropped; unknown keys are synthesized and native:
        # sources are rewritten to the memory:native: node.
        self.assertNotIn("", ids)
        self.assertIn("entity:person:rook", ids)
        self.assertNotIn("entity:database", ids)
        mentions = sorted((e.source, e.target) for e in graph.edges if e.label == "mentions")
        self.assertEqual(mentions, [("memory:mem-1", "entity:person:rook"),
                                    ("memory:mem-1", "entity:vigil"),
                                    ("memory:native:chunk-1", "entity:juno")])
        # Relationships with a missing endpoint are skipped.
        rel = [(e.source, e.target) for e in graph.edges if e.label == "depends_on"]
        self.assertEqual(rel, [("entity:a", "entity:b")])
        # Claims link to their source memory when it survived the filter, and
        # fall back to a slot label when no surface candidate exists.
        self.assertIn(("memory:mem-1", "claim:mem-1:slot-1", "claims"), _edge_keys(graph))
        self.assertEqual(_node(graph, "claim:mem-missing:slot-2").label, "claim slot-2")
        self.assertNotIn(("memory:mem-missing", "claim:mem-missing:slot-2", "claims"),
                         _edge_keys(graph))

    def test_registry_provenance_follows_db_path(self):
        home_node = _node(self._graph(), "memory:mem-1")
        home_extra = home_node.model_extra
        assert home_extra is not None, "imported node must carry model_extra"
        self.assertEqual(home_extra["registry"], "home")
        rook = self._graph(subdir=os.path.join("workspace-rook", "registry.db"))
        rook_node = _node(rook, "memory:mem-1")
        rook_extra = rook_node.model_extra
        assert rook_extra is not None, "imported node must carry model_extra"
        self.assertEqual(rook_extra["registry"], "rook")

    def test_damaged_events_table_degrades_to_minus_one(self):
        # A corrupted memory_events table must not abort the import: the
        # provenance count degrades to -1 and the rest of the registry lands.
        import sqlite3

        from kgraph import memory_import

        with tempfile.TemporaryDirectory() as td:
            db = os.path.join(td, "registry.db")
            _create_registry_db(db)
            conn = sqlite3.connect(db)
            conn.execute("PRAGMA writable_schema=ON")
            conn.execute("UPDATE sqlite_master SET rootpage=0 WHERE name='memory_events'")
            conn.commit()
            conn.execute("PRAGMA writable_schema=OFF")
            conn.close()
            with (
                mock.patch("kgraph.memory_import.load_life_index", return_value=_LIFE_INDEX),
                self.assertLogs("kgraph.memory_import", level="INFO") as logs,
            ):
                graph = memory_import.load_from_memory_db(db)
        self.assertIn("memory:mem-1", _node_ids(graph))
        self.assertTrue(any("-1 events skipped" in line for line in logs.output), logs.output)


if __name__ == "__main__":
    unittest.main()
