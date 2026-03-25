# Memory / Obsidian / `oc g` redesign notes

## What Obsidian should do

Use Obsidian as the **human-facing curated memory browser**.

Target vault path:
- `/home/wayne/.openclaw/state/memory/gigabrain-workspace/obsidian-vault`

Current exported content path:
- `/home/wayne/.openclaw/state/memory/gigabrain-workspace/obsidian-vault/Gigabrain`

### Current reality
The current export contains a nested-vault shape. Useful content is inside
`Gigabrain/`, and both the outer wrapper and the inner folder currently contain
`.obsidian` directories.

### Decision
Stop generating a nested vault structure. Converge on a single intended vault
root for human use.

### Important note
If desktop Obsidian on Windows is pointed at a WSL UNC path and throws `EISDIR: illegal operation on a directory, watch ...`, that is not a markdown-content problem. It is a vault opening / filesystem watching problem on the Obsidian side.

## Recommended graph split

### 1. Obsidian / Gigabrain graph
Use for curated browsing and human memory review.

### 2. `oc g`
Use for derived graph exploration and debugging.

### 3. OpenStinger
Use for temporal/entity recall investigation.

## `oc g` redesign goals

### Keep `oc g` as an operational graph browser
Not the only memory UI, and not the only human memory surface.

### Add explicit graph projections
Implemented/recommended views:
- `overview`
- `topics`
- `files`
- `semantic`
- `raw`

### Make the default graph less noisy
The `overview` projection hides chunk nodes and remaps chunk-level relations onto files where possible.

### Make semantic links controllable
A semantic threshold control is now exposed in the UI.

### Surface provenance
The toolbar should show where the graph came from and which view is active.

## Auth architecture reality

Current OpenClaw behavior still fights the intended secret-ref architecture because `auth-profiles.json` persistence rewrites or drops ref-backed auth fields.

Recommendation:
- do not treat `auth-profiles.json` as the canonical place for durable externalized secret refs today
- keep external secret sources available
- patch/report upstream persistence behavior separately
