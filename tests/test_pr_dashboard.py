"""Tests for kgraph.pr_dashboard — git gathering, correlation, HTML, escaping."""

import os
import subprocess
import tempfile
import unittest
from unittest import mock

from _paths import REPO_ROOT
import kgraph


class TestPRDashboard(unittest.TestCase):
    def test_generate_pr_dashboard_not_a_repo(self):
        with tempfile.TemporaryDirectory() as td:
            html = kgraph.generate_pr_dashboard(td)
            self.assertIn("Error", html)
            self.assertIn("Not a git repository", html)

    def test_generate_pr_dashboard_real_repo(self):
        # THIN SMOKE, deliberately: it proves generate_pr_dashboard runs against a
        # real repository and returns HTML, nothing about the content. The ROWS are
        # pinned against a known commit history in
        # TestPRDashboardGitData::test_the_dashboard_renders_rows_from_a_fixture_repo,
        # which is where a rendering regression is caught.
        html = kgraph.generate_pr_dashboard(REPO_ROOT, days=7)
        self.assertIn("PR Dashboard", html)
        self.assertIn("<!doctype html>", html)

    def test_generate_pr_dashboard_output_file(self):
        with tempfile.TemporaryDirectory() as td:
            out = os.path.join(td, "dashboard.html")
            kgraph.generate_pr_dashboard(REPO_ROOT, days=7, output_path=out)
            self.assertTrue(os.path.exists(out))


class _FailingSubprocess:
    """Module-local stand-in for pr_dashboard.subprocess whose run() always fails.

    Replacing pr_dashboard's own `subprocess` NAME keeps the real subprocess
    module (and everything else in the process) untouched.
    """

    class SubprocessError(Exception):
        pass

    @staticmethod
    def run(*_args, **_kwargs):
        raise OSError("git unavailable")


class TestPRDashboardGitData(unittest.TestCase):
    @staticmethod
    def _git_env(td):
        # Isolate from the user's global/system git config.
        return dict(
            os.environ,
            HOME=td,
            GIT_CONFIG_NOSYSTEM="1",
            GIT_AUTHOR_NAME="Dash Tester",
            GIT_AUTHOR_EMAIL="dash@example.test",
            GIT_COMMITTER_NAME="Dash Tester",
            GIT_COMMITTER_EMAIL="dash@example.test",
        )

    @classmethod
    def _make_repo(cls, td):
        env = cls._git_env(td)

        def git(*args):
            subprocess.run(["git", *args], cwd=td, env=env, check=True,
                           capture_output=True, text=True)

        git("init", "-q")
        with open(os.path.join(td, "a.txt"), "w", encoding="utf-8") as f:
            f.write("one\n")
        git("add", "-A")
        git("commit", "-q", "-m", "initial commit")
        base = subprocess.run(
            ["git", "rev-parse", "--abbrev-ref", "HEAD"],
            cwd=td, env=env, capture_output=True, text=True, check=True,
        ).stdout.strip()
        git("checkout", "-q", "-b", "feature")
        with open(os.path.join(td, "b.txt"), "w", encoding="utf-8") as f:
            f.write("two\n")
        git("add", "-A")
        git("commit", "-q", "-m", "feature commit")
        git("checkout", "-q", base)
        git("merge", "--no-ff", "-q", "-m", "merge feature", "feature")
        return base

    def test_gathers_commits_files_branches_and_authors(self):
        from kgraph import pr_dashboard

        with tempfile.TemporaryDirectory() as td:
            self._make_repo(td)
            data = pr_dashboard._gather_git_data(td, 30, None, 30)

        self.assertGreaterEqual(data["total_commits"], 2)
        self.assertGreaterEqual(data["total_merges"], 1)
        paths = {f["path"] for f in data["recent_files"]}
        self.assertIn("a.txt", paths)
        self.assertIn("b.txt", paths)
        self.assertTrue(any(b["current"] for b in data["branches"]))
        self.assertIn("Dash Tester", data["authors"])
        self.assertEqual(data["total_files_changed"], len(data["recent_files"]))

    def test_author_filter_is_applied(self):
        from kgraph import pr_dashboard

        with tempfile.TemporaryDirectory() as td:
            self._make_repo(td)
            data = pr_dashboard._gather_git_data(td, 30, "Nobody At All", 30)
        self.assertEqual(data["total_commits"], 0)

    def test_git_failures_are_logged_and_reported_as_an_error_entry(self):
        from kgraph import pr_dashboard

        with tempfile.TemporaryDirectory() as td:
            os.makedirs(os.path.join(td, ".git"))
            with (
                mock.patch.object(pr_dashboard, "subprocess", _FailingSubprocess()),
                mock.patch.object(pr_dashboard, "logger") as log,
            ):
                data = pr_dashboard._gather_git_data(td, 30, None, 30)

        self.assertEqual(data["merges"], [{"error": "git unavailable"}])
        for key in ("commits", "recent_files", "branches"):
            self.assertEqual(data[key], [])
        self.assertEqual(data["authors"], {})
        self.assertGreaterEqual(log.warning.call_count, 3)

    def test_generate_pr_dashboard_on_a_non_repo_reports_an_error(self):
        with tempfile.TemporaryDirectory() as td:
            html = kgraph.generate_pr_dashboard(td)
        self.assertIn("Not a git repository", html)
        self.assertIn("Error", html)

    def test_generate_pr_dashboard_writes_the_output_file(self):
        with tempfile.TemporaryDirectory() as td:
            self._make_repo(td)
            out = os.path.join(td, "nested", "dashboard.html")
            with self.assertLogs("kgraph.pr_dashboard", level="INFO") as log:
                html = kgraph.generate_pr_dashboard(td, days=7, output_path=out)
            self.assertTrue(os.path.exists(out))
            with open(out, encoding="utf-8") as f:
                self.assertEqual(f.read(), html)
        # The library logs the write and returns the HTML; the CLI prints the line.
        self.assertTrue(any("PR dashboard written to" in m for m in log.output))
        self.assertIn("Merges", html)
        self.assertIn("PR Dashboard", html)

    def test_the_dashboard_renders_rows_from_a_fixture_repo(self):
        """A fixture repo's known history is rendered as ROWS, not just a heading.

        Catches: the dashboard emitting its heading while dropping or mis-rendering
        the merge/commit/file rows the repository actually has. The REPO_ROOT smoke
        in TestPRDashboard cannot pin this — its history is whatever the working
        repo happens to hold — so this drives a temp repo with a known history:
        base commit -> feature commit -> `merge feature`, plus the two changed files.
        """
        with tempfile.TemporaryDirectory() as td:
            self._make_repo(td)
            html = kgraph.generate_pr_dashboard(td, days=7)
        # Merge row and commit rows (each is a <td> cell of the row).
        self.assertIn("<td>merge feature</td>", html)
        self.assertIn("<td>initial commit</td>", html)
        self.assertIn("<td>feature commit</td>", html)
        # The changed files appear in the files list.
        self.assertIn("a.txt", html)
        self.assertIn("b.txt", html)
        # The feature branch appears as a branch row (no marker: it is not current).
        self.assertIn("<li>feature</li>", html)


class TestPRDashboardCorrelation(unittest.TestCase):
    @staticmethod
    def _git_data(paths):
        return {"recent_files": [{"status": "M", "path": p} for p in paths]}

    def test_matches_in_both_directions_and_skips_nodes_without_a_path(self):
        from kgraph import pr_dashboard

        git_data = self._git_data(["scripts/kgraph/server.py"])
        graph = {"nodes": [
            {"id": "n1", "label": "server", "type": "file", "path": "server.py"},
            {"id": "n2", "label": "pkg", "type": "file",
             "path": "scripts/kgraph/server.py"},
            {"id": "n3", "label": "no path", "type": "topic"},
        ]}
        found = pr_dashboard._correlate_with_graph(git_data, graph)
        self.assertEqual({c["node_id"] for c in found}, {"n1", "n2"})
        self.assertEqual(found[0]["node_type"], "file")

    def test_deduplicates_and_caps_the_result(self):
        from kgraph import pr_dashboard

        one = {"nodes": [{"id": "n1", "label": "N", "path": "f.py"}] * 3}
        self.assertEqual(
            len(pr_dashboard._correlate_with_graph(self._git_data(["f.py"]), one)), 1)

        many = {"nodes": [{"id": f"n{i}", "label": "N", "path": f"p{i}.py"}
                          for i in range(60)]}
        git_many = self._git_data([f"p{i}.py" for i in range(60)])
        self.assertEqual(
            len(pr_dashboard._correlate_with_graph(git_many, many)), 50)

    def test_empty_graph_yields_no_correlations(self):
        from kgraph import pr_dashboard

        self.assertEqual(
            pr_dashboard._correlate_with_graph(self._git_data(["f.py"]), {}), [])
        self.assertEqual(
            pr_dashboard._correlate_with_graph(self._git_data(["f.py"]), None), [])


class TestPRDashboardHtml(unittest.TestCase):
    @staticmethod
    def _build(git_data, correlations=None):
        from kgraph import pr_dashboard

        return pr_dashboard._build_dashboard_html(
            git_data, correlations or [], "/tmp/repo", 30)

    def test_status_badges_cover_every_branch(self):
        html = self._build({"recent_files": [
            {"status": "A", "path": "added.py"},
            {"status": "D", "path": "deleted.py"},
            {"status": "M", "path": "modified.py"},
            {"status": "R100", "path": "renamed.py"},
            {"status": "?", "path": "odd.py"},
        ]})
        self.assertIn('class="badge added"', html)
        self.assertIn('class="badge deleted"', html)
        self.assertIn('class="badge modified"', html)
        self.assertIn('class="badge renamed"', html)
        self.assertIn('<span class="badge">?</span>', html)

    def test_marks_the_current_branch(self):
        html = self._build({"branches": [{"name": "main", "current": True},
                                         {"name": "old", "current": False}]})
        self.assertIn("<strong>▶</strong> main", html)
        self.assertIn("<li>old</li>", html)

    def test_row_limits_are_applied(self):
        html = self._build({
            "merges": [{"hash": f"h{i}", "author_name": "A", "subject": "s",
                        "date": "2026-01-01"} for i in range(25)],
            "commits": [{"hash": f"c{i}", "author_name": "A", "subject": "s",
                         "date": "2026-01-01"} for i in range(35)],
            "recent_files": [{"status": "M", "path": f"f{i}.py"} for i in range(45)],
            "branches": [{"name": f"b{i}", "current": False} for i in range(20)],
        })
        self.assertNotIn("h24", html)     # merges capped at 20
        self.assertNotIn("c34", html)     # commits capped at 30
        self.assertNotIn("f44.py", html)  # files capped at 40
        self.assertNotIn("b19", html)     # branches capped at 15

    def test_correlation_count_renders(self):
        html = self._build({"total_merges": 0, "total_commits": 0}, [
            {"file": "a.py", "node_label": "A", "node_type": "file"},
            {"file": "b.py", "node_label": "B", "node_type": "file"},
        ])
        self.assertIn("Graph Correlations (2)", html)
        self.assertIn("a.py", html)


class TestPRDashboardEscaping(unittest.TestCase):
    def test_pr_dashboard_escapes_git_metadata(self):
        from kgraph.pr_dashboard import _build_dashboard_html

        git_data = {
            "merges": [{
                "hash": "abc12345",
                "author_name": "<script>alert(1)</script>",
                "subject": "</td><script>alert(2)</script>",
                "date": "2026-09-11",
            }],
            "commits": [],
            "recent_files": [{"status": "M", "path": "<img src=x onerror=alert(3)>"}],
            "branches": [{"name": "<script>alert(5)</script>", "current": True}],
            "authors": {"<script>alert(6)</script>": "a@b.c"},
            "total_commits": 0,
            "total_merges": 1,
            "total_files_changed": 1,
            "total_branches": 1,
        }
        html = _build_dashboard_html(git_data, [], "/tmp/<script>repo", 30)
        for injected in (
            "<script>alert(1)</script>",
            "<script>alert(2)</script>",
            "<script>alert(5)</script>",
            "<script>alert(6)</script>",
            "<img src=x onerror=alert(3)>",
        ):
            self.assertNotIn(injected, html)
        self.assertIn("&lt;script&gt;alert(1)&lt;/script&gt;", html)


if __name__ == "__main__":
    unittest.main()
