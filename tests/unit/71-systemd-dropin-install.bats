#!/usr/bin/env bats
# ==============================================================================
# Unit — a systemd/*.conf source declares its own drop-in destinations, and
# install.sh installs THOSE instead of linking the .conf as a unit
# ==============================================================================
# WHY (card SYSTEMD-DROPIN-INSTALL-001, 2026-10-24): install.sh's user-unit loop skipped
# only directories, so every `systemd/*.conf` was symlinked into ~/.config/systemd/user/
# as a non-unit stray — which systemd ignores in silence, so nothing ever complained —
# while the drop-in destination each file documents was never created. A fresh box
# therefore got the strays and NONE of the settings the four .conf files carry (CPU
# isolation during autotune, the quiet-fleet gate, the node stop budget, CI isolation),
# and the installer still exited 0 printing a success line per file.
#
# The rule these cases pin: a .conf declares its own destinations on
# `# install-dropin: <unit> <name>` lines (`system/<unit> <name>` = root-owned), the
# installer reads them, and a .conf that declares nothing is reported rather than passed
# over. The end-to-end cases are the load-bearing ones — a grep for the parser would
# still pass if the parser were never called.
#
# Hermetic: every case runs against a temp HOME with `systemctl` and `sudo` stubbed.
# The sudo stub matters: `sudo -n true` SUCCEEDS on this box (measured 2026-10-24), so an
# unstubbed run would really copy units into /etc and enable them.
setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    FAKE_HOME="$BATS_TEST_TMPDIR/home"
    STUB_DIR="$BATS_TEST_TMPDIR/stubs"
    mkdir -p "$FAKE_HOME" "$STUB_DIR"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_DIR/systemctl"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$STUB_DIR/sudo"
    chmod +x "$STUB_DIR/systemctl" "$STUB_DIR/sudo"
}

# run_installer — runs install.sh against the temp HOME with the stubs first on PATH.
run_installer() {
    run env HOME="$FAKE_HOME" PATH="$STUB_DIR:$PATH" bash "$REPO_ROOT/install.sh"
}

@test "drop-in sources: every systemd/*.conf declares a well-formed destination" {
    local f line name declared=0
    for f in "$REPO_ROOT"/systemd/*.conf
    do
        [ -f "$f" ] || continue
        declared=0
        while IFS= read -r line
        do
            declared=$((declared + 1))
            # Exactly two fields: the target unit (or `system/<unit>`) and the drop-in
            # file name. A third field means a malformed line the parser would skip, and
            # the setting it names would silently not be installed.
            if [[ ! "$line" =~ ^#\ install-dropin:\ [^[:space:]]+\ [^[:space:]]+$ ]]
            then
                echo "malformed directive in ${f##*/}: $line"
                return 1
            fi
            name="${line##* }"
            if [[ "$name" != *.conf ]]
            then
                echo "destination is not a .conf name in ${f##*/}: $name"
                return 1
            fi
        done < <(grep '^# install-dropin:' "$f")
        if [ "$declared" -eq 0 ]
        then
            echo "${f##*/} declares no '# install-dropin:' line, so install.sh installs it nowhere"
            return 1
        fi
    done
    # The four sources that exist today, named so a deletion is not a silent drop in
    # coverage. A NEW .conf needs no edit here: the loop above already demands its
    # declaration.
    for name in cpu-affinity-0-7.conf openclaw-node-stop-budget.conf \
                autotune-resume-quiet-fleet.conf runner-cpu-isolation.conf
    do
        [ -f "$REPO_ROOT/systemd/$name" ]
    done
}

@test "drop-in install: no .conf lands in the unit dir, and each declared target is created" {
    run_installer
    [ "$status" -eq 0 ]

    # The wart this card closes: a .conf is a drop-in SOURCE, never a unit.
    local stray found=0
    for stray in "$FAKE_HOME"/.config/systemd/user/*.conf
    do
        if [ -e "$stray" ] || [ -L "$stray" ]; then
            found=1
            echo "stray in the unit dir: $stray"
        fi
    done
    [ "$found" -eq 0 ]

    # The fix: the declared destinations exist, as links into this repo.
    [ -L "$FAKE_HOME/.config/systemd/user/openclaw-node.service.d/10-stop-budget.conf" ]
    [ "$(readlink -f "$FAKE_HOME/.config/systemd/user/openclaw-node.service.d/10-stop-budget.conf")" \
        = "$REPO_ROOT/systemd/openclaw-node-stop-budget.conf" ]
    [ -L "$FAKE_HOME/.config/systemd/user/graphify-mcp-investigator.service.d/90-cpu-affinity.conf" ]
    [ -L "$FAKE_HOME/.config/systemd/user/autotune-resume.service.d/quiet-fleet.conf" ]

    # Units are still linked — the skip must not have swallowed the unit loop.
    [ -L "$FAKE_HOME/.config/systemd/user/openclaw-refresh-keys.service" ]

    # Root-owned destinations are NOT written when sudo cannot be had, and the exact
    # command is printed instead — a silent skip would leave the runners unpinned.
    [ ! -e "$FAKE_HOME/.config/systemd/user/actions.runner.waynegault-ubuntu-console.wsl-console-1.service.d" ]
    [[ "$output" == *"/etc/systemd/system/actions.runner.waynegault-ubuntu-console.wsl-console-1.service.d/90-cpu-isolation.conf"* ]]
}

@test "drop-in install: a stray an older install created is removed, an operator's file is not" {
    mkdir -p "$FAKE_HOME/.config/systemd/user"
    ln -sfn "$REPO_ROOT/systemd/cpu-affinity-0-7.conf" \
        "$FAKE_HOME/.config/systemd/user/cpu-affinity-0-7.conf"
    # Control: this one does NOT point into the repo, so it belongs to the operator.
    printf '[Service]\nNice=5\n' > "$FAKE_HOME/.config/systemd/user/mine.conf"

    run_installer
    [ "$status" -eq 0 ]

    [ ! -L "$FAKE_HOME/.config/systemd/user/cpu-affinity-0-7.conf" ]
    [[ "$output" == *"removed stray"* ]]
    [ -f "$FAKE_HOME/.config/systemd/user/mine.conf" ]
}
