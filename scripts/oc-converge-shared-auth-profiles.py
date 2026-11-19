#!/usr/bin/env python3
"""Convert CONFIG-DECLARED auth profiles in the SHARED auth store to env-backed keyRefs.

WHY THIS EXISTS (2026-11-19)
    `openclaw secrets audit` reported PLAINTEXT_FOUND for the shared-store profiles
    huggingface:manual and cheaper-inference:manual.  The `auth_map` mechanism could not
    have prevented it: that writes PER-AGENT openclaw-agent.sqlite, and all fourteen of
    those were already clean.  The plaintext lived in the SHARED store
    (state/openclaw.sqlite -> config_machine_state 'authProfiles.store') because
    openclaw.json declares both profiles under `auth.profiles`, and the runtime keeps
    shared profiles in the state DB.  Nothing in the refresh path had ever touched it,
    so a plaintext key there survived every `oc refresh-keys`.

USAGE
    oc-converge-shared-auth-profiles.py <config.json> <state-db> <gateway-state> <cache-file>

    <gateway-state> is what `systemctl --user is-active openclaw-gateway.service` printed.
    Anything other than inactive/failed is treated as UP and DEFERS: the running Gateway
    holds this row in memory, so a live write is lost on its next persist.  Every
    sanctioned mutation path (`openclaw models auth *`, `secrets configure`) is
    offline-only for the same reason.  The boot window is the one that qualifies —
    openclaw-refresh-keys.service is Before=openclaw-gateway.service.

SCOPE
    Profiles that ALREADY EXIST in the store, and only those: it never invents a profile
    id.  The env var name is DERIVED — an existing keyRef id, else the provider's config
    ref, else the conventional <PROVIDER>_API_KEY when that name is actually set — never
    typed into a list.  With no env value it refuses to convert rather than writing a
    ref that cannot resolve.

Exit status is 0 on every path except an unreadable config/DB, so a crash here can never
abort the credential refresh that calls it.
"""

import json
import os
import re
import shutil
import sqlite3
import sys
import time


def env_value(name, cache_path):
    """The value from the environment first, then the Windows-bridge cache."""
    v = os.environ.get(name)
    if v:
        return v
    try:
        with open(cache_path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line.startswith("export "):
                    line = line[len("export ") :]
                if line.startswith(name + "="):
                    return line.split("=", 1)[1].strip().strip('"').strip("'")
    except OSError:
        pass
    return ""


def main(argv):
    if len(argv) != 5:
        sys.stderr.write("usage: %s <config.json> <state-db> <gateway-state> <cache-file>\n" % argv[0])
        return 2
    cfg_path, db_path, gw_state, cache_path = argv[1:5]

    if gw_state.strip() not in ("inactive", "failed"):
        print(
            "deferred: Gateway is %s — shared auth-profile convergence needs it down; "
            "next boot applies it" % (gw_state.strip() or "unknown (no user manager)")
        )
        return 0

    try:
        with open(cfg_path, encoding="utf-8") as fh:
            cfg = json.load(fh)
    except Exception as exc:
        print("error: cannot read %s (%s: %s)" % (cfg_path, type(exc).__name__, exc))
        return 0

    profiles_cfg = (cfg.get("auth") or {}).get("profiles") or {}
    providers_cfg = (cfg.get("models") or {}).get("providers") or {}

    def provider_env_name(provider, existing):
        # 1. what the store already resolves to; 2. the provider's own config ref;
        # 3. the conventional name, but only when it is actually set.
        ref = (existing or {}).get("keyRef") or {}
        if ref.get("id"):
            return ref["id"]
        api = (providers_cfg.get(provider) or {}).get("apiKey")
        if isinstance(api, dict) and api.get("id"):
            return api["id"]
        guess = re.sub(r"[^A-Z0-9]+", "_", provider.upper()).strip("_") + "_API_KEY"
        return guess if env_value(guess, cache_path) else ""

    if not os.path.isfile(db_path):
        print("error: shared auth store not found at %s" % db_path)
        return 0

    con = sqlite3.connect(db_path, timeout=20)
    try:
        row = con.execute("SELECT value_json FROM config_machine_state WHERE state_key='authProfiles.store'").fetchone()
        if not row:
            print("shared auth store has no authProfiles.store row; nothing to do")
            return 0
        store = json.loads(row[0])
        profiles = store.get("profiles") or {}

        converted, stale, unresolved = [], [], []
        for pid in sorted(profiles_cfg):
            existing = profiles.get(pid)
            if not isinstance(existing, dict):
                continue  # never invent a profile id
            if "keyRef" in existing and "key" not in existing:
                continue  # already converged
            if "key" not in existing:
                continue
            provider = existing.get("provider") or (profiles_cfg.get(pid) or {}).get("provider") or ""
            var = provider_env_name(provider, existing)
            if not var:
                unresolved.append(pid)
                continue
            value = env_value(var, cache_path)
            if not value:
                unresolved.append("%s (no $%s)" % (pid, var))
                continue
            if existing["key"] != value:
                # Name it: a plaintext that disagrees with the canonical env is exactly
                # the drift that made it look authoritative.  The env still wins.
                stale.append(pid)
            profiles[pid] = {
                "type": existing.get("type", "api_key"),
                "provider": provider,
                "keyRef": {"source": "env", "provider": "default", "id": var},
            }
            converted.append(pid)

        notes = []
        if converted:
            backup = db_path + ".pre-shared-auth-converge"
            try:
                shutil.copyfile(db_path, backup)
            except OSError as exc:
                print("error: could not back up %s before writing (%s) — nothing written" % (db_path, exc))
                return 0
            store["profiles"] = profiles
            con.execute(
                "UPDATE config_machine_state SET value_json=?, updated_at_ms=? WHERE state_key='authProfiles.store'",
                (json.dumps(store, separators=(",", ":")), int(time.time() * 1000)),
            )
            con.commit()
            notes.append("converted %d shared auth profile(s): %s" % (len(converted), ", ".join(converted)))
        if stale:
            notes.append("plaintext differed from the env for: %s (env wins)" % ", ".join(stale))
        if unresolved:
            notes.append("could not resolve an env var for: %s" % ", ".join(unresolved))
        if notes:
            print("; ".join(notes))
        return 0
    finally:
        con.close()


if __name__ == "__main__":
    sys.exit(main(sys.argv))
