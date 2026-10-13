#!/usr/bin/env bash
# AI INSTRUCTION: On ANY change to this file, increment the Module Version below.
# Module Version: 2
#
# openclaw-update-capture-prune.sh — bound the OpenClaw update-capture store.
#
# WHY THIS EXISTS (2026-10-13)
#
# `~/.openclaw.update-captures/` holds one recovery set per update/Doctor run, each
# ~1 GB (roots = every agent's openclaw-agent.sqlite). The updater documents these as
# MANUAL-removal only — "recovery bundles are not automatically pruned. Keep it until
# you have checked the updated installation; removal is manual"
# (docs/cli/update/how-updates-run.md) — and nothing here pruned them, so the store
# reached 9.1 GB across 9 sets by 2026-10-13, five of them standalone Doctor baselines
# created within a single day. This unit is that missing retention policy.
#
# POLICY (conservative — these are forensic bundles, so err on keeping):
#   * NEVER remove the current `lastRun` set (the updater may still reference it).
#   * NEVER remove the newest set of ANY kind, nor the newest SEALED set
#     (one with manifest.json) — belt-and-braces so the most recent forensic
#     baseline always survives even if the status read is unavailable.
#   * Remove UNSEALED/incomplete sets older than MIN_UNSEALED_H (default 24 h):
#     no manifest = no blob->path map = nothing restorable, pure superseded evidence.
#   * Remove SEALED sets older than SEALED_RETENTION_D (default 7 d), except the
#     newest sealed (above).
#   * Removal is STAGED: the set is moved to Trash (recoverable) and the Trash entries
#     this store created are permanently reclaimed only once older than STAGING_D
#     (default 7 d). Recoverable first, reclaimed later.
#
# SAFETY:
#   * The authoritative set list comes from `openclaw update status --json`
#     (runId + status). Deleting a directory clears its entry — verified 2026-10-13.
#   * FAIL-SAFE: if that status cannot be read, or yields no `lastRun` id, the script
#     REFUSES to prune (a no-op with a warning) — an active lastRun can be an unsealed
#     set indistinguishable from the rest, so pruning blind could destroy it.
#   * Age comes from `stat -c %W` (birth time, which userspace cannot set), falling
#     back to %Y only when birth is 0/unavailable. NEGATIVE ages are REJECTED
#     (clock-step guard: a future mtime would otherwise pass an upper-bound test).
#   * `--dry-run` prints the plan and changes nothing.
#   * A no-op exits 0 (a green unit means the job RAN, not that it found something).
#
# Verify:
#   openclaw-update-capture-prune.sh --dry-run
#   journalctl --user -u openclaw-update-capture-prune.service -n50

set -uo pipefail

STORE="${OPENCLAW_UPDATE_CAPTURES:-$HOME/.openclaw.update-captures}"
MIN_UNSEALED_H="${MIN_UNSEALED_H:-24}"
SEALED_RETENTION_D="${SEALED_RETENTION_D:-7}"
STAGING_D="${STAGING_D:-7}"
CAP_GB="${CAP_GB:-8}"
LOGF="${LOGF:-$HOME/.local/state/openclaw-update-capture-prune.log}"
# Test seam: point at a status JSON file instead of invoking the CLI.
STATUS_JSON_FILE="${OPENCLAW_UPDATE_STATUS_JSON:-}"
TRASH_FILES="$HOME/.local/share/Trash/files"
TRASH_INFO="$HOME/.local/share/Trash/info"

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

export PATH="$HOME/.local/bin:/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:/usr/bin:/bin"

mkdir -p "$(dirname "$LOGF")"
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOGF"; }
quiet() { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOGF"; }

[ -d "$STORE" ] || { log "store absent: $STORE — nothing to do"; exit 0; }

# ── authoritative status (FAIL-SAFE: no status ⇒ no prune) ───────────────────
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
if [ -n "$STATUS_JSON_FILE" ] && [ -r "$STATUS_JSON_FILE" ]; then
  cp "$STATUS_JSON_FILE" "$tmp"
else
  openclaw update status --json >"$tmp" 2>/dev/null || true
fi

LAST_ID=""
declare -A STATUS_OF=()
while IFS=$'\t' read -r tag a b _c; do
  case "$tag" in
    LASTID=*) LAST_ID="${tag#LASTID=}" ;;
    SET)      [ -n "${a:-}" ] && STATUS_OF["$a"]="${b:-?}" ;;
  esac
done < <(node -e '
  const fs=require("fs"), path=require("path");
  let j={}; try { j=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); } catch(e){ process.exit(0); }
  const lr=j.lastRun||{};
  console.log("LASTID="+((lr.id||lr.runId)||""));
  for (const r of (j.recoverySets||[])) {
    const id = r.runId || (r.directory ? path.basename(r.directory) : "");
    if (id) console.log(["SET", id, (r.status||"?")].join("\t"));
  }
' "$tmp" 2>/dev/null)

if [ -z "$LAST_ID" ]; then
  log "WARN   cannot resolve current lastRun from 'openclaw update status --json' — refusing to prune (an active set may be unsealed); nothing changed"
  exit 0
fi

age_seconds() {  # $1 = dir; echoes age in seconds; negative = suspicious
  local d="$1" now birth mtime ts
  now=$(date +%s)
  birth=$(stat -c %W "$d" 2>/dev/null || echo 0); [ -n "$birth" ] || birth=0
  if [ "$birth" -gt 0 ] 2>/dev/null; then ts=$birth; else
    mtime=$(stat -c %Y "$d" 2>/dev/null || echo 0); [ -n "$mtime" ] || mtime=0; ts=$mtime
  fi
  echo $(( now - ts ))
}

# ── pass 1: protections (lastRun id + newest sealed + newest overall) ────────
names=(); ages=(); seals=()
newest_sealed=""; newest_sealed_ts=-1
newest_any=""; newest_any_ts=-1
shopt -s nullglob
for d in "$STORE"/*/; do
  name="$(basename "$d")"
  case "$name" in .*) continue ;; esac
  [ -d "$d" ] || continue
  age="$(age_seconds "$d")"
  sealed=0; [ -f "$d/manifest.json" ] && sealed=1
  names+=("$name"); ages+=("$age"); seals+=("$sealed")
  if [ "$age" -ge 0 ] 2>/dev/null; then
    ts=$(( $(date +%s) - age ))
    [ "$ts" -gt "$newest_any_ts" ] && { newest_any_ts=$ts; newest_any="$name"; }
    if [ "$sealed" -eq 1 ] && [ "$ts" -gt "$newest_sealed_ts" ]; then
      newest_sealed_ts=$ts; newest_sealed="$name"
    fi
  fi
done
shopt -u nullglob

[ "${#names[@]}" -eq 0 ] && { log "store empty: $STORE — nothing to do"; exit 0; }

# ── pass 2: decide ───────────────────────────────────────────────────────────
targets=(); reasons=()
for i in "${!names[@]}"; do
  name="${names[$i]}"; age="${ages[$i]}"; sealed="${seals[$i]}"
  st="${STATUS_OF[$name]:-}"
  if [ "$name" = "$LAST_ID" ]; then quiet "keep   $name  (lastRun)"; continue; fi
  if [ "$age" -lt 0 ] 2>/dev/null; then
    log "WARN   $name  age=${age}s (negative — clock step?); keeping, not deleting"; continue; fi
  if [ "$name" = "$newest_any" ]; then quiet "keep   $name  (newest set)"; continue; fi
  if [ "$sealed" -eq 1 ] && [ "$name" = "$newest_sealed" ]; then
    quiet "keep   $name  (newest sealed)"; continue; fi
  if [ "$sealed" -eq 0 ]; then
    if [ "$age" -gt $(( MIN_UNSEALED_H * 3600 )) ]; then
      targets+=("$name"); reasons+=("unsealed/incomplete, age $(( age/3600 ))h > ${MIN_UNSEALED_H}h${st:+, status=$st}")
    else
      quiet "keep   $name  (unsealed but age $(( age/3600 ))h <= ${MIN_UNSEALED_H}h)"
    fi
  else
    if [ "$age" -gt $(( SEALED_RETENTION_D * 86400 )) ]; then
      targets+=("$name"); reasons+=("sealed, age $(( age/86400 ))d > ${SEALED_RETENTION_D}d")
    else
      quiet "keep   $name  (sealed, age $(( age/86400 ))d <= ${SEALED_RETENTION_D}d)"
    fi
  fi
done

# ── backstop: size cap (oldest retireable first) ─────────────────────────────
store_kb=$(du -sk "$STORE" 2>/dev/null | cut -f1); store_kb=${store_kb:-0}
cap_kb=$(( CAP_GB * 1024 * 1024 ))
if [ "$store_kb" -gt "$cap_kb" ]; then
  log "WARN   store ${store_kb}KB exceeds cap ${cap_kb}KB — considering oldest retireable sets"
  for i in "${!names[@]}"; do
    name="${names[$i]}"
    [ "$name" = "$LAST_ID" ] && continue
    [ "$name" = "$newest_any" ] && continue
    [ "$name" = "$newest_sealed" ] && continue
    case " ${targets[*]} " in *" $name "*) continue ;; esac
    targets+=("$name"); reasons+=("size-cap backstop")
  done
fi

# ── act: stage to Trash ──────────────────────────────────────────────────────
if [ "${#targets[@]}" -eq 0 ]; then
  log "no-op: ${#names[@]} set(s) present, all within retention"
else
  for i in "${!targets[@]}"; do
    name="${targets[$i]}"; why="${reasons[$i]}"
    if [ "$DRY" -eq 1 ]; then
      log "DRY    would trash $name  ($why)"
    elif trash "$STORE/$name" 2>/dev/null; then
      log "trash  $name  ($why)"
    else
      log "ERROR  failed to trash $name — keeping"
    fi
  done
  [ "$DRY" -eq 0 ] && log "staged ${#targets[@]} set(s) to Trash; store now $(du -sh "$STORE" 2>/dev/null | cut -f1)"
fi

# ── stage B: reclaim Trash entries this store created, past STAGING_D ─────────
[ "$DRY" -eq 1 ] && exit 0
reclaimed=0
shopt -s nullglob
for info in "$TRASH_INFO"/*.trashinfo; do
  p="$(sed -n 's/^Path=//p' "$info" | head -1)"
  case "$p" in "$STORE"/*) ;; *) continue ;; esac
  dd="$(sed -n 's/^DeletionDate=//p' "$info" | head -1)"
  [ -n "$dd" ] || continue
  dts="$(date -d "$dd" +%s 2>/dev/null || echo 0)"
  [ "$dts" -gt 0 ] || continue
  [ $(( $(date +%s) - dts )) -gt $(( STAGING_D * 86400 )) ] || continue
  base="$(basename "$info" .trashinfo)"
  rm -rf -- "${TRASH_FILES:?}/${base:?}" "$info" 2>/dev/null && { reclaimed=$(( reclaimed + 1 )); }
done
shopt -u nullglob
[ "$reclaimed" -gt 0 ] && log "reclaimed $reclaimed staged Trash entr(y/ies) older than ${STAGING_D}d"

exit 0
