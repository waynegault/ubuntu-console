import json
import os
import re
import sys

from .core import (
    EXIT_CANNOT_RUN, EXIT_CLEAN, EXIT_DRIFT, READ_BACK_REASON_MIN,
    _CheckerOptions, read_baseline, read_lines,
)

# ── subcommand: swallows ────────────────────────────────────────────────────
# REF: "Coding Agents Keep Shipping Silent Failures — Here Is How to Catch Them"
#      (TDS, 2026-09-18) —
#      https://towardsdatascience.com/coding-agents-keep-shipping-silent-failures-here-is-how-to-catch-them/
#
# TOOLING HALF ONLY (card item 2).  Silent swallows are unclassified and heavy in
# the mutating modules.  Reclassifying the existing corpus is a separate pass that
# collides with files another session owns, so this subcommand does the
# count-ratchet job the repo already uses for exactly this situation
# (tools/count-ratchet.sh): the existing population is RECORDED, a NEW unclassified
# swallow is a FAILURE, and the baseline shrinks as sites are classified.
#
# DEFERRED, not attempted here (each lives in a reserved file or a later pass):
# card item 1 (read-back assertions before a success echo on model start/stop/
# switch, vault load, orphan clean, gog auth), item 3 (stale-telemetry badges in
# the dashboard render) and item 4 (injected-failure BATS cases for them).
SWALLOWS_MARKER = re.compile(r"#\s*swallow-ok:\s*(\S.*)$")
SWALLOW_PATTERNS = (("|| true", re.compile(r"\|\|\s*true\b")),
                    ("2>/dev/null", re.compile(r"2>\s*/dev/null")))
SWALLOWS_SCOPE = "scripts/*.sh, bin/*, tools/*.sh, tools/hooks/*, tools/qwen-hooks/*, nas/**/*.sh"
# Files another session owns during the tooling pass: reported with their counts,
# never edited here, so the second pass has a starting point.
SWALLOWS_RESERVED = {
    "scripts/11e-llm-model.sh": "start/stop read-backs landed (tests/unit/25-*.bats); its sites stay unclassified, which the baseline permits",
    "scripts/09d-oc-agents.sh": "reported only this pass",
    "scripts/08-maintenance.sh": "reported only: 5 pre-existing sites, untouched by the docker-prune fix (commit 39f2fb08)",
    "scripts/11d-llm-gpu.sh": "reported only this pass",
}


def swallow_sites(text):
    """[(line number, pattern name)] for every swallow site in a file's text.

    Comment-only lines are excluded; a site inside a TRAILING comment on a code
    line still counts (a deliberate over-count that keeps the counter simple and
    stable, which is what a ratchet needs).  A marker reason must therefore not
    spell a pattern itself.
    """
    sites = []
    for number, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        for name, pattern in SWALLOW_PATTERNS:
            sites.extend([(number, name)] * len(pattern.findall(line)))
    return sites


def swallow_markers(text):
    """{line number: reason} for every `# swallow-ok: <reason>` marker.

    The marker is ONE comment line, and it classifies a site on its own line or on
    the line DIRECTLY below it.  Deliberately not "somewhere in the comment block
    above": a stale explanation three lines up would then silence a new swallow
    silently, which is the whole failure class this check exists to catch.  A
    wrapped marker therefore does not count — put the reason on one line and keep
    any longer explanation in the comment lines above it.
    """
    markers = {}
    for number, line in enumerate(text.splitlines(), 1):
        match = SWALLOWS_MARKER.search(line)
        if match:
            markers[number] = match.group(1).strip()
    return markers


def swallow_corpus(repo):
    """[(rel, abs)] for every shell file the swallow check scans.

    WIDENED 2026-09-24, from `scripts/*.sh` alone.  bin/ and tools/ are shell too, and
    excluding them made the reported population a PARTIAL figure — this check's own
    output said so ("the same counts outside scripts/*.sh are not scanned") — and a
    partial count cannot be ratcheted against honestly.  tools/hooks/* is in for the
    same reason: those files ARE shell, so an unscanned hook is an unmeasured decision.

    WIDENED AGAIN 2026-10-02: `nas/**/*.sh`.  The NAS (butler) tooling is mirrored into this
    repo at nas/butler/ and is shell, so leaving it out was the same unmeasured decision.  It
    is the ONE group that needs a RECURSIVE walk — its files sit two levels down (nas/butler/
    scripts/…), which a single listdir of `nas/` can never reach.  Every site in that tree was
    classified BEFORE this landed, so the baseline gains no row.

    WIDENED AGAIN 2026-10-02 (card b55c77f5): `tools/qwen-hooks/*`.  The Qwen hook set lives
    under tools/ but one listdir of `tools/` never reaches a subdirectory, so — with `tools`
    non-recursive — those files were scanned by neither this gate nor tools/lint.sh's
    whole-tree loops.  Every site was classified before this landed, so the baseline gains no
    row.

    Returns `(corpus, missing)` where `missing` is the (sub, base) of every CONFIGURED group
    whose directory is absent (card 74051862).  A missing group used to be skipped silently,
    so its baseline rows read STALE (non-fatal) and a whole vanished group passed as a fix.
    """
    groups = (("scripts", True, False), ("bin", False, False), ("tools", True, False),
              ("tools/hooks", False, False), ("tools/qwen-hooks", False, False),
              ("nas", True, True))
    corpus = []
    missing = []
    for sub, only_sh, recursive in groups:
        base = os.path.join(repo, sub)
        if not os.path.isdir(base):
            missing.append((sub, base))
            continue
        if recursive:
            for dirpath, dirnames, filenames in os.walk(base):
                dirnames[:] = sorted(d for d in dirnames if not d.startswith("."))
                for entry in sorted(filenames):
                    if entry.startswith("."):
                        continue
                    if only_sh and not entry.endswith(".sh"):
                        continue
                    full = os.path.join(dirpath, entry)
                    corpus.append((os.path.relpath(full, repo), full))
            continue
        for entry in sorted(os.listdir(base)):
            if entry.startswith("."):
                continue
            path = os.path.join(base, entry)
            if not os.path.isfile(path):
                continue
            if only_sh and not entry.endswith(".sh"):
                continue
            corpus.append((f"{sub}/{entry}", path))
    return corpus, missing


def run_swallows(repo, options: _CheckerOptions):
    """Record and ratchet the unclassified silent swallows in the shell corpus."""
    # `--dump-sites` is the machine-readable form of this subcommand's population
    # (card SPLIT-CONTRACT-TRIAGE-001): one JSON object per site, so a consumer —
    # tools/swallow-classify.py — reads the SAME sites this check counts instead of
    # re-grepping the corpus with a second scanner that could disagree.  It is
    # read-only and never a verdict: every line of stdout is JSONL, the human-facing
    # summary goes to stderr, and the exit code is clean even when sites are
    # unclassified (this is a dump, not a check).
    dump = options["dump_sites"]
    if dump:
        sys.stderr.write(f"=== Silent-swallow site dump ({SWALLOWS_SCOPE}) ===\n")
    else:
        print(f"=== Silent-swallow check ({SWALLOWS_SCOPE}) ===")
    corpus, missing_groups = swallow_corpus(repo)
    if not corpus:
        sys.stderr.write("check-contracts: no shell files found for the swallow check — nothing "
                         "to scan, and an empty scan is not a clean tree. Refusing to pass.\n")
        return EXIT_CANNOT_RUN
    baseline = read_baseline(repo, "tools/contracts-swallows-baseline.tsv")
    known = {}
    for key, detail in baseline.items():
        if key.startswith("unclassified\t"):
            known[key.split("\t", 1)[1]] = detail

    # A configured group whose directory is absent is a coverage loss, not a clean
    # tree (card 74051862).  Without this it was skipped silently, so its baseline rows
    # read STALE (non-fatal) and a whole vanished group passed as the fix that removed
    # its sites.  A group the baseline knows about is a FAIL (blocking); a group with no
    # baseline rows has nothing to lose and is only a named WARNING, so a partial
    # fixture tree stays usable with --repo.
    group_fail: list[str] = []
    group_warn: list[str] = []
    for sub, base in missing_groups:
        covered = any(rel.startswith(sub + "/") for rel in known)
        line = (f"  {'FAIL' if covered else 'WARNING'}  group '{sub}': configured for the "
                f"swallow corpus but {os.path.relpath(base, repo)}/ is not a directory — a "
                f"whole group was NOT scanned")
        (group_fail if covered else group_warn).append(line)

    problems = []
    rows = []
    site_rows = []
    for rel, _path in corpus:
        text = read_lines(repo, rel)
        if text is None:
            problems.append(f"  FAIL  {rel}: cannot be read")
            continue
        sites = swallow_sites(text)
        markers = swallow_markers(text)
        lines = text.splitlines()
        classified = 0
        occurrence: dict = {}
        for number, pattern_name in sites:
            reason = markers.get(number)
            source = "same-line" if reason is not None else None
            if reason is None and number - 2 >= 0:
                previous = lines[number - 2].strip()
                above = SWALLOWS_MARKER.search(previous) if previous.startswith("#") else None
                if above:
                    reason = above.group(1).strip()
                    source = "line-above"
            if reason is not None and len(reason) < 8:
                problems.append(f"  FAIL  {rel}:{number}: `# swallow-ok:` needs a reason, not "
                                f"'{reason}' — a marker with no reason is a marker no reviewer "
                                f"can weigh")
            if reason:
                classified += 1
            if dump:
                # The matched TEXT, not just the pattern's name: a pattern can match a
                # longer spelling (`||    true`), and the consumer quotes what was
                # matched.  `occurrence` keeps rows distinct when one line carries the
                # same pattern twice, which the site count above also counts twice.
                key = (number, pattern_name)
                occurrence[key] = occurrence.get(key, 0) + 1
                matched = next(p.search(lines[number - 1]) for name, p in SWALLOW_PATTERNS
                               if name == pattern_name)
                site_rows.append({
                    "file": rel,
                    "line": number,
                    "pattern": pattern_name,
                    "match": matched.group(0) if matched else pattern_name,
                    "occurrence": occurrence[key],
                    "text": lines[number - 1].strip(),
                    "classified": bool(reason),
                    "reason": reason,
                    "reason_source": source,
                    "reason_weighable": bool(reason) and len(reason) >= READ_BACK_REASON_MIN,
                })
        unclassified = len(sites) - classified
        rows.append((rel, len(sites), classified, unclassified))

    if dump:
        for site_row in site_rows:
            print(json.dumps(site_row, sort_keys=True))
        # stderr, so the JSONL on stdout stays parseable.
        for line in group_fail + group_warn:
            sys.stderr.write(line.lstrip() + "\n")
        sys.stderr.write(
            f"check-contracts[dump-sites]: {len(site_rows)} site(s) in {len(rows)} file(s) — "
            f"{sum(1 for row in site_rows if row['classified'])} classified, "
            f"{sum(1 for row in site_rows if not row['classified'])} unclassified "
            f"(read-only; the exit code is not a verdict)\n")
        return EXIT_CLEAN

    new_sites = []
    seen = set()
    if options["print_baseline"]:
        print("# paste-ready rows for tools/contracts-swallows-baseline.tsv — the measured "
              "population:")
        for rel, _total, _classified, unclassified in rows:
            if unclassified:
                print(f"unclassified\t{rel}\t{unclassified}")
        for line in group_fail + group_warn:
            sys.stderr.write(line.lstrip() + "\n")
        return EXIT_CLEAN
    for rel, total, _classified, unclassified in rows:
        if unclassified == 0:
            continue
        if rel in known:
            seen.add(rel)
            if unclassified > int(known[rel]):
                new_sites.append(f"  FAIL  {rel}: {unclassified} unclassified swallow(s) against "
                                 f"a baseline of {known[rel]} — a NEW swallow needs a reason: "
                                 f"mark it `# swallow-ok: <why>`, or fix the swallow")
        else:
            new_sites.append(f"  FAIL  {rel}: {unclassified} unclassified swallow(s) and no "
                             f"baseline row. Mark each one on its own line or the line")
            new_sites.append("        directly above it (`# swallow-ok: <one-line reason>`), or "
                             "record the count in")
            new_sites.append("        tools/contracts-swallows-baseline.tsv as a deliberate act")
    problems.extend(new_sites)
    problems.extend(group_fail)

    stale = [rel for rel in known
             if rel not in {row[0] for row in rows}
             or next((r[3] for r in rows if r[0] == rel), 0) < int(known[rel])]
    for rel in stale:
        print(f"  STALE     {rel}: fewer unclassified swallow(s) than the baseline "
              f"({known[rel]}) — lower or delete the row in "
              f"tools/contracts-swallows-baseline.tsv")
    for line in group_warn:
        print(line)

    total_sites = sum(row[1] for row in rows)
    total_classified = sum(row[2] for row in rows)
    total_unclassified = sum(row[3] for row in rows)
    heaviest = sorted([row for row in rows if row[3]], key=lambda row: -row[3])[:6]
    print(f"  {len(rows)} file(s) scanned: {total_sites} site(s), {total_classified} classified "
          f"(`# swallow-ok:`), {total_unclassified} unclassified across "
          f"{sum(1 for row in rows if row[3])} file(s)")
    for rel, total, classified, unclassified in heaviest:
        note = SWALLOWS_RESERVED.get(rel)
        suffix = f"   <- {note}" if note else ""
        print(f"  HEAVIEST  {rel}: {total} site(s), {classified} classified, "
              f"{unclassified} unclassified{suffix}")
    per_pattern: dict[str, int] = {}
    for rel, _path in corpus:
        text = read_lines(repo, rel)
        if text is None:
            continue
        for name, pattern in SWALLOW_PATTERNS:
            hits = sum(1 for line in text.splitlines() if not line.lstrip().startswith("#")
                       and pattern.search(line))
            per_pattern[name] = per_pattern.get(name, 0) + hits
    print("  line counts (the card's `grep -c` figures, comments excluded): "
          + ", ".join(f"{name}: {count}" for name, count in sorted(per_pattern.items())))

    for problem in problems:
        print(problem)
    summary = (f"{total_sites} site(s) in {len(rows)} file(s) | {total_classified} classified | "
               f"{total_unclassified} unclassified | {len(known)} baseline row(s)")
    if problems:
        print(f"check-contracts[swallows]: FAIL — {len(problems)} finding(s). {summary}")
        print("  A new `|| true` or `2>/dev/null` is a decision: either the failure is genuinely")
        print("  optional (say why with `# swallow-ok: <reason>` on the site or the line above)")
        print("  or it is a swallow that hides a real failure. The baseline records the")
        print("  population measured on 2026-09-23; it may FALL freely, never rise unnoticed.")
        return EXIT_DRIFT
    print(f"check-contracts[swallows]: OK — {summary}")
    print("  Enforced: no NEW unclassified swallow, and every `# swallow-ok:` marker carries a")
    print("  reason. Reported, not enforced: the existing unclassified population (recorded in")
    print("  tools/contracts-swallows-baseline.tsv, printed above with the heaviest files).")
    print("  Enforced for EVERY file in the corpus above.  Not scanned: tests/ (test")
    print("  fixtures, not shipped code) and the root-level loaders (env.sh,")
    print("  tactical-console.bashrc, install.sh) — adding those is a separate decision.")
    return EXIT_CLEAN
