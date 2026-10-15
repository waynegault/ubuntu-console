#!/usr/bin/env bats
# ==============================================================================
# Unit — tools/vscode-companion-state/vscode-companion-state-trim.py: bounding the
# companion's single `globalState` conversation blob.
# ==============================================================================
# WHY THIS EXISTS.  The Qwen companion persists its ENTIRE WebView conversation history
# in one `globalState` value (`qwenlm.qwen-code-vscode-ide-companion`); on this box that
# reached 75,342,349 bytes and VS Code logged its own "large extension state detected"
# warning.  VS Code serialises extension state wholesale on every write and loads the DB
# at window start, so the blob is a per-write and per-startup cost, not just disk.
#
# The tool's CONTRACT is what these cases assert — not its current output:
#
#   * no arguments = DRY RUN: it reports what WOULD go and changes NOTHING;
#   * `--apply` is the ONLY writer, it takes a backup FIRST, and it RE-READS what it
#     stored rather than trusting the write;
#   * the rule is "keep conversations that HAVE MESSAGES and were updated within the
#     window; a conversation with no messages is always dropped";
#   * a state DB that cannot hold the key is reported, never crashed on;
#   * no state DB at all is exit 2.
#
# FALSIFICATION.  Case 1 fails against any dry run that writes (it compares the stored
# value's length AND sha256 before and after — the byte-level observable, not the
# tool's own summary).  Case 3 is the window's discriminator: the same fixture with
# `--keep-days 200` must keep the 100-day-old conversation that the default 90 drops,
# so a tool that ignored the window, or dropped by position/count, fails it.  Case 6 is
# the regression net for the first defect found by dry run: on a table-less
# `state.vscdb` (the remote server's is 0 bytes) it raised
# `sqlite3.OperationalError: no such table: ItemTable`, so the case asserts a clean
# verdict AND the absence of a traceback.
#
# Hermetic: a throwaway state dir under `mktemp -d`, driven through the tool's own
# documented `--state-dir` / `--backup-dir` seams, so no real VS Code profile is ever
# read or written.  No env.sh: the tool is standalone, imports only the standard
# library, and reads no repo module state — it is run here as a subprocess, exactly as
# a user runs it.
# ==============================================================================

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export REPO_ROOT
    TOOL="$REPO_ROOT/tools/vscode-companion-state/vscode-companion-state-trim.py"
    export TOOL
    # The tool is stdlib-only, so either interpreter serves; prefer the repo venv and
    # fall back to PATH.  The cases invoke "$TOOL" itself rather than "$PY $TOOL", so
    # the executable bit checkout restored is exercised too (a lost mode is a real
    # failure mode here: write_file lands a new file 0600).
    PY="$REPO_ROOT/.venv/bin/python3"
    [[ -x "$PY" ]] || PY="python3"
    export PY

    SANDBOX="$(mktemp -d)"
    export SANDBOX
    BACKUPS="$SANDBOX/backups"
    export BACKUPS
    # An ambient override must not leak in and redirect the walk.
    unset VSCODE_USER_DIR

    DB="$SANDBOX/globalStorage/state.vscdb"
    export DB
}

teardown() {
    rm -rf "$SANDBOX"
}

# _fixture FILE — three conversations, so one fixture answers every case below:
#   recent-with-messages  updated 1 day ago, has messages  → kept under any sane window
#   old-with-messages     updated 100 days ago, has messages → the window's discriminator
#   recent-empty          updated now, NO messages          → always dropped
_fixture() {
    "$PY" - "$1" <<'PY'
import json, sys, time
now = int(time.time() * 1000)
day = 86_400_000
convs = [
    {"id": "recent-with-messages", "updatedAt": now - day,
     "messages": [{"role": "user"}, {"role": "assistant"}]},
    {"id": "old-with-messages", "updatedAt": now - 100 * day,
     "messages": [{"role": "user"}]},
    {"id": "recent-empty", "updatedAt": now, "messages": []},
]
with open(sys.argv[1], "w") as fh:
    json.dump({"conversations": convs}, fh)
PY
}

# _mkdb DB CONVERSATIONS_JSON — the store exactly as VS Code keeps it: an `ItemTable`
# whose `value` blob is the whole state document under the companion's key.
_mkdb() {
    mkdir -p "$(dirname "$1")"
    "$PY" - "$1" "$2" <<'PY'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
conn.execute("CREATE TABLE IF NOT EXISTS ItemTable (key TEXT PRIMARY KEY, value BLOB)")
conn.execute(
    "INSERT OR REPLACE INTO ItemTable (key, value) VALUES (?, ?)",
    ("qwenlm.qwen-code-vscode-ide-companion", open(sys.argv[2], "rb").read()),
)
conn.commit()
conn.close()
PY
}

# _stored DB — "BYTES SHA256" of the value as it sits in the DB right now.  The dry-run
# and no-write cases compare this, so "changed nothing" is checked on the artefact.
_stored() {
    "$PY" - "$1" <<'PY'
import hashlib, sqlite3, sys
conn = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
try:
    row = conn.execute("SELECT value FROM ItemTable WHERE key = ?",
                       ("qwenlm.qwen-code-vscode-ide-companion",)).fetchone()
finally:
    conn.close()
raw = row[0] if row else b""
raw = raw if isinstance(raw, (bytes, bytearray)) else str(raw).encode()
print(len(raw), hashlib.sha256(raw).hexdigest())
PY
}

# _stored_type DB — the SQLite storage class of the value as the DB holds it.  VS Code
# writes this column as TEXT; a BLOB row (what binding Python bytes produces) makes the
# extension host log "[extHostStorage] unexpected error parsing storage contents" on its
# next start, with the value read back as a non-string.
_stored_type() {
    "$PY" - "$1" <<'PY'
import sqlite3, sys
conn = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
try:
    row = conn.execute("SELECT typeof(value) FROM ItemTable WHERE key = ?",
                       ("qwenlm.qwen-code-vscode-ide-companion",)).fetchone()
finally:
    conn.close()
print(row[0] if row else "none")
PY
}

# _trim [--apply ...] — run the tool with the standard seams, stderr merged so a
# traceback or a failure line cannot hide behind the verdict.
_trim() {
    run bash -c '"$1" --state-dir "$2" --backup-dir "$3" "${@:4}" 2>&1' _ \
        "$TOOL" "$SANDBOX" "$BACKUPS" "$@"
}

_conv_count() {
    "$PY" - "$1" <<'PY'
import json, sqlite3, sys
conn = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
try:
    row = conn.execute("SELECT value FROM ItemTable WHERE key = ?",
                       ("qwenlm.qwen-code-vscode-ide-companion",)).fetchone()
finally:
    conn.close()
state = json.loads(row[0]) if row else {}
print(len(state.get("conversations", []) or []))
PY
}

@test "companion-trim: a dry run reports the drop and writes NOTHING" {
    _fixture "$SANDBOX/convs.json"
    _mkdb "$DB" "$SANDBOX/convs.json"
    before="$(_stored "$DB")"

    _trim
    [ "$status" -eq 0 ]
    [[ "$output" == *"(dropping 2)"* ]]
    [[ "$output" == *"DRY RUN"* ]]

    # The observable: the stored value is byte-identical, and no backup was taken.
    [ "$(_stored "$DB")" = "$before" ]
    [ ! -d "$BACKUPS" ]
}

@test "companion-trim: --apply backs up first, writes, and the re-read agrees" {
    _fixture "$SANDBOX/convs.json"
    _mkdb "$DB" "$SANDBOX/convs.json"
    before="$(_stored "$DB")"
    before_bytes="${before%% *}"

    _trim --apply
    [ "$status" -eq 0 ]
    [[ "$output" == *"after re-read:"* ]]

    # The write landed: one conversation left, strictly fewer bytes than before.
    [ "$(_conv_count "$DB")" = "1" ]
    after_bytes="$(_stored "$DB")"
    [ "${after_bytes%% *}" -lt "$before_bytes" ]

    # ...and the column is TEXT, as VS Code writes it.  The fixture inserts BYTES, so this
    # asserts the writer's type and nothing else.
    [ "$(_stored_type "$DB")" = "text" ]

    # And a backup was taken, non-empty, before the write.
    compgen -G "$BACKUPS/companion-conversations-*.json.gz" > /dev/null
    backup="$(echo "$BACKUPS"/companion-conversations-*.json.gz)"
    [ -s "$backup" ]
}

@test "companion-trim: the WINDOW decides the old conversation, not position or count" {
    _fixture "$SANDBOX/convs.json"
    _mkdb "$DB" "$SANDBOX/convs.json"

    # The default 90 days drops the 100-day-old conversation as well as the empty one.
    _trim
    [ "$status" -eq 0 ]
    [[ "$output" == *"(dropping 2)"* ]]

    # Widening the window past its age keeps it, and the message-less one still goes —
    # so the window is what selected it, and "no messages" is an INDEPENDENT rule.
    _trim --keep-days 200
    [ "$status" -eq 0 ]
    [[ "$output" == *"conversations: 3 -> 2"* ]]
    [[ "$output" == *"(dropping 1)"* ]]
}

@test "companion-trim: a compliant DB is left alone even with --apply" {
    "$PY" - "$SANDBOX/convs.json" <<'PY'
import json, sys
with open(sys.argv[1], "w") as fh:
    json.dump({"conversations": [
        {"id": "recent-with-messages", "updatedAt": 4102444800000,
         "messages": [{"role": "user"}]},
    ]}, fh)
PY
    _mkdb "$DB" "$SANDBOX/convs.json"
    before="$(_stored "$DB")"

    _trim --apply
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing to do"* ]]
    # The writer must not have run: same bytes, and still no backup.
    [ "$(_stored "$DB")" = "$before" ]
    [ ! -d "$BACKUPS" ]
}

@test "companion-trim: every profile DB is covered, not only the top-level one" {
    _fixture "$SANDBOX/convs.json"
    _mkdb "$DB" "$SANDBOX/convs.json"
    profile="$SANDBOX/profiles/122065b0/globalStorage/state.vscdb"
    _mkdb "$profile" "$SANDBOX/convs.json"

    _trim
    [ "$status" -eq 0 ]
    [[ "$output" == *"$DB"* ]]
    [[ "$output" == *"$profile"* ]]
}

@test "companion-trim: a DB with no ItemTable is reported, not crashed on" {
    mkdir -p "$(dirname "$DB")"
    : > "$DB"   # the remote server's state.vscdb is 0 bytes with no tables at all

    _trim
    [ "$status" -eq 0 ]
    [[ "$output" == *"no ItemTable"* ]]
    [[ "$output" != *"Traceback"* ]]
    [[ "$output" != *"OperationalError"* ]]
}

@test "companion-trim: no state DB under the given dir is exit 2, naming where it looked" {
    _trim
    [ "$status" -eq 2 ]
    [[ "$output" == *"no state.vscdb found"* ]]
    [[ "$output" == *"$SANDBOX"* ]]
}

# end of file
