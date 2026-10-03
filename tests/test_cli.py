"""Tests for kgraph.cli — graph loading, subcommand dispatch, git hooks."""

import contextlib
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

from _kgraph_fixtures import _AST_GRAPH, _SMALL_GRAPH
import kgraph


class TestCliGraphLoad(unittest.TestCase):
    def _load(self, graph_path):
        import argparse

        from kgraph.cli import _load_graph

        args = argparse.Namespace(
            graph=graph_path, graph_db=os.path.join(tempfile.gettempdir(), "kgraph-missing.sqlite"),
            import_db=None,
        )
        return _load_graph(args)

    def test_missing_graph_file_exits_with_message(self):
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            with self.assertRaises(SystemExit) as ctx:
                self._load("/nonexistent/definitely-not-here.json")
        self.assertEqual(ctx.exception.code, 1)
        self.assertIn("failed to load graph file", stderr.getvalue())

    def test_schema_invalid_graph_file_exits_with_message(self):
        # A provenance tag in `source` with no `from` has no real endpoint; the
        # CLI must report it cleanly rather than letting a pydantic traceback
        # escape from a renderer.
        with tempfile.TemporaryDirectory() as td:
            path = os.path.join(td, "bad-schema.json")
            with open(path, "w", encoding="utf-8") as f:
                json.dump({"nodes": [], "edges": [{"source": "ast", "target": "n2"}]}, f)
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                with self.assertRaises(SystemExit) as ctx:
                    self._load(path)
        self.assertEqual(ctx.exception.code, 1)
        self.assertIn("invalid graph", stderr.getvalue())

    def test_malformed_graph_file_exits_with_message(self):
        with tempfile.TemporaryDirectory() as td:
            path = os.path.join(td, "bad.json")
            with open(path, "w", encoding="utf-8") as f:
                f.write("{ not valid json")
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                with self.assertRaises(SystemExit) as ctx:
                    self._load(path)
        self.assertEqual(ctx.exception.code, 1)
        self.assertIn("bad.json", stderr.getvalue())


class _CliHarness(unittest.TestCase):
    """Drives cli.main() directly; no subprocess."""

    def _run(self, argv):
        from kgraph import cli

        stdout, stderr = io.StringIO(), io.StringIO()
        # cli.main() takes no argv and argparse reads sys.argv itself, so the
        # sys.argv *list* is swapped for the duration of the call (restored on
        # exit); nothing else in this process reads argv while it is patched.
        with (mock.patch.object(sys, "argv", argv),
              contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr)):
            try:
                cli.main()
            except SystemExit as exc:
                return exc.code, stdout.getvalue(), stderr.getvalue()
        return 0, stdout.getvalue(), stderr.getvalue()

    def _graph_file(self, td, graph=None):
        path = os.path.join(td, "graph.json")
        with open(path, "w", encoding="utf-8") as f:
            json.dump(_SMALL_GRAPH if graph is None else graph, f)
        return path


class TestCliLoadGraphFallbacks(unittest.TestCase):
    def _args(self, graph=None, graph_db=None, import_db=None):
        import argparse

        from kgraph.cli import _load_graph

        return _load_graph(argparse.Namespace(graph=graph, graph_db=graph_db,
                                             import_db=import_db))

    def test_a_graph_file_wins_and_the_graph_db_is_the_fallback(self):
        with tempfile.TemporaryDirectory() as td:
            path = os.path.join(td, "g.json")
            with open(path, "w", encoding="utf-8") as f:
                json.dump(_AST_GRAPH, f)
            db = os.path.join(td, "graph.sqlite")
            kgraph.save_to_graph_db(db, _SMALL_GRAPH)
            from_file = self._args(graph=path, graph_db=db)
            from_db = self._args(graph_db=db, import_db=os.path.join(td, "no-mem.db"))
        self.assertEqual({n["id"] for n in from_file["nodes"]},
                         {n["id"] for n in _AST_GRAPH["nodes"]})
        self.assertEqual({n["id"] for n in from_db["nodes"]}, {"a", "b", "c"})

    def test_an_empty_graph_db_falls_through_to_the_memory_db(self):
        from kgraph import cli

        with tempfile.TemporaryDirectory() as td:
            db = os.path.join(td, "graph.sqlite")
            kgraph.save_to_graph_db(db, {"nodes": [], "edges": []})
            mem = os.path.join(td, "mem.sqlite")
            with open(mem, "w", encoding="utf-8") as f:
                f.write("")
            with (mock.patch.object(cli, "resolve_memory_db_path", return_value=mem),
                  mock.patch.object(cli, "load_from_memory_db",
                                    return_value=kgraph.Graph.from_dict(_AST_GRAPH))):
                loaded = self._args(graph_db=db, import_db=None)
        self.assertEqual(len(loaded["nodes"]), len(_AST_GRAPH["nodes"]))

    def test_failing_sources_are_logged_and_the_sample_graph_is_used(self):
        from kgraph import cli

        with tempfile.TemporaryDirectory() as td:
            db = os.path.join(td, "graph.sqlite")
            mem = os.path.join(td, "mem.sqlite")
            for path in (db, mem):
                with open(path, "w", encoding="utf-8") as f:
                    f.write("not a sqlite db")
            with (mock.patch.object(cli, "load_from_graph_db", side_effect=OSError("locked")),
                  mock.patch.object(cli, "resolve_memory_db_path", return_value=mem),
                  mock.patch.object(cli, "load_from_memory_db", side_effect=ValueError("bad db")),
                  self.assertLogs("kgraph.cli", level="WARNING") as captured):
                loaded = self._args(graph_db=db, import_db=None)
            self.assertTrue(any("Failed to load graph from graph DB" in m for m in captured.output))
            self.assertTrue(any("Failed to load graph from memory DB" in m for m in captured.output))
            # Nothing exists and nothing is resolvable: the sample graph.
            loaded = self._args(graph_db=os.path.join(td, "missing.sqlite"),
                                import_db=os.path.join(td, "missing-mem.db"))
        self.assertEqual({n["id"] for n in loaded["nodes"]},
                         {n["id"] for n in kgraph.SAMPLE_GRAPH["nodes"]})


class TestCliMainModes(_CliHarness):
    def test_reporting_modes_print_and_write_expected_output(self):
        with tempfile.TemporaryDirectory() as td:
            graph = self._graph_file(td)
            bench, report, html = (os.path.join(td, n) for n in
                                   ("bench.json", "r.md", "flow.html"))
            cases = [
                (["query", "--query", "Alpha"], ["1 matching nodes:", "[topic] Alpha (a)", "match=exact"]),
                (["query", "--query", "zzz-nope"], ['No nodes matching "zzz-nope"']),
                (["path", "--path", "a", "c"], ["Path:", "a → b: project topic [0.9]"]),
                (["explain", "--explain", "a"], ["Node: Alpha (a)", "Connections: 1 (1 out, 0 in)"]),
                (["confidence"], ["Edge confidence:", "INFERRED:  2 (100.0%)"]),
                (["communities"], ["1 communities (detected now):", "Alpha · Beta · Gamma — 3 members"]),
                (["god-nodes", "--top-god-nodes", "2"], ["Top 2 god nodes:", "Beta"]),
                (["call-flow"], ["```mermaid"]),
                (["call-flow", "--output", html], [f"Written to {html}"]),
                (["benchmark", "--output", bench], ["Benchmark written to", "Token-Reduction Benchmark"]),
                (["report", "--report-path", report], ["Wrote", "# Knowledge Graph Report"]),
                (["audit"], ["# Security Audit — kgraph"]),
            ]
            for argv, expected in cases:
                with self.subTest(command=argv[0]):
                    code, out, _ = self._run(["kgraph", *argv, "--graph", graph])
                    self.assertEqual(code, 0)
                    for want in expected:
                        self.assertIn(want, out)
            self.assertTrue(os.path.exists(html))
            with open(bench, encoding="utf-8") as f:
                self.assertEqual(json.load(f)["node_count"], 3)
            with open(report, encoding="utf-8") as f:
                self.assertIn("- **Edges:** 2", f.read())

    def test_communities_and_god_nodes_edge_cases(self):
        from kgraph import cli

        with tempfile.TemporaryDirectory() as td:
            graph = self._graph_file(td)
            empty = self._graph_file(td, {"nodes": [], "edges": []})
            _, out, _ = self._run(["kgraph", "communities", "--graph", empty])
            self.assertIn("No communities detected", out)
            _, out, _ = self._run(["kgraph", "god-nodes", "--graph", empty])
            self.assertIn("No god nodes found", out)
            for command in ("communities", "god-nodes"):
                with mock.patch.object(cli, "communities_available", return_value=False):
                    code, _, err = self._run(["kgraph", command, "--graph", graph])
                self.assertEqual(code, 1)
                self.assertIn("networkx not available", err)

    def test_audit_reports_a_missing_file(self):
        from kgraph import cli

        # cli's own `os` binding is swapped so the audit file looks absent;
        # os.path.join (which builds the path) still runs for real.
        fake_os = mock.MagicMock(wraps=os)
        fake_os.path.exists.return_value = False
        with mock.patch.object(cli, "os", fake_os):
            _, out, _ = self._run(["kgraph", "audit"])
        self.assertIn("Security audit report not found at", out)

    def test_pr_dashboard_forwards_options(self):
        with tempfile.TemporaryDirectory() as td:
            graph = self._graph_file(td)
            target = os.path.join(td, "dash.html")
            with mock.patch("kgraph.pr_dashboard.generate_pr_dashboard") as build:
                code, out, _ = self._run([
                    "kgraph", "pr-dashboard", "--graph", graph, "--output", target,
                    "--days", "7", "--author", "Wayne", "--max-prs", "5"])
            self.assertEqual(code, 0)
            self.assertIn(f"Written to {target}", out)
            kwargs = build.call_args.kwargs
            self.assertEqual((kwargs["output_path"], kwargs["days"], kwargs["author"],
                              kwargs["max_prs"]), (target, 7, "Wayne", 5))
            self.assertEqual(len(kwargs["graph_data"]["nodes"]), 3)

    def test_update_and_watch_forward_their_options(self):
        from kgraph import cli

        with tempfile.TemporaryDirectory() as td:
            db, mem = (os.path.join(td, n) for n in ("graph.sqlite", "mem.sqlite"))
            out_json = os.path.join(td, "updated.json")
            graph = kgraph.Graph.from_dict(_SMALL_GRAPH)
            with mock.patch.object(cli, "incremental_update", return_value=graph) as upd:
                code, out, _ = self._run([
                    "kgraph", "update", "--graph-db", db, "--import-db", mem,
                    "--source-dir", td, "--ast-vars", "--ast-max-files", "5",
                    "--include-all", "--output", out_json])
            self.assertEqual(code, 0)
            self.assertIn("Update complete: 3 nodes, 2 edges", out)
            self.assertIn("EXTRACTED: 0, INFERRED: 2, AMBIGUOUS: 0", out)
            kwargs = upd.call_args.kwargs
            self.assertEqual((upd.call_args.args[0], kwargs["mem_db_path"], kwargs["source_dir"]),
                             (db, mem, td))
            self.assertTrue((kwargs["ast"], kwargs["ast_vars"], kwargs["include_all"]))
            self.assertEqual(kwargs["ast_max_files"], 5)
            with open(out_json, encoding="utf-8") as f:
                self.assertEqual(len(json.load(f)["nodes"]), 3)
            with mock.patch.object(cli, "incremental_update", return_value=graph) as upd:
                self._run(["kgraph", "update", "--graph-db", db, "--import-db", mem])
            # No source dir means no AST pass, and no --output means no file.
            self.assertEqual((upd.call_args.kwargs["ast"],
                              upd.call_args.kwargs["source_dir"]), (False, None))
            with mock.patch.object(cli, "start_watch") as watch:
                self.assertEqual(self._run([
                    "kgraph", "watch", "--graph-db", db, "--import-db", mem,
                    "--source-dir", td, "--watch-interval", "7", "--ast-vars",
                    "--ast-max-files", "3", "--ast-subdirs", "sub"])[0], 0)
            kwargs = watch.call_args.kwargs
            self.assertEqual((watch.call_args.args[0], kwargs["mem_db_path"],
                              kwargs["source_dir"], kwargs["interval"]), (db, mem, td, 7))
            self.assertTrue((kwargs["ast"], kwargs["ast_vars"]))
            self.assertEqual((kwargs["ast_max_files"], kwargs["ast_subdirs"]), (3, ["sub"]))

    def test_mcp_default_and_explicit_port(self):
        with tempfile.TemporaryDirectory() as td:
            with mock.patch("kgraph.mcp_server.serve_mcp") as serve:
                self.assertEqual(self._run(["kgraph", "mcp"])[0], 0)
            self.assertEqual((serve.call_args.kwargs["port"], serve.call_args.kwargs["graph_db"]),
                             (8331, kgraph.GRAPH_DB_DEFAULT))
            with mock.patch("kgraph.mcp_server.serve_mcp") as serve:
                self._run(["kgraph", "mcp", "--host", "0.0.0.0", "--port", "9000",
                           "--graph-db", os.path.join(td, "g.sqlite")])
        self.assertEqual((serve.call_args.kwargs["host"], serve.call_args.kwargs["port"],
                          serve.call_args.kwargs["graph_db"]),
                         ("0.0.0.0", 9000, os.path.join(td, "g.sqlite")))

    def test_ast_errors_and_a_real_extraction(self):
        from kgraph import cli

        code, _, err = self._run(["kgraph", "ast"])
        self.assertEqual(code, 1)
        self.assertIn("--repo is required for AST extraction", err)
        with tempfile.TemporaryDirectory() as td:
            with mock.patch.object(cli, "ast_available", return_value=False):
                code, _, err = self._run(["kgraph", "ast", "--repo", td])
            self.assertEqual((code, "tree-sitter not available" in err), (1, True))
            os.makedirs(os.path.join(td, "parser"))
            with open(os.path.join(td, "parser", "mod.py"), "w", encoding="utf-8") as f:
                f.write("def hello():\n    print('hi')\n")
            with open(os.path.join(td, "other.py"), "w", encoding="utf-8") as f:
                f.write("def other():\n    pass\n")
            _, out, _ = self._run(["kgraph", "ast", "--repo", td])
            self.assertIn('"ast_func:python:hello"', out)
            target = os.path.join(td, "ast.json")
            _, out, _ = self._run(["kgraph", "ast", "--repo", td, "--ast-vars",
                                   "--ast-max-files", "5", "--ast-subdirs", "parser",
                                   "--output", target])
            self.assertIn(f"Saved to {target}", out)
            with open(target, encoding="utf-8") as f:
                ids = {n["id"] for n in json.load(f)["nodes"]}
        self.assertIn("ast_func:python:hello", ids)
        self.assertNotIn("ast_func:python:other", ids)  # --ast-subdirs restricted the scan

    def test_wiring_errors_summary_and_show_all(self):
        from kgraph import wiring

        code, _, err = self._run(["kgraph", "wiring"])
        self.assertEqual((code, "--repo is required" in err), (1, True))
        with tempfile.TemporaryDirectory() as td:
            with open(os.path.join(td, "mod.py"), "w", encoding="utf-8") as f:
                f.write("x = 1\n")
            _, out, _ = self._run(["kgraph", "wiring", "--repo", td])
            self.assertIn("Wiring analysis:", out)
            self.assertIn("'orphans': 1", out)
            with mock.patch.object(wiring, "format_wiring_report",
                                   return_value="FULL REPORT") as fmt:
                _, out, _ = self._run(["kgraph", "wiring", "--repo", td, "--wiring-all"])
        self.assertIn("FULL REPORT", out)
        self.assertTrue(fmt.call_args.kwargs["show_all"])

    def test_default_mode_writes_html_and_serve_flag_serves_it(self):
        from kgraph import cli

        with tempfile.TemporaryDirectory() as td:
            graph = self._graph_file(td)
            target = os.path.join(td, "out.html")
            code, out, _ = self._run(["kgraph", "html", "--graph", graph, "--output", target])
            self.assertEqual((code, out.splitlines()[0]), (0, f"Wrote {target}"))
            self.assertIn("usage: kgraph", out)
            with mock.patch.object(cli, "serve_file") as serve:
                code, out, _ = self._run([
                    "kgraph", "serve", "--graph", graph, "--output", target,
                    "--host", "0.0.0.0", "--port", "8123", "--store",
                    os.path.join(td, "store.json"), "--embed", "--view", "topics",
                    "--semantic-threshold", "0.5"])
            self.assertEqual(code, 0)
            self.assertNotIn("usage: kgraph", out)
            kwargs = serve.call_args.kwargs
            self.assertEqual(serve.call_args.args[0], target)
            self.assertEqual((kwargs["host"], kwargs["port"], kwargs["store_path"]),
                             ("0.0.0.0", 8123, os.path.join(td, "store.json")))
            self.assertTrue(kwargs["force_embed"])
            self.assertEqual((kwargs["view_mode"], kwargs["semantic_threshold"]), ("topics", 0.5))
            self.assertEqual(kwargs["graph_db_path"], os.path.expanduser(kgraph.GRAPH_DB_DEFAULT))


class TestCliSubcommandDispatch(_CliHarness):
    """Card 75219978: the subcommand dispatch table.

    The old ``main()`` was a 365-line if-chain.  These cases pin the properties the
    table must have for that rewrite to be safe — every advertised command reaches a
    handler, the removed flat-flag form is rejected rather than silently dispatched,
    and an unknown command fails loudly instead of falling through to the default
    render (which would exit 0 and write a file: the silent no-op the case exists to
    stop).
    """

    def test_the_advertised_commands_and_the_dispatch_table_agree(self):
        from kgraph import cli

        advertised = [name for name, _ in cli._COMMANDS]
        self.assertEqual(len(advertised), len(set(advertised)))
        for name, help_text in cli._COMMANDS:
            self.assertTrue(help_text.strip(), name)
        # A renamed command would advertise a name with no handler, or leave a
        # dispatch key nothing advertises — both fail here rather than at runtime.
        self.assertEqual(set(advertised), set(cli._DISPATCH))
        for name in advertised:
            self.assertTrue(callable(cli._DISPATCH[name]), name)

    def test_the_flat_flag_form_is_not_accepted(self):
        # No backwards compatibility: a mode flag is not a command.  Each of these
        # was a valid flat invocation before the subcommand rewrite, and every one
        # must now fail with usage rather than silently dispatching a mode.
        for flat in (["--update"], ["--audit"], ["--serve"], ["--query", "Alpha"]):
            code, out, err = self._run(["kgraph", *flat])
            self.assertNotEqual(code, 0, flat)
            self.assertIn("usage: kgraph", err, flat)
            self.assertNotIn("Wrote", out, flat)

    def test_a_subcommand_reaches_its_handler(self):
        # `audit` is the cheapest handler with a deterministic, file-only effect.
        code, out, _ = self._run(["kgraph", "audit"])
        self.assertEqual(code, 0)
        self.assertIn("# Security Audit", out)

    def test_dispatch_calls_the_handler_the_subcommand_names(self):
        from kgraph import cli

        calls = []
        with mock.patch.dict(cli._DISPATCH, {"audit": lambda args: calls.append(args.command)}):
            code, _, _ = self._run(["kgraph", "audit"])
        self.assertEqual((code, calls), (0, ["audit"]))

    def test_an_unknown_command_exits_nonzero_with_usage(self):
        code, out, err = self._run(["kgraph", "definitely-not-a-command"])
        self.assertNotEqual(code, 0)
        self.assertIn("usage: kgraph", err)
        self.assertNotIn("Wrote", out)

    def test_a_subcommand_missing_its_value_fails_loudly(self):
        # `kgraph query` names a mode but no pattern — a loud error, never a
        # handler that runs on None.
        code, out, err = self._run(["kgraph", "query"])
        self.assertEqual(code, 1)
        self.assertIn("--query", err)
        self.assertNotIn("matching nodes", out)


class TestCliGitHooks(_CliHarness):
    def _hooks_dir(self, td):
        hooks = os.path.join(td, "hooks")
        os.makedirs(hooks)
        return hooks

    def test_install_writes_executable_hooks_and_respects_existing_ones(self):
        from kgraph import cli

        with tempfile.TemporaryDirectory() as td:
            hooks = self._hooks_dir(td)
            with mock.patch.object(cli, "_find_git_hooks_dir", return_value=hooks):
                code, out, err = self._run(["kgraph", "install-hook"])
                self.assertEqual((code, err), (0, ""))
                self.assertIn(f"Installed post-commit hook in {hooks}", out)
                for name in ("post-commit", "post-merge"):
                    path = os.path.join(hooks, name)
                    self.assertEqual(os.stat(path).st_mode & 0o777, 0o755)
                    with open(path, encoding="utf-8") as f:
                        content = f.read()
                    self.assertIn("kgraph auto-rebuild", content)
                    self.assertIn("kgraph update --source-dir", content)
                # A pre-existing kgraph hook is rewritten, not refused.
                self.assertNotIn("not installed by kgraph",
                                 self._run(["kgraph", "install-hook"])[2])

            foreign = os.path.join(hooks, "post-commit")
            with open(foreign, "w", encoding="utf-8") as f:
                f.write("#!/bin/bash\n# husky\n")
            os.remove(os.path.join(hooks, "post-merge"))
            os.makedirs(os.path.join(hooks, "post-merge"))  # unreadable (a dir)
            with mock.patch.object(cli, "_find_git_hooks_dir", return_value=hooks):
                code, _, err = self._run(["kgraph", "install-hook"])
            self.assertEqual(code, 0)
            with open(foreign, encoding="utf-8") as f:
                self.assertEqual(f.read(), "#!/bin/bash\n# husky\n")
            self.assertIn("existing hook was not installed by kgraph", err)
            self.assertIn("cannot read existing hook", err)
            self.assertTrue(os.path.isdir(os.path.join(hooks, "post-merge")))

    def test_uninstall_removes_only_its_own_hooks(self):
        from kgraph import cli

        with tempfile.TemporaryDirectory() as td:
            hooks = self._hooks_dir(td)
            ours, theirs = (os.path.join(hooks, n) for n in ("post-commit", "post-merge"))
            with open(ours, "w", encoding="utf-8") as f:
                f.write("#!/bin/bash\n# kgraph auto-rebuild\n")
            with open(theirs, "w", encoding="utf-8") as f:
                f.write("#!/bin/bash\n# husky\n")
            with mock.patch.object(cli, "_find_git_hooks_dir", return_value=hooks):
                code, out, err = self._run(["kgraph", "uninstall-hook"])
            self.assertEqual(code, 0)
            self.assertEqual((os.path.exists(ours), os.path.exists(theirs)), (False, True))
            self.assertIn(f"Removed {ours}", out)
            self.assertIn("not a kgraph hook", err)

        with tempfile.TemporaryDirectory() as td:
            hooks = self._hooks_dir(td)
            unreadable = os.path.join(hooks, "post-commit")
            os.makedirs(unreadable)
            with mock.patch.object(cli, "_find_git_hooks_dir", return_value=hooks):
                code, _, err = self._run(["kgraph", "uninstall-hook"])
            self.assertEqual((code, "cannot read hook" in err, os.path.isdir(unreadable)),
                             (0, True, True))

    def test_hook_commands_exit_when_not_in_a_git_repo(self):
        from kgraph import cli

        for command in ("install-hook", "uninstall-hook"):
            with mock.patch.object(cli, "_find_git_hooks_dir", return_value=None):
                code, _, err = self._run(["kgraph", command])
            self.assertEqual(code, 1)
            self.assertIn("not in a git repository", err)


class TestCliFindGitHooksDir(unittest.TestCase):
    def setUp(self):
        self._cwd = os.getcwd()
        self.addCleanup(os.chdir, self._cwd)

    def test_walks_up_to_the_git_hooks_directory_and_none_without_one(self):
        from kgraph.cli import _find_git_hooks_dir

        with tempfile.TemporaryDirectory() as td:
            hooks = os.path.join(td, ".git", "hooks")
            nested = os.path.join(td, "a", "b")
            os.makedirs(hooks)
            os.makedirs(nested)
            os.chdir(nested)
            self.assertEqual(_find_git_hooks_dir(), hooks)
        with tempfile.TemporaryDirectory() as td:
            os.chdir(td)
            self.assertIsNone(_find_git_hooks_dir())

    def test_core_hooks_path_wins_over_the_git_dir(self):
        """A repo that tracks its hooks sets core.hooksPath, and git then
        ignores .git/hooks — so a hook installed there would never run."""
        from kgraph.cli import _find_git_hooks_dir

        with tempfile.TemporaryDirectory() as td:
            repo = os.path.join(td, "repo")
            os.makedirs(repo)
            subprocess.run(["git", "-C", repo, "init", "-q"], check=True, capture_output=True)
            tracked = os.path.join(td, "tracked-hooks")
            os.makedirs(tracked)
            subprocess.run(["git", "-C", repo, "config", "core.hooksPath", tracked],
                           check=True, capture_output=True)
            os.chdir(repo)
            self.assertEqual(_find_git_hooks_dir(), tracked)

    def test_relative_core_hooks_path_resolves_against_the_repo(self):
        """git accepts a relative core.hooksPath; it must not be read as a
        path relative to whatever directory the process happens to be in."""
        from kgraph.cli import _find_git_hooks_dir

        with tempfile.TemporaryDirectory() as td:
            repo = os.path.join(td, "repo")
            os.makedirs(repo)
            subprocess.run(["git", "-C", repo, "init", "-q"], check=True, capture_output=True)
            subprocess.run(["git", "-C", repo, "config", "core.hooksPath", "tools/hooks"],
                           check=True, capture_output=True)
            os.chdir(repo)
            self.assertEqual(_find_git_hooks_dir(), os.path.join(repo, "tools", "hooks"))


if __name__ == "__main__":
    unittest.main()
