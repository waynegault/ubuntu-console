#!/usr/bin/env python3
"""PostToolUse hook (matcher: ^run_shell_command$): advisory scan of the COMMAND TEXT.

WHY THIS EXISTS.  A stdin-reading tool invoked with no operand blocks until the
tool's own timeout, and that timeout is minutes.  Measured 2026-09-29: a shell
command `markdownlint "$note"` whose variable had expanded to the empty string
passed no filename, so markdownlint read stdin and hung for the full 120 s tool
timeout.  The empty-variable shape is not statically detectable, but the COMMAND
SHAPE that results from it is exactly this: a stdin-reading tool with no operand.

Do NOT "fix" this by testing the tools with `</dev/null`: they all exit at once
there, because EOF is immediate (measured 2026-09-29 — markdownlint, jq, sqlite3
and cat all exit rc=0).  The hang needs an OPEN stdin, which is what the shell
tool hands a child process, so the hazard is real in THIS environment and
invisible to a redirect-based check.

Scope, deliberately tiny and named (a broad linter list is the alarm class this
repo warns about): the tools that are never useful bare — a linter with no
target, or a REPL.  `cat`, `grep`, `awk` and friends are NOT included: they are
routinely used with stdin from a pipe or a heredoc, and flagging them would train
the reader to ignore this hook.  A tool fed by a pipe in the same command is not
flagged either — its stdin is provided.

Advisory only, never blocks, exit status always 0, prints NOTHING when clean
(same contract as ~/.qwen/hooks/post-edit-check.sh).
"""

from __future__ import annotations

import json
import re
import shlex
import sys

#: Tools that block on an open stdin and are never useful without an operand here.
RISKY_TOOLS = frozenset({"markdownlint", "jq", "sqlite3", "python", "python3", "node"})

#: Wrappers stripped before the tool name is read (env assignments too).
_LEADING_WRAPPERS = frozenset({"sudo", "time", "nice", "command", "exec", "env"})
_ENV_ASSIGNMENT_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")

#: Shell separators that start a new simple command; `|` is kept SEPARATE because a
#: command to its right has its stdin provided by the pipe.
_SEPARATOR_RE = re.compile(r"(&&|\|\||;|\n|\|)")


#: Flags that SUPPLY the program to an interpreter, so stdin is not being read:
#: `python3 -c '…'`, `python3 -m pytest`, `python3 -` (program on stdin by design),
#: `node -e '…'`.  Without these, `python3 -m pytest tests/` would be flagged.
_PROGRAM_FLAGS = frozenset({"-c", "-m", "-e", "--eval", "--command", "-"})

#: Flags that make the tool print and exit without reading stdin (`--version`, `--help`).
_INFO_FLAGS = frozenset({"-v", "--version", "-V", "-h", "--help"})

#: Tools that consume a FILE target: a bare or variable-only operand is the hazard.
_LINTER_TOOLS = frozenset({"markdownlint", "jq", "sqlite3"})

#: Tools whose bare form is an interactive REPL.  A variable operand is NOT a hazard
#: for these (`python3 "$script"` runs a file; an empty expansion errors rather than
#: blocking), so only a completely argument-less invocation is flagged.
_REPL_TOOLS = frozenset({"python", "python3", "node"})

#: A redirection token (`>`, `>>`, `2>`, `2>&1`, `&>`, `<`) is not an operand.
_REDIRECT_RE = re.compile(r"^\d*[<>]|^&>")

#: A shell variable reference — `$note`, `${note}`.  shlex does not expand it, so an
#: operand that is ONLY a variable may expand to the empty string, which is exactly
#: how `markdownlint "$note"` passed no filename and read stdin.
_VAR_ONLY_RE = re.compile(r"^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?$")

#: Stateful git commands whose EXIT STATUS is the evidence: a commit can fail loudly
#: or succeed silently, and nothing else in the output says which happened.
_GIT_STATEFUL_RE = re.compile(r"\b(?:git\s+(?:commit|push)\b|git_commit\.sh\b)")


def _masked_exit_findings(command: str) -> list[str]:
    """Segments that are a stateful git command on the LEFT side of a pipe.

    WHY: a pipeline's exit status is its LAST command's, so `git_commit.sh … | tail`
    reports `tail`'s status.  Measured 2026-09-29: two commit attempts were read as
    "exit 0" through that pipe while the wrapper had actually returned 1, which hid
    a mypy failure and cost two full ~9-minute hook chains before the cause was
    seen.  A REDIRECT (`> log 2>&1`) is not flagged — the status still reaches the
    caller.
    """
    parts = _SEPARATOR_RE.split(command)
    masked: list[str] = []
    for index in range(0, len(parts), 2):
        segment = parts[index].strip()
        separator = parts[index + 1] if index + 1 < len(parts) else None
        if segment and separator == "|" and _GIT_STATEFUL_RE.search(segment):
            masked.append(segment[:80])
    return masked


def _split_simple_commands(command: str) -> list[tuple[str, bool]]:
    """Return (segment, piped_in) pairs.

    ``piped_in`` is True when the segment sits to the RIGHT of a pipe, so its
    stdin comes from the pipeline rather than from the terminal.
    """
    segments: list[tuple[str, bool]] = []
    for index, part in enumerate(_SEPARATOR_RE.split(command)):
        if index % 2 == 1:  # the separator itself
            continue
        stripped = part.strip()
        if not stripped:
            continue
        # `bool(...)` rather than the bare `and` chain: the chain's value is the last
        # operand, so `command and …` yields the EMPTY STRING when the command is empty
        # — a `str` in a field declared `bool`, which is what the type checker refused.
        piped_in = bool(
            index > 0 and command and _SEPARATOR_RE.split(command)[index - 1] == "|"
        )
        segments.append((stripped, piped_in))
    return segments


def _tool_and_operand(segment: str) -> tuple[str, bool] | None:
    """Return (tool basename, reads_stdin) for a segment, or None if it is not one.

    ``reads_stdin`` is False — i.e. not a hazard — when the segment supplies an
    operand, a program flag (`-c`/`-m`/`-e`/`-`), an info flag (`--version`), or a
    heredoc (which provides stdin).
    """
    try:
        tokens = shlex.split(segment, comments=False)
    except ValueError:
        tokens = segment.split()
    if not tokens:
        return None
    while tokens and (
        tokens[0].rsplit("/", 1)[-1] in _LEADING_WRAPPERS or _ENV_ASSIGNMENT_RE.match(tokens[0])
    ):
        tokens.pop(0)
    if not tokens:
        return None
    tool = tokens[0].rsplit("/", 1)[-1]
    if tool not in RISKY_TOOLS:
        return None
    rest = tokens[1:]
    if "<<" in segment:  # a heredoc supplies stdin
        return tool, False
    if any(arg in _PROGRAM_FLAGS or arg in _INFO_FLAGS for arg in rest):
        return tool, False
    operands = [
        arg for arg in rest if not arg.startswith("-") and not _REDIRECT_RE.match(arg)
    ]
    if tool in _REPL_TOOLS:
        # Only a completely bare invocation is a REPL that would block.
        return tool, not rest
    # A linter with no operand, or with ONLY variable references as operands, may
    # receive no filename at all once the shell expands them.
    variable_only = bool(operands) and all(_VAR_ONLY_RE.match(arg) for arg in operands)
    return tool, (not operands) or variable_only


def main() -> int:
    raw = sys.stdin.read()
    try:
        payload = json.loads(raw)
    except (ValueError, TypeError):
        return 0
    tool_input = payload.get("tool_input") or {}
    command = tool_input.get("command") or ""
    if not isinstance(command, str) or not command.strip():
        return 0

    stdin_findings: list[str] = []
    for segment, piped_in in _split_simple_commands(command):
        parsed = _tool_and_operand(segment)
        if parsed is None:
            continue
        tool, reads_stdin = parsed
        if not reads_stdin or piped_in:
            continue
        stdin_findings.append(tool)

    masked = _masked_exit_findings(command)
    if not stdin_findings and not masked:
        return 0

    if stdin_findings:
        print("shell-command-check: a stdin-reading tool was invoked with no operand.")
        for tool in stdin_findings:
            print(
                f"  `{tool}` with no file/target argument reads STDIN and blocks until the "
                "tool's own timeout (measured: markdownlint hung for the full 120 s this way "
                "on 2026-09-29) — verify the operand is non-empty (e.g. guard with "
                "`[ -n \"$var\" ] || exit 0`, or pass an explicit path/glob)."
            )
        print("  (advisory only; a pipe into the tool, or a deliberate REPL, is fine.)")
    if masked:
        print("shell-command-check: a stateful git command is piped, so its EXIT STATUS is masked.")
        for segment in masked:
            print(f"  `{segment}` — this pipeline's status is the LAST command's, not the "
                  "commit's/push's, so a failure reads as success (measured 2026-09-29: two "
                  "commit attempts read 'exit 0' from `| tail` while the wrapper returned 1). "
                  "Run it unpiped, or use `set -o pipefail` / `${PIPESTATUS[0]}`.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
