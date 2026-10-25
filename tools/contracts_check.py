"""Enforce the console's contracts. See the script header for scope per subcommand."""
import os
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if REPO_ROOT not in sys.path:
    sys.path.insert(0, REPO_ROOT)

from tools.contracts_checkers.core import (  # noqa: E402 - repo root must be on sys.path first
    EXIT_CANNOT_RUN, EXIT_CLEAN, SUBCOMMANDS, USAGE, _CheckerOptions,
)
from tools.contracts_checkers.continuity import run_continuity  # noqa: E402 - sys.path bootstrap above
from tools.contracts_checkers.derived import run_derived  # noqa: E402 - sys.path bootstrap above
from tools.contracts_checkers.modules import run_modules  # noqa: E402 - sys.path bootstrap above
from tools.contracts_checkers.state import run_state  # noqa: E402 - sys.path bootstrap above
from tools.contracts_checkers.swallows import run_swallows  # noqa: E402 - sys.path bootstrap above

# ── argument parsing ────────────────────────────────────────────────────────
def parse_args(argv):
    """Return selected checks, repo, positionals, and options for this invocation.

    A positional argument is a command name for `continuity` ("what still applies
    to this command?").  It is only accepted with that subcommand selected, so a
    typo'd subcommand cannot be mistaken for a command name and slip through.
    """
    options: _CheckerOptions = {"print_baseline": False, "dump_sites": False}
    selected = []
    positionals = []
    repo = REPO_ROOT
    index = 0
    while index < len(argv):
        arg = argv[index]
        if arg == "--repo":
            if index + 1 >= len(argv):
                sys.stderr.write("check-contracts: --repo needs a path\n")
                return EXIT_CANNOT_RUN, None, None, None, options
            repo = argv[index + 1]
            index += 2
            continue
        if arg == "--print-baseline":
            # Read-only: prints the rows the recorded baseline would need, so the
            # deliberate act of recording is a paste rather than a guess.  It never
            # writes the file.
            options["print_baseline"] = True
            index += 1
            continue
        if arg == "--dump-sites":
            # Read-only JSONL dump of the swallow SITES (card SPLIT-CONTRACT-TRIAGE-001):
            # the machine-readable form of the population this subcommand counts, so a
            # consumer never re-greps with a second scanner that could disagree.
            options["dump_sites"] = True
            index += 1
            continue
        if arg in ("-h", "--help"):
            print(USAGE)
            return EXIT_CLEAN, None, None, None, options
        if arg in SUBCOMMANDS:
            selected.append(arg)
            index += 1
            continue
        if arg.startswith("-"):
            sys.stderr.write(f"check-contracts: unknown option '{arg}'\n\n{USAGE}\n")
            return EXIT_CANNOT_RUN, None, None, None, options
        positionals.append(arg)
        index += 1
    if not selected:
        if positionals:
            # Keep the plain "unknown argument" wording (a typo'd subcommand is the
            # common case) and add the one thing that disambiguates it.
            sys.stderr.write(
                f"check-contracts: unknown argument '{positionals[0]}'\n"
                "  A COMMAND name is only accepted with the `continuity` subcommand, e.g.\n"
                "  `check-contracts.sh continuity model use`.\n\n" + USAGE + "\n")
            return EXIT_CANNOT_RUN, None, None, None, options
        selected = list(SUBCOMMANDS)
    if positionals and "continuity" not in selected:
        sys.stderr.write(
            f"check-contracts: unexpected argument(s) {' '.join(positionals)} — a COMMAND name\n"
            "  is only meaningful for `continuity`.\n")
        return EXIT_CANNOT_RUN, None, None, None, options
    if options["dump_sites"]:
        # The dump is a machine-readable stream: mixing it with the baseline print or
        # with another subcommand's prose would make the JSONL unparseable, so the
        # combination is refused rather than half-honoured.  A bare invocation narrows
        # to `swallows` for the same reason.
        if options["print_baseline"]:
            sys.stderr.write("check-contracts: --dump-sites and --print-baseline are two "
                             "read-only modes for the same population — pass one.\n")
            return EXIT_CANNOT_RUN, None, None, None, options
        if "swallows" not in selected and selected != list(SUBCOMMANDS):
            sys.stderr.write("check-contracts: --dump-sites is only meaningful with the "
                             "`swallows` subcommand.\n")
            return EXIT_CANNOT_RUN, None, None, None, options
        selected = ["swallows"]
    return None, selected, repo, positionals, options


def run_selected(selected, repo, positionals, options: _CheckerOptions):
    """Dispatch each requested subcommand; return the worst exit code."""
    worst = EXIT_CLEAN
    arms = {
        "state": lambda: run_state(repo),
        "modules": lambda: run_modules(repo, options),
        "derived": lambda: run_derived(repo),
        "continuity": lambda: run_continuity(repo, positionals),
        "swallows": lambda: run_swallows(repo, options),
    }
    for name in selected:
        arm = arms.get(name)
        if arm is None:
            sys.stderr.write(f"check-contracts: subcommand '{name}' has no implementation\n")
            worst = max(worst, EXIT_CANNOT_RUN)
            continue
        # The blank separator is for a human reading prose; in `--dump-sites` mode it
        # would be a non-JSON line on stdout and break the stream contract.
        if not options["dump_sites"]:
            print("")
        worst = max(worst, arm())
    return worst


# `_run_subcommand` is the single entry point for both paths below: SUBCOMMANDS +
# run_selected() are the extension points named in the header, and a new
# subcommand needs nothing else.
def _run_subcommand(argv):
    """Parse argv and run the selected subcommands."""
    code, selected, repo, positionals, options = parse_args(argv)
    if code is not None:
        return code
    if repo and not os.path.isdir(repo):
        sys.stderr.write(f"check-contracts: --repo {repo} is not a directory\n")
        return EXIT_CANNOT_RUN
    return run_selected(selected, repo, positionals, options)


def main(argv=None):
    """Run the selected subcommands and return the process exit code.

    *argv* defaults to this process's arguments after the program name — the repo
    root, then the subcommand options — which is exactly what the wrapper passes.
    """
    global REPO_ROOT
    args = list(sys.argv[1:] if argv is None else argv)
    REPO_ROOT = args[0]
    return _run_subcommand(args[1:])




if __name__ == "__main__":
    sys.exit(main())
