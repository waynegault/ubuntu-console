#!/usr/bin/env python3
"""swallow-classify — PROPOSE `# swallow-ok:` reasons for swallow sites.  It never gates.

THE GAP THIS CLOSES (card SPLIT-CONTRACT-TRIAGE-001).  tools/check-contracts.sh's
`swallows` subcommand already enforces the count: no NEW unclassified `|| true` /
`2>/dev/null` site, and every classified site carries a human reason.  What is still
the reader's job is the DECISION — a human writes `# swallow-ok: <why>`.  This tool
asks a local model the one narrow question per site ("is this swallow deliberate and
benign, or is it hiding a failure?") and assembles the verdicts IN CODE, so the
decision arrives as a PROPOSAL.

WHAT IT IS NOT.  It is not a gate.  Nothing passes or fails on model output: the
deterministic count/baseline in `swallows` remains the only enforcement (Wayne's
ruling, 2026-09-29).  The tool never edits the corpus — it writes a report — and
`--labels` is a self-check for the battery, never a verdict on the tree.

THE ORDER IS THE POINT.  `--baseline-only` measures the HUMAN baseline with no model
call at all; the model comparison is a separate run of the same tool.  The baseline
is the existing `# swallow-ok:` reasons, which are free ground truth: a marker is a
human saying "this swallow is deliberate", so the human verdict is BENIGN for every
classified site, and the corpus carries no negative label at all.  That is why the
masking side of the comparison cannot come from existing data: the model NOMINATES
the masking candidates and a human ratifies them, and the falsification direction is
proven by a seeded fixture in tests/unit/35-swallow-classify.bats, not by a
fabricated production label.

SITES COME FROM THE CHECKER, NOT FROM A SECOND SCANNER.  The population is read
through `tools/check-contracts.sh swallows --dump-sites` (JSONL), so this tool and
the check that enforces the count cannot disagree about what a site is.  The asked
unit is the unique site LINE: the checker counts SITES (`2>/dev/null || true` on one
line is two hits), a line's hits share one text and one marker, and the report prints
both figures (at HEAD: 1136 hits on 880 unique lines) so the smaller asking pool is
visible.

THE LANE.  A model server on loopback, by default the qwen2.5-3b CPU lane at
http://127.0.0.1:18084 (override with `--endpoint` or $SWALLOW_CLASSIFY_ENDPOINT);
the model NAME is read from that endpoint's /v1/models, never hardcoded.  No hosted
API is called.  Loopback only, and every request carries a timeout.

RUNNING IT:
    # 1. the human baseline — deterministic, no model, safe to run anywhere
    .venv/bin/python3 tools/swallow-classify.py --baseline-only

    # 2. the labelled sample first: the 20 classified sites, model compared to humans
    .venv/bin/python3 tools/swallow-classify.py --only classified --limit 20

    # 3. the full proposal run against the lane (this is the ratification report)
    .venv/bin/python3 tools/swallow-classify.py --limit 0 --out /tmp/swallow-proposal.txt

EXIT: 0 report produced (or `--baseline-only`) · 1 a `--labels` disagreement (the
      battery's self-check; never reached without --labels) · 2 cannot run (the
      checker failed, the endpoint did not answer, a report line did not parse).

REF: "Coding Agents Keep Shipping Silent Failures — Here Is How to Catch Them"
     (TDS, 2026-09-18) — the swallow class this tool proposes reasons for —
     https://towardsdatascience.com/coding-agents-keep-shipping-silent-failures-here-is-how-to-catch-them/
REF: "Towards Spec-Driven Test Automation: Part 1" (Gal Arav, TDS, 2026-09-24) — the
     baseline-then-compare ordering and the seeded-fault falsification direction —
     https://towardsdatascience.com/towards-spec-driven-test-automation-part-1/
"""

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

# The site scanner lives in the checker; this tool reads its JSONL dump so the two
# can never disagree about what a site is (see the module docstring).
TOOL_DIR = os.path.dirname(os.path.abspath(__file__))
CHECKER = os.path.join(TOOL_DIR, "check-contracts.sh")
DUMP_TIMEOUT = 300.0
DEFAULT_ENDPOINT = "http://127.0.0.1:18084"
ENDPOINT_ENV = "SWALLOW_CLASSIFY_ENDPOINT"
VERDICTS = ("benign", "masking")
# The same 8-character floor the corpus marker uses: a reason a reviewer can weigh.
REASON_MIN = 8
HTTP_TIMEOUT_DEFAULT = 60.0
# One narrow, typed question.  Deliberately neutral between the two answers (an
# example verdict would bias a 3B model), and deliberately about ONE site: the
# assembled verdict is code's job, not the model's.
PROMPT = (
    "You are auditing ONE line of a bash script for a silent failure.\n"
    "\n"
    "line: {text}\n"
    "swallow(s) on it: {patterns}\n"
    "\n"
    "benign  = the failure is deliberately ignored (an optional probe, a best-effort\n"
    "          cleanup, or a value whose absence the caller checks for).\n"
    "masking = it hides a failure the code should surface (a step whose error is\n"
    "          discarded, so the next line runs on a broken premise).\n"
    "\n"
    "Answer with exactly two lines and nothing else:\n"
    "VERDICT: <benign or masking>\n"
    "REASON: <one line, at most 120 characters, naming the failure that is ignored or hidden>\n"
)
VERDICT_RE = re.compile(r"^VERDICT:\s*(\S+)", re.IGNORECASE)
REASON_RE = re.compile(r"^REASON:\s*(\S.*)$", re.IGNORECASE)


def parse_args(argv):
    """The CLI.  Defaults are the safe ones: no full sweep, no model call to measure."""
    parser = argparse.ArgumentParser(
        prog="swallow-classify.py",
        description="Propose `# swallow-ok:` reasons for swallow sites (never a gate).",
    )
    parser.add_argument("--repo", default=None,
                        help="checkout to read (default: the repo this tool lives in)")
    parser.add_argument("--endpoint", default=None,
                        help=f"loopback model base URL (default ${ENDPOINT_ENV} or "
                             f"{DEFAULT_ENDPOINT})")
    parser.add_argument("--model", default=None,
                        help="model name; by default read from the endpoint's /v1/models")
    parser.add_argument("--limit", type=int, default=20,
                        help="ask about at most N unique site-lines, classified first "
                             "(0 = every site-line)")
    parser.add_argument("--only", choices=("all", "classified", "unclassified"), default="all",
                        help="restrict which sites are asked about (default: all)")
    parser.add_argument("--baseline-only", action="store_true",
                        help="print the deterministic human baseline and make NO model call")
    parser.add_argument("--labels", default=None,
                        help="TSV `file:line<TAB>benign|masking`: the model's verdict must "
                             "agree with every row, or the run exits 1 (a self-check for the "
                             "battery; never a verdict on the tree)")
    parser.add_argument("--out", default=None, help="write the report here (default: stdout)")
    parser.add_argument("--timeout", type=float, default=HTTP_TIMEOUT_DEFAULT,
                        help=f"per-request timeout in seconds (default {HTTP_TIMEOUT_DEFAULT:g})")
    parser.add_argument("--dry-run", action="store_true",
                        help="print the prompt for the first site to ask about, then exit")
    return parser.parse_args(argv)


def repo_root(explicit):
    """The checkout to read: --repo, else the repo this tool lives in."""
    if explicit:
        return os.path.abspath(explicit)
    return os.path.dirname(TOOL_DIR)


def endpoint_base(raw):
    """Normalize a base URL: no trailing slash and no duplicated /v1."""
    base = (raw or DEFAULT_ENDPOINT).strip().rstrip("/")
    if base.endswith("/v1"):
        base = base[: -len("/v1")]
    return base


def read_sites(repo):
    """Every swallow site, from the checker's JSONL dump.

    A dump line that does not parse is an ERROR, never a skipped row: a silently
    dropped site would make the report's population smaller than the one the check
    enforces, which is the disagreement this seam exists to prevent.
    """
    if not os.path.isfile(CHECKER):
        raise RuntimeError(f"the site scanner is missing: {CHECKER}")
    completed = subprocess.run(
        [CHECKER, "swallows", "--dump-sites", "--repo", repo],
        capture_output=True, text=True, timeout=DUMP_TIMEOUT, check=False,
    )
    if completed.returncode != 0:
        raise RuntimeError(
            f"`{os.path.relpath(CHECKER, repo)} swallows --dump-sites --repo {repo}` exited "
            f"{completed.returncode}: {completed.stderr.strip()}"
        )
    sites = []
    for number, line in enumerate(completed.stdout.splitlines(), 1):
        if not line.strip():
            continue
        try:
            sites.append(json.loads(line))
        except json.JSONDecodeError as exc:
            raise RuntimeError(f"dump line {number} is not JSON: {exc}: {line[:120]!r}") from exc
    return sites


def http_get_json(url, timeout):
    """One JSON GET.  Module-local on purpose: the battery replaces THIS function.

    Patching this (or `http_post_json`) is the only way the tests touch the network
    layer — never the global `urllib`/`subprocess` modules, so unrelated calls in the
    same process still run and their failures still surface.
    """
    with urllib.request.urlopen(url, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def http_post_json(url, payload, timeout):
    """One JSON POST (the model call the tests replace).  See http_get_json."""
    data = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        url, data=data, headers={"Content-Type": "application/json"}, method="POST"
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def discover_model(endpoint, timeout):
    """The model name, read from the endpoint's /v1/models — never hardcoded."""
    body = http_get_json(endpoint + "/v1/models", timeout)
    entries = body.get("data") or []
    if not entries:
        raise RuntimeError(f"{endpoint}/v1/models listed no model")
    return str(entries[0].get("id") or "").strip() or f"<unnamed at {endpoint}>"


def parse_verdict(text):
    """(verdict, reason) from a model reply; verdict is None when it did not answer.

    Strict and code-side: the verdict must be a VERDICT: line naming one of the two
    values, and the reason a REASON: line long enough to weigh.  A reply that does
    not commit is UNPARSED — never defaulted to benign, because a silent default is
    exactly the success-without-a-write shape this whole subcommand exists to catch.
    """
    verdict = None
    reason = None
    for line in text.splitlines():
        stripped = line.strip()
        if verdict is None:
            match = VERDICT_RE.match(stripped)
            if match:
                candidate = match.group(1).strip().strip(".,;:\"'`*_").lower()
                verdict = candidate if candidate in VERDICTS else None
                continue
        if reason is None:
            match = REASON_RE.match(stripped)
            if match:
                candidate = match.group(1).strip()
                reason = candidate if len(candidate) >= REASON_MIN else None
    if verdict is None:
        return None, reason
    return verdict, reason


def ask_model(site, endpoint, model, timeout):
    """ONE narrow question about ONE site line; the verdict is assembled by the caller."""
    prompt = PROMPT.format(text=site["text"], patterns=", ".join(site["patterns"]))
    payload = {
        "model": model,
        "temperature": 0.0,
        "max_tokens": 96,
        "messages": [{"role": "user", "content": prompt}],
    }
    body = http_post_json(endpoint + "/v1/chat/completions", payload, timeout)
    choices = body.get("choices") or []
    if not choices:
        raise RuntimeError(f"the endpoint returned no choice for {site['file']}:{site['line']}")
    message = choices[0].get("message") or {}
    return parse_verdict(str(message.get("content") or ""))


def site_key(site):
    """`<file>:<line>` — the identity a label file and a report line both use."""
    return f"{site['file']}:{site['line']}"


def merge_site_lines(sites):
    """One entry per unique site LINE, with every pattern on that line.

    The checker counts SITES (a line carrying `2>/dev/null || true` is two hits), but
    the question this tool asks is about the LINE's behaviour — and a line's hits
    share the same text, the same marker and therefore the same classification.  So
    the asked unit is the unique site-line, which keeps `file:line` as the identity
    everywhere (dump, label file, report) and cannot collapse two verdicts into one
    key.  Both figures are printed, so the smaller asking pool is visible, not silent.
    """
    merged = {}
    order = []
    for site in sites:
        key = (site["file"], site["line"])
        if key not in merged:
            merged[key] = {
                "file": site["file"],
                "line": site["line"],
                "text": site["text"],
                "patterns": [],
                "hits": 0,
                "classified": site["classified"],
                "reason": site["reason"],
                "reason_source": site["reason_source"],
                "reason_weighable": site["reason_weighable"],
            }
            order.append(key)
        entry = merged[key]
        entry["hits"] += 1
        if site["pattern"] not in entry["patterns"]:
            entry["patterns"].append(site["pattern"])
    return [merged[key] for key in order]


def ordered_for_asking(sites, only):
    """The asking order: the LABELLED baseline first, then the unclassified sites.

    The card's ordering, made mechanical: a small `--limit` therefore samples the
    human-labelled sites first, so the comparison to the baseline exists before any
    proposal does.  The dump's own order (corpus order) is preserved inside each half.
    """
    if only == "classified":
        return [site for site in sites if site["classified"]]
    if only == "unclassified":
        return [site for site in sites if not site["classified"]]
    labelled = [site for site in sites if site["classified"]]
    unlabelled = [site for site in sites if not site["classified"]]
    return labelled + unlabelled


def baseline_section(sites):
    """The HUMAN baseline — deterministic, model-free, printed before any verdict."""
    classified = [site for site in sites if site["classified"]]
    unclassified = [site for site in sites if not site["classified"]]
    labelled_lines = {(site["file"], site["line"]) for site in classified}
    unlabelled_lines = {(site["file"], site["line"]) for site in unclassified}
    reasons = {site["reason"] for site in classified}
    patterns = {}
    for site in sites:
        patterns[site["pattern"]] = patterns.get(site["pattern"], 0) + 1
    same_line = sum(1 for site in classified if site["reason_source"] == "same-line")
    line_above = sum(1 for site in classified if site["reason_source"] == "line-above")
    unweighable = sum(1 for site in classified if not site["reason_weighable"])
    files_with_sites = len({site["file"] for site in sites})
    lines = [
        f"SITES          {len(sites)} site hit(s) on {len({(s['file'], s['line']) for s in sites})} "
        f"unique site-line(s),",
        f"               in {files_with_sites} file(s) that carry a site",
        f"               {len(classified)} classified · {len(unclassified)} unclassified hit(s)",
        "               patterns: " + ", ".join(f"{name} {count}"
                                              for name, count in sorted(patterns.items())),
        f"HUMAN BASELINE {len(labelled_lines)} classified site-line(s) / {len(classified)} "
        f"classified site-hit(s)",
        f"               {len(reasons)} distinct reason(s); marker placement: {line_above} "
        f"line-above, {same_line} same-line; unweighable reason(s): {unweighable}",
        "               0 masking — this corpus carries no negative label, so BENIGN is the "
        "only human",
        "               verdict a marker can express; the masking side is the model's to "
        "nominate,",
        "               for a human to ratify (never inferred from production data here).",
        f"               {len(unlabelled_lines)} unclassified site-line(s) await a proposal.",
    ]
    return lines


def count_verdicts(asked, verdicts):
    benign = sum(1 for site in asked if verdicts[site_key(site)][0] == "benign")
    masking = sum(1 for site in asked if verdicts[site_key(site)][0] == "masking")
    unparsed = sum(1 for site in asked if verdicts[site_key(site)][0] is None)
    return benign, masking, unparsed


def report_lines(repo, raw_sites, asked, verdicts, endpoint, model):
    """The whole report: baseline, the model comparison, the masking candidates."""
    lines = ["swallow-classify — PROPOSAL report (no gate; the count/baseline in",
             "`check-contracts.sh swallows` is the only enforcement)",
             f"REPO           {repo}",
             ""]
    lines.extend(baseline_section(raw_sites))
    lines.append("")
    benign, masking, unparsed = count_verdicts(asked, verdicts)
    lines.append(f"MODEL          {endpoint} model={model}")
    lines.append(f"               asked {len(asked)} unique site-line(s): {benign} benign · "
                 f"{masking} masking · {unparsed} unparsed (a non-answer is never counted as "
                 f"benign)")
    classified_asked = [site for site in asked if site["classified"]]
    if classified_asked:
        agree = [site for site in classified_asked if verdicts[site_key(site)][0] == "benign"]
        disagree = [site for site in classified_asked if verdicts[site_key(site)][0] == "masking"]
        unknown = [site for site in classified_asked if verdicts[site_key(site)][0] is None]
        lines.append(f"AGREEMENT      on the {len(classified_asked)} classified site-line(s) "
                     f"asked: {len(agree)} agree (model benign, human marker), {len(disagree)} "
                     f"disagree (model masking), {len(unknown)} unparsed")
    candidates = [site for site in asked if verdicts[site_key(site)][0] == "masking"]
    lines.append("")
    lines.append(f"MASKING CANDIDATES (ratify or reject)  {len(candidates)}")
    for site in candidates:
        _verdict, reason = verdicts[site_key(site)]
        origin = "human-labelled benign" if site["classified"] else "unclassified"
        lines.append(f"  {site_key(site)} [{', '.join(site['patterns'])}] ({origin}) "
                     f"{reason or 'model gave no weighable reason'}")
        lines.append(f"      {site['text']}")
    proposals = [site for site in asked if verdicts[site_key(site)][0] == "benign"]
    lines.append("")
    lines.append(f"PROPOSALS (a human accepts or rejects each)  {len(proposals)}")
    for site in proposals:
        _verdict, reason = verdicts[site_key(site)]
        lines.append(f"  {site_key(site)} -> # swallow-ok: {reason or '<no reason yet>'}")
    unparsed_sites = [site for site in asked if verdicts[site_key(site)][0] is None]
    if unparsed_sites:
        lines.append("")
        lines.append(f"UNPARSED (the model did not answer in the required form)  "
                     f"{len(unparsed_sites)}")
        for site in unparsed_sites:
            lines.append(f"  {site_key(site)} [{', '.join(site['patterns'])}] {site['text']}")
    return lines


def read_labels(path):
    """`{(file, line): verdict}` from a TSV.  A malformed row is an error, not a skip."""
    labels = {}
    with open(path, encoding="utf-8") as handle:
        for number, line in enumerate(handle, 1):
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            parts = stripped.split("\t")
            if len(parts) != 2 or parts[1].strip() not in VERDICTS:
                raise RuntimeError(f"{path}:{number}: expected `<file>:<line><TAB>benign|masking`, "
                                   f"got {stripped!r}")
            where = parts[0].strip()
            if not re.match(r"^.+:\d+$", where):
                raise RuntimeError(f"{path}:{number}: `{where}` is not `<file>:<line>`")
            rel, _sep, lineno = where.rpartition(":")
            labels[(rel, int(lineno))] = parts[1].strip()
    return labels


def label_disagreements(labels, asked, verdicts):
    """[(label, model verdict or None, site or None)] for every label the model missed.

    The battery's self-check (card SPLIT-CONTRACT-TRIAGE-001's acceptance): a site the
    model calls benign where the sample says masking is a FAILURE of the comparison.
    An unparsed verdict does NOT agree with a label either — a non-answer cannot pass
    a check that a verdict is supposed to pass.
    """
    asked_index = {(site["file"], site["line"]): site for site in asked}
    disagreements = []
    for key, label in sorted(labels.items()):
        site = asked_index.get(key)
        if site is None:
            disagreements.append((key, label, None, None))
            continue
        verdict = verdicts[site_key(site)][0]
        if verdict != label:
            disagreements.append((key, label, verdict, site))
    return disagreements


def run(argv):
    """Everything except the top-level error handling; returns the exit code."""
    args = parse_args(argv)
    repo = repo_root(args.repo)
    raw_sites = read_sites(repo)
    # The asked unit is the unique site LINE (see merge_site_lines); the baseline
    # reports both figures so the smaller asking pool is visible.
    site_lines = merge_site_lines(raw_sites)

    if args.baseline_only:
        lines = ["swallow-classify — HUMAN BASELINE (no model call)", f"REPO           {repo}", ""]
        lines.extend(baseline_section(raw_sites))
        write_report(args.out, lines)
        return 0

    endpoint = endpoint_base(args.endpoint or os.environ.get(ENDPOINT_ENV))
    pool = ordered_for_asking(site_lines, args.only)
    asked = pool if args.limit <= 0 else pool[: args.limit]
    if not asked:
        raise RuntimeError(f"no site matches --only {args.only}")

    if args.dry_run:
        # Before model discovery on purpose: showing the prompt must not need a lane.
        print(PROMPT.format(text=asked[0]["text"], patterns=", ".join(asked[0]["patterns"])))
        return 0

    model = args.model or discover_model(endpoint, args.timeout)
    verdicts = {}
    for site in asked:
        verdicts[site_key(site)] = ask_model(site, endpoint, model, args.timeout)
    lines = report_lines(repo, raw_sites, asked, verdicts, endpoint, model)

    if args.labels:
        labels = read_labels(args.labels)
        disagreements = label_disagreements(labels, asked, verdicts)
        lines.append("")
        lines.append(f"LABEL CHECK    {args.labels}: {len(labels)} label(s), "
                     f"{len(disagreements)} disagreement(s)")
        for key, label, verdict, site in disagreements:
            where = f"{key[0]}:{key[1]}"
            if site is None:
                lines.append(f"  NOT ASKED  {where} labelled {label} — the label cannot be "
                             f"checked, so the measurement is incomplete")
            else:
                lines.append(f"  MISMATCH   {where} labelled {label}, model said "
                             f"{verdict or 'unparsed'} — an unparsed verdict does not satisfy "
                             f"a label")
        if disagreements:
            lines.append(f"  The comparison FAILED: {len(disagreements)} labelled site(s) "
                         f"disagree with the model.")
    write_report(args.out, lines)
    if args.labels:
        return 1 if disagreements else 0
    return 0


def write_report(path, lines):
    """Print the report, or write it to a file.  A write failure is an error."""
    text = "\n".join(lines) + "\n"
    if not path:
        sys.stdout.write(text)
        return
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)
    sys.stderr.write(f"swallow-classify: report written to {path} ({len(lines)} line(s))\n")


def main(argv=None):
    """Run, converting a cannot-run into exit 2 with the reason on stderr."""
    try:
        return run(sys.argv[1:] if argv is None else argv)
    except (RuntimeError, urllib.error.URLError, TimeoutError, OSError) as exc:
        sys.stderr.write(f"swallow-classify: cannot run: {exc}\n")
        return 2


if __name__ == "__main__":
    sys.exit(main())
