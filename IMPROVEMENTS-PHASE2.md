# Codebase Improvements - Phase 2 Backlog

**Created:** 2026-03-28  
**Status:** Active backlog (prioritized from original Phase 2 analysis)  
**Original:** See `archive/IMPROVEMENTS-PHASE2.md` for full analysis

---

## Executive Summary

Phase 2 has been reprioritized into **high-value items only**. Low-priority refinements have been deferred indefinitely.

**Completion:** ~50% (8/17 items from original list complete)

---

## Priority 1: High-Value Features (Week 1-2)

### ✅ COMPLETED Items

| Item | Status | Location |
|------|--------|----------|
| Integration tests | ✅ Done | `tests/integration/` (4 files) |
| Docker prune step | ✅ Done | `scripts/08-maintenance.sh` [16/17] |
| NPM cache clean step | ✅ Done | `scripts/08-maintenance.sh` [17/17] |
| Git pre-commit secret scan | ✅ Done | `scripts/10-deployment.sh` |
| Maintenance metrics | ✅ Done | `maintenance-history.csv` |
| Directory preservation in `up` | ✅ Done | `scripts/08-maintenance.sh` |

---

## Priority 2: Medium-Value (Week 3-4)

### 🟡 In Progress / Partial

| Item | Priority | Effort | Status |
|------|----------|--------|--------|
| **Auto-download models** | 🟡 Medium | 3-4h | ❌ Not started |
| **Mock framework for tests** | 🟢 Low | 4-6h | ❌ Not started |
| **Usage analytics dashboard** | 🟢 Low | 4-6h | ❌ Not started |

#### Auto-download Models
**Proposal:** Auto-download GGUF files when `model use N` is called but file is missing.

**Implementation:**
```bash
# In scripts/11-llm-manager.sh model_use()
if [[ ! -f "$LLAMA_MODEL_DIR/$file" ]]
then
    __tac_info "Model File" "[NOT FOUND - Downloading...]" "$C_Warning"
    # Prompt for models >2GB
    local size_gb
    size_gb=$(du -g "$LLM_REGISTRY" | awk -F'|' -v n="$num" '$1==n {print $4}' | sed 's/G//')
    if (( size_gb > 2 ))
    then
        read -p "Download ${size_gb}GB model? [y/N] " confirm
        [[ "$confirm" != "y" ]] && return 1
    fi
    model download "$file" || return 1
fi
```

**Risk:** Large downloads without explicit consent  
**Mitigation:** Confirmation prompt for models >2GB

---

## Priority 3: Low-Value (Deferred Indefinitely)

### ❌ DEFERRED Items

The following items from the original Phase 2 list are **no longer active priorities**:

| Item | Original Priority | Reason for Deferral |
|------|-------------------|---------------------|
| Dashboard caching optimization | 🟢 Low | Already fast enough (~200ms) |
| Parallel maintenance steps | 🟢 Low | Not a pain point |
| Consistent error handling pattern | 🟢 Low | Cosmetic only |
| Magic string constants | 🟢 Low | Maintainability only |
| Function length refactoring | 🟢 Low | Code is readable as-is |
| API key rotation reminder | 🟢 Low | Security handled elsewhere |
| Battery status enhancement | 🟢 Low | Laptop-specific |
| Property-based UI tests | 🟢 Low | Nice-to-have |

---

## Documentation Status

### ✅ Completed
- [x] ADR-001: Modular Bash Architecture
- [x] ADR-002: Local LLM Design
- [x] ADR-003: Windows R Integration
- [x] ADR-004: Obsidian and Graph Design
- [x] README quick start (1429 lines)

### 🟡 Partial
- [ ] ADR-005: Cooldown System Design (optional)
- [ ] ADR-006: UI Engine Tradeoffs (optional)

---

## Recommended Next Actions

1. **Auto-download models** — Highest remaining UX improvement
2. **Mock framework** — Enables more CI/CD testing
3. **Usage analytics** — Optional visibility enhancement

---

## Original Phase 2 Summary Table (Reference)

| Category | Item | Priority | Status |
|----------|------|----------|--------|
| **Testing** | Integration tests | 🟡 Medium | ✅ DONE |
| **Testing** | Mock framework | 🟢 Low | ❌ Backlog |
| **Features** | Auto-download models | 🟡 Medium | ❌ Backlog |
| **Features** | Usage analytics | 🟢 Low | ❌ Backlog |
| **Documentation** | ADRs | 🟢 Low | ✅ 4/4 core done |

**Total Remaining Effort:** 11-16 hours (if all backlog items pursued)

---

## Conclusion

The codebase is in excellent shape. The remaining Phase 2 items are **optional enhancements** rather than critical needs. Focus on auto-download models if UX improvement is desired; otherwise, the system is production-ready as-is.

**Recommendation:** Close Phase 2 after implementing auto-download models (if desired). Future improvements should be tracked as individual issues or feature requests.
