#!/usr/bin/env bats
# ==============================================================================
# Unit — tools/swallow-classify.py: the PROPOSAL, and the comparison that can fail
# ==============================================================================
# Card SPLIT-CONTRACT-TRIAGE-001.  The `swallows` check already enforces the count; the
# delta this card adds is a MODEL VERDICT that proposes the `# swallow-ok:` reason.  Two
# things therefore have to be true of the tool, and they pull in opposite directions:
#
#   * it must ASSEMBLE a proposal from a typed answer, per site, in code — the model
#     answers ONE narrow question and the code decides what that means;
#   * it must never GATE.  Nothing passes or fails on model output: the deterministic
#     count/baseline in `check-contracts.sh swallows` stays the only enforcement
#     (Wayne's ruling, 2026-09-29), so a model that disagrees with every human marker
#     is still just a report.
#
# The comparison is the part that has to be able to FAIL, and it is driven by a
# SEEDED FIXTURE plus a STUBBED model answer — never by production labels, because the
# corpus carries no negative (`masking`) label at all: one marker kind exists, and a
# marker is a human saying "deliberate".  The stub replaces the tool's OWN HTTP
# functions module-locally (driver.py below), never the global `urllib` module, so
# unrelated calls in the same process still run and their failures still surface.
#
# Hermetic: a throwaway tree under $BATS_TEST_TMPDIR, a driver that patches only the
# tool's HTTP seam, and no request to any lane — the endpoint the tests pass is
# unroutable on purpose, and `--baseline-only` must not resolve it at all.
# REF: "Towards Spec-Driven Test Automation: Part 1" (Gal Arav, TDS, 2026-09-24) — https://towardsdatascience.com/towards-spec-driven-test-automation-part-1/
# ==============================================================================

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export CHECKER="$REPO_ROOT/tools/check-contracts.sh"
    # TOOL is read from the environment when it is already set, so this suite can be
    # run against a deliberately broken copy of the tool (the mutation run in the card's
    # report), exactly as 34 does for CHECKER:
    #   TOOL=/tmp/mutant/tools/swallow-classify.py bats tests/unit/35-swallow-classify.bats
    export TOOL="${TOOL:-$REPO_ROOT/tools/swallow-classify.py}"
    export PY="$REPO_ROOT/.venv/bin/python3"
    [[ -x "$PY" ]] || export PY="python3"
    export FIXTURE="$BATS_TEST_TMPDIR/fixture"
    export DRIVER="$BATS_TEST_TMPDIR/driver.py"
    export LABELS="$BATS_TEST_TMPDIR/labels.tsv"
    # BELT AND BRACES: every stubbed case also passes an UNROUTABLE endpoint.  The
    # driver replaces the tool's HTTP functions, so this is never dialled — but if that
    # patch ever stops taking effect, the run fails fast (exit 2) instead of asking the
    # live lane at :18084, which a unit test must never do.
    export DEAD_ENDPOINT="http://127.0.0.1:1"
    mkdir -p "$FIXTURE/scripts"
    _write_fixture
    MASKING_LINE=$(grep -n '^sync_cert() ' "$FIXTURE/scripts/01-fixture.sh" | cut -d: -f1)
    BENIGN_LINE=$(grep -n '^probe_optional() ' "$FIXTURE/scripts/01-fixture.sh" | cut -d: -f1)
    export MASKING_LINE BENIGN_LINE
    _write_labels
    _write_driver
}

# _write_fixture — one SEEDED MASKING site (an unclassified swallow whose failure is
# discarded), and one human-classified BENIGN site (the marker is the human verdict).
# Deliberately wrong on purpose where it is wrong: the first site must NOT be "fixed".
_write_fixture() {
    cat > "$FIXTURE/scripts/01-fixture.sh" <<'SH'
#!/usr/bin/env bash
# Fixture for tests/unit/35-swallow-classify.bats.

# SEEDED MASKING site: the certificate copy is a REQUIRED step and its failure is
# discarded, so the next line runs on a broken premise.  Left unclassified on purpose.
sync_cert() { cp "$FIXTURE_CERT" "$FIXTURE_ETC/cert.pem" 2>/dev/null || true; }

# swallow-ok: the optional probe tool is absent on a minimal box and the caller checks for it.
probe_optional() { command -v optional-probe 2>/dev/null >/dev/null; }
SH
}

# _write_labels — the labelled sample for the comparison, in the tool's TSV shape.
_write_labels() {
    {
        printf '%s\n' '# label -> <file>:<line><TAB>benign|masking'
        printf 'scripts/01-fixture.sh:%s\tmasking\n' "$MASKING_LINE"
        printf 'scripts/01-fixture.sh:%s\tbenign\n' "$BENIGN_LINE"
    } > "$LABELS"
}

# _write_driver — load the tool and replace ITS HTTP functions, module-locally.
#
# The patch is verified after it is applied, on purpose: a typo in the seam's NAME
# (measured — `http_json_post` for `http_post_json`) leaves the real function in place
# and the run then calls the lane the tests must never touch.  These assertions turn
# that into a loud failure instead of a silent dial-out.
_write_driver() {
    cat > "$DRIVER" <<'PY'
"""Run tools/swallow-classify.py with its own HTTP seam patched.

`http_get_json`/`http_post_json` are the tool's OWN functions — patched here, never
the global `urllib`/`subprocess` modules, so unrelated calls in this process still run
and their failures still surface.  STUB_ANSWER is the model's reply, verbatim.
"""
import importlib.util
import os
import sys

spec = importlib.util.spec_from_file_location("swallow_classify", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

for _name in ("http_get_json", "http_post_json"):
    assert callable(getattr(module, _name, None)), f"no HTTP seam named {_name}"


def _get(url, timeout):
    return {"data": [{"id": "stub-model"}]}


def _post(url, payload, timeout):
    # The seam asserts the contract it replaces: the chat URL, and a model NAME that
    # came from discovery (never a hardcoded one).
    assert url.endswith("/v1/chat/completions"), url
    assert isinstance(payload.get("model"), str) and payload["model"], payload
    return {"choices": [{"message": {"content": os.environ["STUB_ANSWER"]}}]}


module.http_get_json = _get
module.http_post_json = _post
# Prove the patch reached the globals the callers look through, or stop here.
assert module.discover_model.__globals__["http_get_json"] is _get
assert module.ask_model.__globals__["http_post_json"] is _post
sys.exit(module.main(sys.argv[2:]))
PY
}

# ── the site source ────────────────────────────────────────────────────────
@test "dump: the checker's JSONL dump is the site source, and it names the seeded sites" {
    # The tool reads sites through this mode, so the mode's stream must be pure JSONL
    # (every line parses) and must expose the seeded fault as UNCLASSIFIED — a dump
    # that said "classified" for everything would make every proposal meaningless.
    "$CHECKER" swallows --dump-sites --repo "$FIXTURE" > "$BATS_TEST_TMPDIR/dump.jsonl" \
        2> "$BATS_TEST_TMPDIR/dump.err"
    run "$PY" - "$BATS_TEST_TMPDIR/dump.jsonl" "$MASKING_LINE" "$BENIGN_LINE" <<'PY'
import json
import sys

rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
masking_line, benign_line = int(sys.argv[2]), int(sys.argv[3])
hits = [row for row in rows if row["file"] == "scripts/01-fixture.sh"]
masking = [row for row in hits if row["line"] == masking_line]
benign = [row for row in hits if row["line"] == benign_line]
assert len(masking) == 2, masking            # the seeded line carries both patterns
assert all(not row["classified"] for row in masking), masking
assert all(row["reason"] is None for row in masking), masking
assert len(benign) == 1, benign
assert benign[0]["classified"] and benign[0]["reason_source"] == "line-above", benign
print("seeded rows:", len(masking), "unclassified,", len(benign), "classified")
PY
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"seeded rows: 2 unclassified, 1 classified"* ]]

    # ...and the CHECK still fails on this fixture: the dump is a read-only view of the
    # population, not a weakened check (the seeded site is unclassified, no baseline row).
    run "$CHECKER" swallows --repo "$FIXTURE"
    [[ "$status" -eq 1 ]]
}

@test "baseline: --baseline-only is deterministic, touches no endpoint, and counts both units" {
    # The card's ordering, enforced here: the human baseline is measured with NO model
    # call at all.  The endpoint is unroutable on purpose — the mode must not resolve it.
    run "$PY" "$TOOL" --repo "$FIXTURE" --baseline-only --endpoint http://127.0.0.1:1
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"HUMAN BASELINE"* ]]
    [[ "$output" == *"3 site hit(s) on 2 unique site-line(s)"* ]]
    [[ "$output" == *"1 classified site-line(s) / 1 classified site-hit(s)"* ]]
    [[ "$output" == *"1 distinct reason(s)"* ]]
    [[ "$output" == *"0 masking"* ]]
    [[ "$output" == *"1 unclassified site-line(s) await a proposal"* ]]
}

@test "verdicts: a benign answer is assembled in code and proposed as a human marker" {
    run env STUB_ANSWER=$'VERDICT: benign\nREASON: the optional probe is absent by design on a minimal box' \
        "$PY" "$DRIVER" "$TOOL" --repo "$FIXTURE" --endpoint "$DEAD_ENDPOINT" --limit 0
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"model=stub-model"* ]]
    [[ "$output" == *"asked 2 unique site-line(s): 2 benign · 0 masking · 0 unparsed"* ]]
    [[ "$output" == *"AGREEMENT      on the 1 classified site-line(s) asked: 1 agree"* ]]
    [[ "$output" == *"-> # swallow-ok: the optional probe is absent by design on a minimal box"* ]]
}

# ── the comparison, and the direction that must FAIL ───────────────────────
@test "falsification: a site the model calls BENIGN where the label says MASKING fails" {
    # The card's acceptance criterion, seeded: the fixture line is labelled masking and
    # the model answers benign.  A comparison that passed here would be the "can never
    # disagree" test suite in miniature.
    run env STUB_ANSWER=$'VERDICT: benign\nREASON: the required copy is best effort at this stage' \
        "$PY" "$DRIVER" "$TOOL" --repo "$FIXTURE" --endpoint "$DEAD_ENDPOINT" --limit 0 --labels "$LABELS"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"MISMATCH   scripts/01-fixture.sh:$MASKING_LINE labelled masking, model said benign"* ]]
    [[ "$output" == *"The comparison FAILED"* ]]
}

@test "falsification: the reverse — a benign site the model calls MASKING — also fails" {
    run env STUB_ANSWER=$'VERDICT: masking\nREASON: the probe failure is hidden from the caller here' \
        "$PY" "$DRIVER" "$TOOL" --repo "$FIXTURE" --endpoint "$DEAD_ENDPOINT" --limit 0 --labels "$LABELS"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"MISMATCH   scripts/01-fixture.sh:$BENIGN_LINE labelled benign, model said masking"* ]]
    [[ "$output" == *"MASKING CANDIDATES (ratify or reject)  2"* ]]
}

@test "falsification: an unparsed answer satisfies no label, and is never read as benign" {
    run env STUB_ANSWER='I think this is probably fine, honestly.' \
        "$PY" "$DRIVER" "$TOOL" --repo "$FIXTURE" --endpoint "$DEAD_ENDPOINT" --limit 0 --labels "$LABELS"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"asked 2 unique site-line(s): 0 benign · 0 masking · 2 unparsed"* ]]
    [[ "$output" == *"model said unparsed — an unparsed verdict does not satisfy a label"* ]]
}

@test "parsing: a preambled VERDICT line still parses; a bare word is not a verdict" {
    # Tolerance in one direction only: the model may think out loud BEFORE the answer,
    # but an answer that never commits is unparsed — never defaulted to benign.
    run env STUB_ANSWER=$'Sure — here is my answer:\nVERDICT: masking\nREASON: the required copy failure is discarded' \
        "$PY" "$DRIVER" "$TOOL" --repo "$FIXTURE" --endpoint "$DEAD_ENDPOINT" --limit 1 --only unclassified
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"1 unique site-line(s): 0 benign · 1 masking · 0 unparsed"* ]]

    run env STUB_ANSWER='benign' "$PY" "$DRIVER" "$TOOL" --repo "$FIXTURE" --endpoint "$DEAD_ENDPOINT" --limit 1 \
        --only unclassified
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"1 unique site-line(s): 0 benign · 0 masking · 1 unparsed"* ]]
}

@test "posture: a model that disagrees with every marker is a report, not a verdict" {
    # THE NON-GATING HALF.  Same masking-for-everything stub as the case above, but no
    # --labels: exit 0, the disagreement is listed for ratification, and the corpus is
    # byte-identical afterwards — the tool proposes, it never edits and never gates.
    local _before _after
    _before=$(sha256sum "$FIXTURE/scripts/01-fixture.sh" | cut -d' ' -f1)
    run env STUB_ANSWER=$'VERDICT: masking\nREASON: the probe failure is hidden from the caller here' \
        "$PY" "$DRIVER" "$TOOL" --repo "$FIXTURE" --endpoint "$DEAD_ENDPOINT" --limit 0
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"MASKING CANDIDATES (ratify or reject)  2"* ]]
    [[ "$output" == *"(human-labelled benign)"* ]]
    _after=$(sha256sum "$FIXTURE/scripts/01-fixture.sh" | cut -d' ' -f1)
    [[ "$_before" == "$_after" ]]
}

# end of file
