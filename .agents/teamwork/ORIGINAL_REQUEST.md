# Original User Request

## Initial Request — 2026-11-10T12:24:27Z

An expert Python software architect orchestrating, supervising and quality assuring a team of expert Python software developers to make this repository box-aware (optimising for an Asus RTX Spark with 128GB unified memory and a Dell XPS with 4GB CUDA VRAM) and perform an exhaustive audit and refactoring across the codebase for production use.

Working directory: /home/wayne/github-wsl/ubuntu-console
Integrity mode: development

## Requirements

### R1. Box Awareness and Hardware Profile Optimization
Make the repository box-aware and optimize functionality for two target environments: an Asus RTX Spark with 128GB unified memory and a Dell XPS with 4GB CUDA VRAM. Optimize memory usage, execution workloads, and model parameters appropriately for each machine.

### R2. Comprehensive Architectural Audit and Refactoring Plan
Perform an exhaustive audit across the codebase to identify architectural flaws, structural/technical debt, redundant or duplicated logic, bypassed Pydantic validations, unfinalized stubs, circular imports, monster files/methods, non-idempotent functions, and vacuous or missing tests. Deliver a detailed audit report and refactoring plan for review before applying sweeping changes.

### R3. Codebase Refactoring and Consolidation
Implement the approved refactoring plan across the codebase: eliminate backwards compatibility hacks and dead code, unify isolated or overlapping logic into shared modules, enforce strict Pydantic validation across execution flows, and ensure all scripts, tools, and execution flows strictly utilize the Python executable within the local repo `.venv`.

### R4. Test Suite Validation and Zero-Regression Hardening
Thoroughly validate key logic without contaminating real data by executing the repository's existing pytest test suite and expanding test coverage for refactored areas. Eliminate suppressed warnings, unhandled errors, and vacuous test passes.

## Acceptance Criteria

### Box Awareness
- [ ] Codebase identifies or adapts to the target hardware profile (Asus RTX Spark with 128GB unified memory vs Dell XPS with 4GB CUDA VRAM) and adjusts workloads and resource allocations accordingly.

### Code Quality and Architecture
- [ ] Comprehensive audit report detailing identified flaws, debt, and refactoring items is produced.
- [ ] Approved refactoring changes are implemented with clean architecture, removing backwards compatibility hacks and dead code.
- [ ] Duplicated logic (such as multi-use test scenarios or overlapping utilities) is consolidated into unified shared modules.
- [ ] Pydantic validation is strictly enforced across data flows without bypasses.
- [ ] All scripts, tools, and execution flows strictly execute using the local repo `.venv` Python executable.

### Test Verification
- [ ] The repository's existing pytest test suite passes cleanly with zero regressions.
- [ ] New unit tests thoroughly validate refactored components without real data contamination.
- [ ] Suppressed warnings and vacuous test passes are eliminated.

## Follow-up — 2026-11-10T13:52:40Z

User note: "keep an eye on your token use so that you have enough left to complete this work." Please ensure orchestrators and subagents manage context window / token usage efficiently through to completion.
