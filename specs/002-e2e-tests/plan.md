# Implementation Plan: End-to-End Tests for Harvest Spending

**Branch**: `002-e2e-tests` | **Date**: 2026-04-18 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/002-e2e-tests/spec.md`

## Summary

Add automated end-to-end tests that execute the deployed `voucher_spend` validator against the project's authoritative fixtures (Groth16 proof, customer Ed25519 bundle, applied script), cover all four documented rejection reasons with mutation-paired negatives, confirm the customer signature bytes are verifiable by an independent Ed25519 library, and cross-check that the JS-produced `signed_data` byte layout matches what the Aiken validator parses.

**Technical approach**: primary tests spin up a real Cardano devnet using the `cardano-node-clients:devnet` sub-library (`withDevnet`, `submitTx`, the existing `TxBuild` DSL), submit real transactions that exercise the applied validator bytecode, and observe the node's accept/reject verdict. Ed25519 verification (for FR-003) uses primitives re-exported from `cardano-node-clients` — the underlying implementation is the same `cardano-crypto-class` `Ed25519DSIGN` that Plutus builtins ultimately call. If a primitive we need is not yet public in `cardano-node-clients`, it is patched upstream and pinned as a `source-repository-package` with SHA256, per the repository's constitution rule. `signed_data` byte-layout cross-check is a pure-Haskell test that needs no external primitives.

## Technical Context

**Language/Version**: Haskell GHC 9.10 for all new E2E tests. Aiken 1.1.x (Plutus V3) remains the validator language, but tests target the compiled bytecode via a real node, not via `aiken check`. Node 20 remains the phone-side signer and fixture producer.
**Primary Dependencies** (harvest side):
- `cardano-node-clients:devnet` (sub-library with `public` visibility) — `withDevnet` bracket, `mkSignKey`, `deriveVerKeyDSIGN`, `addKeyWitness`, `submitTx`.
- `cardano-node-clients` (main library) — already in `build-depends`. Provides `TxBuild`, `Evaluate.evaluateAndBalance`, `Submitter`, `Provider`, `Ledger`.
- `cardano-crypto-class` via cardano-node-clients re-exports — `Ed25519DSIGN`, `verifyDSIGN` for FR-003's independent verifier step. If the required re-export doesn't exist today, a patch to `cardano-node-clients` adds it; that patch is pinned as a `source-repository-package` with SHA256 in `cabal.project`.
- `hspec` (existing test framework), `base16-bytestring`, `aeson` for fixture ingest.
- The fixture generator uses the existing `Cardano.Groth16.Compress` module.
**Storage**: fixture files under `circuits/build/fixtures/` and `offchain/test/fixtures/` (produced by the previous PR). Devnet runtime directory lives under the test's temp dir via `withDevnet`.
**Testing**: `cabal test` (hspec) invoked via the existing `checks.unit-tests` nix derivation; the devnet bracket spins up inside each test. `checks.aiken-check` keeps the on-chain Aiken unit-test coverage for pure-logic helpers but is no longer where the validator E2E lives. Both derivations are already in `just ci` and the GitHub workflow — FR-005 is satisfied by wiring into existing gates.
**Target Platform**: CI on x86_64-linux via `nix build .#checks.x86_64-linux.unit-tests`; the devnet harness runs cardano-node inside the test process, so the test environment must make the `cardano-node` binary available (same as cardano-node-clients' own e2e tests already require).
**Project Type**: additions to an existing multi-language project (Circom + Aiken + Haskell + Rust FFI). No new top-level project.
**Performance Goals**: devnet startup (~10–20 s) amortised across the scenarios in one test run; each spend tx ≲ 5 s; 1 golden + 4 negatives ≈ 30–60 s added CI time. Budget: well under 2 minutes incremental to current `just ci`.
**Constraints**: tests must consume the authoritative fixtures (FR-006); no parallel copies; the cardano-node binary must be available in the test derivation's PATH (added to the check's dependencies).
**Scale/Scope**: 1 golden-path test + 4 negative tests via devnet; 1 independent Ed25519 verify + 1 parsing consistency test (no devnet); possibly 1 upstream patch to `cardano-node-clients` to expose Ed25519 primitives in its public surface.

## Constitution Check

**Principle V (Proof Soundness)** — this feature's entire point is to exercise the two-layer binding described in the constitution (Groth16 proof + customer Ed25519 signature). The plan covers all three bindings (d, acceptor_pk, TxOutRef) as positive and negative tests, plus the `pk_c` cross-check. ✅

**Principle IV (Privacy by Default)** — tests use fixture values only, no real user data, no leakage beyond what's already in committed fixtures. ✅

**Principle III (Smart Contract as Trust Layer)** — the primary tests run against the applied validator bytecode, not a re-implemented one. ✅

**Principle VI (Monotonic State)** — out of scope for this feature (spec trie and counter monotonicity not exercised by a single-spend unit test; that belongs to a future multi-spend integration test). No violation.

**No constitution violations.** No Complexity Tracking entries needed.

## Project Structure

### Documentation (this feature)

```text
specs/002-e2e-tests/
├── plan.md              # This file
├── research.md          # Phase 0: Aiken Ed25519 API, byte-layout conventions, fixture-format decisions
├── data-model.md        # Phase 1: Aiken fixture module shape; Haskell parsing helper type
├── quickstart.md        # Phase 1: how to run the new tests locally
├── contracts/           # Phase 1: canonical signed_data byte layout contract
│   └── signed-data-layout.md
├── checklists/
│   └── requirements.md  # Spec quality checklist (already produced)
└── tasks.md             # Phase 2 output (/speckit.tasks)
```

### Source Code (repository root)

```text
offchain/
├── harvest.cabal                         # MODIFIED — add cardano-node-clients:devnet to test-suite deps
├── src/                                  # unchanged
└── test/
    ├── Main.hs                           # existing
    ├── Groth16Spec.hs                    # existing
    ├── E2ESpec.hs                        # existing
    ├── DevnetSpendSpec.hs                # NEW — spin up devnet, submit real spend tx, observe accept/reject (golden + 4 negatives)
    ├── Ed25519Spec.hs                    # NEW — independent Ed25519 verify of fixture bundle via cardano-node-clients re-export
    └── SignedDataLayoutSpec.hs           # NEW — parse phone bytes, assert each field matches customer.json

cabal.project                             # NEW (if not already present) — source-repository-package for any cardano-node-clients patch

onchain/                                  # unchanged
circuits/                                 # unchanged
```

**Structure Decision**: adds exactly three Haskell test modules (`DevnetSpendSpec`, `Ed25519Spec`, `SignedDataLayoutSpec`). No new executables, no new generated files, nothing on-chain changes. All tests live in `offchain/test/` and run under the existing `checks.unit-tests` nix derivation. The derivation is updated to include `cardano-node` on PATH (same pattern as cardano-node-clients' own e2e test).

**Patch flow**: if during implementation `cardano-node-clients` is found to not expose an Ed25519 primitive we need (for FR-003's independent verifier), the patch is prepared in `/code/cardano-node-clients`, opened as a PR there, and pinned here via `cabal.project`'s `source-repository-package` with a SHA256 hash computed via `nix flake prefetch`. The constitution rule about pins-main-only applies: the pin must target the merged main commit, not a feature branch.

**Fixture refresh flow** (documented in `quickstart.md`): regenerate circuit fixtures (`node circuits/generate_fixtures.js`), copy outputs to `offchain/test/fixtures/`, run `just ci`. No generated source to sync; the Haskell tests read the JSON/hex fixtures directly.

## Complexity Tracking

No constitutional violations or simpler-alternative rejections to record. The plan adds strictly additive tooling (one executable, one generated module, test modules) alongside existing conventions; no architectural changes.
