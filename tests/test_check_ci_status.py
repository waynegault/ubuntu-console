"""Tests for the console CI verdict gate (card CI-WATCH-CONSOLE-001).

The gate exists because CI is a write-only signal here: nothing read GitHub's
verdict, so a red main sat unread (Nightly Full Suite 36215222418, 2026-09-26) and
a run that never started looked exactly like a quiet one.

These tests pin the four decisions the card names, each as a case that can fail:

* a RED verdict for the pushed tip blocks, and a governed exemption must EXPIRE;
* a queued/in-progress run is "no verdict yet" — never green, never red;
* a completed run for a DIFFERENT commit is never attributed to the current head
  (the console difference: ci.yml has no `concurrency:`, so superseded runs queue);
* being unable to read the verdict is reported as UNKNOWN, never as green.

The mutation proof is `TestMainMutationProof`: the same fixture returns exit 0 and
then exit 1 when one field — the conclusion — is flipped.  A gate nobody can make
red is not evidence.

Two kinds of class below, deliberately: the pure ones are `unittest.TestCase` and
the ones needing pytest fixtures (monkeypatch/tmp_path/capsys) are plain pytest
classes, because a unittest method receives no injected fixtures.
"""

from __future__ import annotations

import json
import unittest
from datetime import UTC, date, datetime, timedelta

import pytest
from _paths import REPO_ROOT

import check_ci_status as mod

TIP = "a" * 40
OTHER = "b" * 40
GRACE = 20
NOW = datetime(2026, 9, 26, 12, 0, tzinfo=UTC)
FUTURE = date.today() + timedelta(days=7)
PAST = date.today() - timedelta(days=1)


def run_row(
    workflow: str,
    conclusion: str,
    created: datetime,
    *,
    status: str = "completed",
    sha: str = TIP,
    event: str = "push",
) -> dict:
    """Build one GitHub run row as `gh run list --json` emits it."""
    return {
        "workflowName": workflow,
        "conclusion": conclusion,
        "status": status,
        "headSha": sha,
        "createdAt": created.isoformat().replace("+00:00", "Z"),
        "url": f"https://example.invalid/{workflow}",
        "event": event,
    }


def entry(
    workflow: str, *, expiry: date, owner: str = "wayne", card: str = "CI-WATCH-CONSOLE-001"
) -> mod.BaselineEntry:
    """Build a baseline exemption."""
    return mod.BaselineEntry(
        workflow=workflow, owner=owner, card=card, expiry=expiry, reason="test", lineno=1
    )


def evaluate(
    runs: list[dict],
    entries: list[mod.BaselineEntry] | None = None,
    *,
    tip: str = TIP,
    tip_at: datetime | None = None,
    grace: int = GRACE,
    local_sha: str = "",
    awaiting_push_reason: str = "",
) -> mod.Report:
    """Evaluate with the newest push-run stamp derived from `runs`."""
    stamps = mod._push_run_stamps(runs)
    return mod.evaluate(
        runs,
        list(entries or []),
        branch="main",
        tip_sha=tip,
        tip_committed_at=tip_at,
        newest_push_run_at=max(stamps) if stamps else None,
        grace_minutes=grace,
        local_sha=local_sha,
        awaiting_push_reason=awaiting_push_reason,
    )


class ParseBaselineTests(unittest.TestCase):
    def test_parses_a_governed_entry(self) -> None:
        text = (
            "# a comment\n"
            "\n"
            "workflow=CI | owner=wayne | card=CI-WATCH-CONSOLE-001 | expiry=2099-01-01 | flaky\n"
        )
        (parsed,) = mod.parse_baseline(text)
        self.assertEqual(parsed.workflow, "CI")
        self.assertEqual(parsed.owner, "wayne")
        self.assertEqual(parsed.card, "CI-WATCH-CONSOLE-001")
        self.assertEqual(parsed.expiry.isoformat(), "2099-01-01")
        self.assertIn("flaky", parsed.reason)

    def test_missing_governance_field_is_an_error_not_a_skip(self) -> None:
        with self.assertRaises(ValueError) as ctx:
            mod.parse_baseline("workflow=CI | owner=wayne | expiry=2099-01-01 | no card\n")
        self.assertIn("card", str(ctx.exception))

    def test_unparseable_expiry_is_an_error(self) -> None:
        with self.assertRaises(ValueError):
            mod.parse_baseline("workflow=CI | owner=w | card=C | expiry=soon | reason\n")

    def test_missing_workflow_prefix_is_an_error(self) -> None:
        with self.assertRaises(ValueError):
            mod.parse_baseline("CI | owner=w | card=C | expiry=2099-01-01 | reason\n")

    def test_expired_entry_reports_expired(self) -> None:
        (parsed,) = mod.parse_baseline(
            "workflow=CI | owner=w | card=C | expiry=2000-01-01 | old\n"
        )
        self.assertTrue(parsed.expired)

    def test_live_entry_is_not_expired(self) -> None:
        (parsed,) = mod.parse_baseline(
            "workflow=CI | owner=w | card=C | expiry=2099-01-01 | live\n"
        )
        self.assertFalse(parsed.expired)


class NewestPerWorkflowTests(unittest.TestCase):
    def test_newest_completed_run_wins(self) -> None:
        runs = [
            run_row("CI", "failure", NOW - timedelta(hours=2)),
            run_row("CI", "success", NOW - timedelta(hours=1)),
        ]
        (status,) = mod.newest_per_workflow(runs)
        self.assertEqual(status.conclusion, "success")

    def test_cancelled_is_skipped_so_it_never_reds(self) -> None:
        runs = [
            run_row("CI", "cancelled", NOW - timedelta(hours=1)),
            run_row("CI", "success", NOW - timedelta(hours=2)),
        ]
        (status,) = mod.newest_per_workflow(runs)
        self.assertEqual(status.conclusion, "success")

    def test_each_workflow_tracked_separately(self) -> None:
        runs = [
            run_row("CI", "success", NOW),
            run_row("Nightly Full Suite", "failure", NOW),
        ]
        by_name = {s.workflow: s for s in mod.newest_per_workflow(runs)}
        self.assertFalse(by_name["CI"].red)
        self.assertTrue(by_name["Nightly Full Suite"].red)

    def test_an_unfinished_run_is_pending_and_has_no_verdict(self) -> None:
        runs = [run_row("CI", "", NOW, status="in_progress")]
        (status,) = mod.newest_per_workflow(runs)
        self.assertTrue(status.pending)
        self.assertEqual(status.conclusion, "")
        self.assertFalse(status.red)

    def test_queued_run_does_not_replace_the_last_verdict(self) -> None:
        # The console's shape: a queued (not cancelled) run sits on top of the last
        # completed verdict, which is still the PREVIOUS commit's.
        runs = [
            run_row("CI", "", NOW, status="queued", sha=TIP),
            run_row("CI", "success", NOW - timedelta(hours=1), sha=OTHER),
        ]
        (status,) = mod.newest_per_workflow(runs)
        self.assertTrue(status.pending)
        self.assertEqual(status.head_sha, OTHER)
        self.assertEqual(status.conclusion, "success")


class EvaluateRedTests(unittest.TestCase):
    def test_red_run_for_the_tip_without_exemption_blocks(self) -> None:
        report = evaluate([run_row("CI", "failure", NOW)])
        self.assertTrue(report.failing)
        self.assertEqual([s.workflow for s in report.red], ["CI"])

    def test_red_run_exempted_by_a_live_entry_does_not_block(self) -> None:
        report = evaluate([run_row("CI", "failure", NOW)], [entry("CI", expiry=FUTURE)])
        self.assertFalse(report.failing)
        self.assertEqual(len(report.exempted), 1)

    def test_expired_exemption_does_not_exempt_and_itself_fails(self) -> None:
        report = evaluate([run_row("CI", "failure", NOW)], [entry("CI", expiry=PAST)])
        self.assertTrue(report.failing)
        self.assertEqual(len(report.red), 1)
        self.assertEqual(len(report.expired_entries), 1)

    def test_exemption_for_a_different_workflow_does_not_leak(self) -> None:
        report = evaluate(
            [run_row("CI", "failure", NOW)],
            [entry("Nightly Full Suite", expiry=FUTURE)],
        )
        self.assertTrue(report.failing)
        self.assertEqual(len(report.red), 1)

    def test_green_run_reports_nothing_red(self) -> None:
        report = evaluate([run_row("CI", "success", NOW)])
        self.assertFalse(report.failing)
        self.assertTrue(report.green)

    def test_timed_out_and_startup_failure_are_red(self) -> None:
        for conclusion in ("timed_out", "startup_failure", "action_required"):
            with self.subTest(conclusion=conclusion):
                report = evaluate([run_row("CI", conclusion, NOW)])
                self.assertTrue(report.failing)


class SupersededAndPendingTests(unittest.TestCase):
    """The measured console difference — a superseded run queues, it is not cancelled."""

    def test_a_green_for_another_commit_is_not_this_heads_green(self) -> None:
        report = evaluate([run_row("CI", "success", NOW, sha=OTHER)])
        self.assertEqual(len(report.superseded), 1)
        self.assertFalse(report.green)
        self.assertFalse(report.failing)

    def test_a_red_for_another_commit_is_not_this_heads_red(self) -> None:
        report = evaluate([run_row("CI", "failure", NOW, sha=OTHER)])
        self.assertEqual(report.red, [])
        self.assertFalse(report.failing)
        self.assertEqual(len(report.superseded), 1)

    def test_a_queued_run_for_the_tip_is_no_verdict_yet(self) -> None:
        runs = [
            run_row("CI", "", NOW, status="queued", sha=TIP),
            run_row("CI", "success", NOW - timedelta(hours=1), sha=OTHER),
        ]
        report = evaluate(runs)
        self.assertEqual(len(report.pending), 1)
        self.assertEqual(report.superseded, [])
        self.assertFalse(report.green)
        self.assertFalse(report.failing)

    def test_a_workflow_with_only_a_queued_run_is_pending(self) -> None:
        report = evaluate([run_row("CI", "", NOW, status="in_progress", sha=TIP)])
        self.assertEqual(len(report.pending), 1)
        self.assertFalse(report.green)

    def test_a_tip_verdict_together_with_a_pending_rerun_is_still_green(self) -> None:
        runs = [
            run_row("CI", "", NOW, status="queued", sha=TIP),
            run_row("CI", "success", NOW - timedelta(minutes=5), sha=TIP),
        ]
        report = evaluate(runs)
        self.assertEqual(report.pending, [])
        self.assertTrue(report.green)


class EvaluateDarkTests(unittest.TestCase):
    def test_no_push_run_at_all_is_dark(self) -> None:
        report = evaluate([], tip_at=NOW)
        self.assertTrue(report.dark)

    def test_commit_newer_than_newest_push_run_is_dark(self) -> None:
        report = evaluate(
            [run_row("CI", "success", NOW - timedelta(hours=2))],
            tip_at=NOW,
        )
        self.assertTrue(report.dark)

    def test_run_within_the_grace_window_is_not_dark(self) -> None:
        report = evaluate(
            [run_row("CI", "success", NOW - timedelta(minutes=5))],
            tip_at=NOW,
        )
        self.assertFalse(report.dark)

    def test_a_fresh_SCHEDULED_run_does_not_clear_dark(self) -> None:
        # nightly.yml is schedule-driven by design: it says nothing about whether a
        # push produced a run, so DARK is judged on push-triggered runs only.
        report = evaluate(
            [run_row("Nightly Full Suite", "success", NOW, event="schedule")],
            tip_at=NOW,
        )
        self.assertTrue(report.dark)

    def test_a_fresh_push_run_does_clear_dark(self) -> None:
        report = evaluate([run_row("CI", "success", NOW)], tip_at=NOW)
        self.assertFalse(report.dark)

    def test_dark_alone_does_not_block(self) -> None:
        report = evaluate([], tip_at=NOW)
        self.assertTrue(report.dark)
        self.assertFalse(report.failing)


class AwaitingPushTests(unittest.TestCase):
    def test_local_head_ahead_is_awaiting_push_not_dark_not_failing(self) -> None:
        report = evaluate(
            [run_row("CI", "success", NOW)],
            tip_at=NOW,
            local_sha=OTHER,
            awaiting_push_reason="local HEAD is not the pushed tip",
        )
        self.assertTrue(report.awaiting_push)
        self.assertFalse(report.dark)
        self.assertFalse(report.failing)
        self.assertTrue(report.green)


class FeedStalenessTests(unittest.TestCase):
    def test_backwards_is_stale(self) -> None:
        self.assertTrue(mod._feed_went_backwards(NOW, NOW + timedelta(minutes=1)))

    def test_forward_is_not_stale(self) -> None:
        self.assertFalse(mod._feed_went_backwards(NOW, NOW - timedelta(minutes=1)))

    def test_equal_is_not_stale(self) -> None:
        self.assertFalse(mod._feed_went_backwards(NOW, NOW))

    def test_missing_either_side_is_not_stale(self) -> None:
        self.assertFalse(mod._feed_went_backwards(None, NOW))
        self.assertFalse(mod._feed_went_backwards(NOW, None))


class TestPushedTipAndSlug:
    """Plain pytest class: these cases take the `monkeypatch` fixture."""

    def test_parses_the_commit_payload(self, monkeypatch) -> None:
        monkeypatch.setattr(
            mod,
            "_gh_json",
            lambda args, *, timeout: {
                "sha": TIP,
                "commit": {"committer": {"date": "2026-09-26T10:00:00Z"}},
            },
        )
        sha, stamp = mod.pushed_tip("owner/name", "main")
        assert sha == TIP
        assert stamp == datetime(2026, 9, 26, 10, 0, tzinfo=UTC)

    def test_missing_committer_date_is_no_time_not_an_error(self, monkeypatch) -> None:
        monkeypatch.setattr(mod, "_gh_json", lambda args, *, timeout: {"sha": TIP})
        sha, stamp = mod.pushed_tip("owner/name", "main")
        assert sha == TIP
        assert stamp is None

    def test_non_object_payload_is_unknown(self, monkeypatch) -> None:
        monkeypatch.setattr(mod, "_gh_json", lambda args, *, timeout: [])
        with pytest.raises(mod.CiStatusUnknown):
            mod.pushed_tip("owner/name", "main")

    def test_slug_is_derived_from_the_origin_remote(self) -> None:
        slug = mod.repo_slug()
        assert slug.count("/") == 1
        assert not slug.startswith("/")

    def test_cache_file_lives_inside_dot_git(self) -> None:
        # Never committed, and therefore needs no .gitignore entry.
        assert ".git" in mod.CACHE_FILE.parts

    def test_the_baseline_sits_with_the_other_baselines(self) -> None:
        assert mod.BASELINE_FILE.parent.name == "tools"
        assert mod.BASELINE_FILE.exists()
        assert mod.parse_baseline(mod.BASELINE_FILE.read_text()) == []

    def test_the_repo_root_resolves(self) -> None:
        assert str(mod.REPO_DIR) == REPO_ROOT


class TestMainUnknown:
    """An unreadable verdict is UNKNOWN, never green."""

    @staticmethod
    def _patch(monkeypatch, tmp_path) -> None:
        monkeypatch.setattr(mod, "CACHE_FILE", tmp_path / "ci.json")

        def boom(*args: object, **kwargs: object) -> None:
            raise mod.CiStatusUnknown("no egress")

        monkeypatch.setattr(mod, "repo_slug", boom)
        monkeypatch.setattr(mod, "local_head", lambda: (TIP, NOW))
        monkeypatch.setattr(mod, "pushed_tip", lambda slug, branch: (TIP, NOW))

    def test_unknown_warns_and_passes_without_strict(self, monkeypatch, tmp_path, capsys) -> None:
        self._patch(monkeypatch, tmp_path)
        assert mod.main([]) == 0
        assert "UNKNOWN" in capsys.readouterr().err

    def test_unknown_is_fatal_with_strict(self, monkeypatch, tmp_path) -> None:
        self._patch(monkeypatch, tmp_path)
        assert mod.main(["--strict-unknown"]) == 2

    def test_unknown_is_never_green_in_json(self, monkeypatch, tmp_path, capsys) -> None:
        self._patch(monkeypatch, tmp_path)
        mod.main(["--json"])
        payload = json.loads(capsys.readouterr().out)
        assert payload["unknown"]
        assert not payload.get("green", False)


class TestMainMutationProof:
    """The card's acceptance: the gate must be provably red-able by mutation."""

    @staticmethod
    def _patch(monkeypatch, tmp_path, runs) -> None:
        monkeypatch.setattr(mod, "CACHE_FILE", tmp_path / "ci.json")
        monkeypatch.setattr(mod, "repo_slug", lambda: "owner/name")
        monkeypatch.setattr(mod, "local_head", lambda: (TIP, NOW))
        monkeypatch.setattr(mod, "pushed_tip", lambda slug, branch: (TIP, NOW))
        monkeypatch.setattr(mod, "_run_gh", lambda args, *, timeout: list(runs))

    def test_the_same_fixture_is_green_then_red_by_one_field(
        self, monkeypatch, tmp_path
    ) -> None:
        runs = [run_row("CI", "success", NOW)]
        self._patch(monkeypatch, tmp_path, runs)
        assert mod.main(["--fail"]) == 0

        # MUTATION: flip the conclusion only, and re-probe past the cache.
        runs[0]["conclusion"] = "failure"
        monkeypatch.setattr(mod, "CACHE_FILE", tmp_path / "ci-mutated.json")
        assert mod.main(["--fail"]) == 1

    def test_red_is_exempted_by_the_baseline_file(self, monkeypatch, tmp_path) -> None:
        baseline = tmp_path / "ci-status-baseline.txt"
        baseline.write_text(
            "workflow=CI | owner=wayne | card=CI-WATCH-CONSOLE-001 "
            f"| expiry={(date.today() + timedelta(days=1)).isoformat()} | being fixed\n"
        )
        self._patch(monkeypatch, tmp_path, [run_row("CI", "failure", NOW)])
        monkeypatch.setattr(mod, "BASELINE_FILE", baseline)
        assert mod.main(["--fail"]) == 0

    def test_a_malformed_baseline_fails_loudly(self, monkeypatch, tmp_path) -> None:
        baseline = tmp_path / "ci-status-baseline.txt"
        baseline.write_text("workflow=CI | owner=wayne | expiry=2099-01-01 | no card\n")
        self._patch(monkeypatch, tmp_path, [run_row("CI", "success", NOW)])
        monkeypatch.setattr(mod, "BASELINE_FILE", baseline)
        assert mod.main(["--fail"]) == 1

    def test_the_cache_short_circuits_a_second_probe(self, monkeypatch, tmp_path) -> None:
        calls = {"n": 0}

        def counting_run_gh(args: list[str], *, timeout: int) -> list[dict]:
            calls["n"] += 1
            return [run_row("CI", "success", NOW)]

        self._patch(monkeypatch, tmp_path, [])
        monkeypatch.setattr(mod, "_run_gh", counting_run_gh)
        assert mod.main(["--fail"]) == 0
        assert mod.main(["--fail"]) == 0
        assert calls["n"] == 1


class TestCLISurface:
    def test_print_baseline_shows_the_format(self, capsys) -> None:
        assert mod.main(["--print-baseline"]) == 0
        assert "workflow=<name> | owner=<owner> | card=<card> | expiry=YYYY-MM-DD" in (
            capsys.readouterr().out
        )
