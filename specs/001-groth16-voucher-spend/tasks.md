# Tasks: Voucher Spend

**Input**: Design documents from `/specs/001-groth16-voucher-spend/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Migrate existing code from cardano-bbs-next, establish project structure, nix flake.

- [ ] T001 Create flake.nix with dev shell providing ghc, cabal, cargo, circom, nodejs, aiken in `/flake.nix`
- [ ] T002 Create justfile with recipes for build-ffi, build-offchain, build-onchain, test-offchain, test-onchain, format-check in `/justfile`
- [ ] T003 [P] Migrate Circom circuit from cardano-bbs-next to `/circuits/voucher_spend.circom`
- [ ] T004 [P] Migrate snarkjs proof generation script to `/circuits/generate_proof.js` and `/circuits/package.json`
- [ ] T005 [P] Migrate Aiken validator and types to `/onchain/validators/voucher_spend.ak` and `/onchain/lib/voucher/`
- [ ] T006 [P] Migrate Rust FFI crate to `/offchain/cbits/groth16-ffi/`
- [ ] T007 [P] Migrate Haskell modules to `/offchain/src/Cardano/Groth16/`
- [ ] T008 [P] Migrate Haskell tests to `/offchain/test/Groth16Spec.hs`
- [ ] T009 Create CI workflow in `/.github/workflows/ci.yml` (build gate + build + test + format + lint)
- [ ] T010 Run trusted setup and commit verification_key.json to `/circuits/build/verification_key.json`
- [ ] T011 Verify all existing tests pass: `just test-offchain` (9/9 Groth16Spec) and `just test-onchain` (aiken check)

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Extend the circuit with EdDSA signature verification and user identity binding. These are required before any user story can be fully implemented.

- [ ] T012 Validate Aiken Groth16 verifier against external test vectors from ak-381 (3_fac circuit) and plutus-groth (3 test cases) in `/onchain/tests/groth16_vectors.ak`
- [ ] T013 Add EdDSA signature verification to circuit: include circomlib EdDSAVerifier in `/circuits/voucher_spend.circom`
- [ ] T013 Add user identity binding to circuit: constraint `user_id == Poseidon(user_secret)` in `/circuits/voucher_spend.circom`
- [ ] T014 Add issuer public key as private input to circuit, verify certificate signature over `(user_id, cap)` in `/circuits/voucher_spend.circom`
- [ ] T015 Recompile circuit with `--prime bls12381`, verify constraint count is acceptable (<10000) in `/circuits/build/`
- [ ] T016 Re-run trusted setup for updated circuit in `/circuits/build/`
- [ ] T017 Update generate_proof.js to include EdDSA key generation, signing, and the new private inputs in `/circuits/generate_proof.js`
- [ ] T018 Verify proof round-trip with full circuit (EdDSA + Poseidon + range check): `node generate_proof.js` outputs VALID
- [ ] T019 Update Aiken VoucherDatum to include user_id field in `/onchain/lib/voucher/types.ak`
- [ ] T020 Update Aiken validator to pass user_id as part of public inputs or verify it from datum in `/onchain/validators/voucher_spend.ak`
- [ ] T021 Verify Aiken compiles: `aiken build` with voucher_spend in plutus.json

---

## Phase 3: User Story 1 — Spend Vouchers (P1)

**Goal**: A customer with a valid certificate generates a proof and a supermarket submits it on-chain. The committed counter updates.

**Independent Test**: Simulate spend with known values (cap=100, spent=25, d=10). Verify ledger update.

- [ ] T022 [US1] Add cardano-node-clients dependency to `/offchain/cardano-bbs.cabal`
- [ ] T023 [US1] Create transaction construction module: build spend transaction from compressed proof + datum in `/offchain/src/Cardano/Groth16/Transaction.hs`
- [ ] T024 [US1] Create transaction submission module: submit via cardano-node-clients in `/offchain/src/Cardano/Groth16/Submit.hs`
- [ ] T025 [US1] Create end-to-end test: generate proof → compress → serialize → build tx → submit to preprod in `/offchain/test/E2E/SpendSpec.hs`
- [ ] T026 [US1] Deploy voucher_spend validator to preprod testnet
- [ ] T027 [US1] Create initial user UTXO on preprod with datum (user_id, commit_spent=Poseidon(0, r))
- [ ] T028 [US1] Submit spend transaction on preprod, verify counter updates

---

## Phase 4: User Story 2 — Cross-Member Spending (P1)

**Goal**: A voucher issued by member A is spent through a submission by member B.

**Independent Test**: Issue certificate from issuer A, submit spend through member B's wallet, verify issuer A's entry updates.

- [ ] T029 [US2] Add coalition accepted list as reference input to validator in `/onchain/validators/voucher_spend.ak`
- [ ] T030 [US2] Create coalition list datum type (list of issuer verification keys + EdDSA public keys) in `/onchain/lib/voucher/types.ak`
- [ ] T031 [US2] Update validator to check issuer's VK is in the coalition list reference input in `/onchain/validators/voucher_spend.ak`
- [ ] T032 [US2] Update circuit to include issuer identification that the validator can match against the coalition list
- [ ] T033 [US2] Test: create two issuer key pairs, deploy coalition list with both, spend from issuer A through issuer B's wallet on preprod
- [ ] T034 [US2] Test: attempt spend from an issuer NOT in the coalition list, verify rejection

---

## Phase 5: User Story 3 — Supermarket Submits for Customer (P1)

**Goal**: The transaction succeeds with only the supermarket's signature, not the user's.

**Independent Test**: Generate proof offline, submit signed only by supermarket wallet, verify success.

- [ ] T035 [US3] Verify validator does not require user signature (no extra_signatories check for user) in `/onchain/validators/voucher_spend.ak`
- [ ] T036 [US3] Update transaction construction to sign with supermarket key only in `/offchain/src/Cardano/Groth16/Transaction.hs`
- [ ] T037 [US3] Test: submit spend transaction signed only by supermarket, verify acceptance on preprod

---

## Phase 6: User Story 4 — Multiple Spends Over Time (P2)

**Goal**: Sequential spends accumulate correctly, each proof builds on the previous committed counter.

**Independent Test**: Spend 10, then 20, then 15 from cap=100, verify final counter = 45.

- [ ] T038 [US4] Create sequential spend test: three spends from same user, verify each counter update in `/offchain/test/E2E/SequentialSpendSpec.hs`
- [ ] T039 [US4] Test: attempt spend exceeding remaining balance, verify proof generation fails
- [ ] T040 [US4] Test: verify on-chain state after each spend matches expected commitment

---

## Phase 7: User Story 5 — Multi-Issuer Spend (P3)

**Goal**: Spend from multiple issuers in a single transaction.

**Independent Test**: Spend 30 from issuer A and 20 from issuer B in one transaction, verify both counters update.

- [ ] T041 [US5] Update validator to accept multiple spend proofs in a single transaction in `/onchain/validators/voucher_spend.ak`
- [ ] T042 [US5] Update transaction construction to include multiple redeemers (one per issuer) in `/offchain/src/Cardano/Groth16/Transaction.hs`
- [ ] T043 [US5] Test: multi-issuer spend on preprod, verify both counters update atomically
- [ ] T044 [US5] Test: multi-issuer spend where one issuer's cap would be exceeded, verify entire transaction fails

---

## Phase 8: Polish & Cross-Cutting

**Purpose**: Documentation, CI hardening, cleanup.

- [ ] T045 Update README.md with project overview and quickstart link
- [ ] T046 Verify CI passes on all jobs (build gate, build, test, format, lint)
- [ ] T047 Remove any BBS-specific code that was migrated but is not needed

---

## Dependencies

```
Phase 1 (Setup) → Phase 2 (Foundational) → Phase 3 (US1: Spend)
                                          → Phase 4 (US2: Cross-Member) [needs US1]
                                          → Phase 5 (US3: No User Wallet) [needs US1]
                                          → Phase 6 (US4: Sequential) [needs US1]
                                          → Phase 7 (US5: Multi-Issuer) [needs US2]
                                          → Phase 8 (Polish) [needs all]
```

## Parallel Opportunities

- **Phase 1**: T003-T008 can all run in parallel (independent file migrations)
- **Phase 3-5**: US1, US2, US3 share the same foundation but US2 and US3 build on US1's transaction infrastructure
- **Phase 6**: Independent once US1 is complete
- **Phase 7**: Independent once US2 is complete

## Implementation Strategy

**MVP**: Phase 1 + Phase 2 + Phase 3 (User Story 1). A single-issuer spend that works end-to-end on preprod. This proves the protocol works.

**Increment 2**: Phase 4 + Phase 5 (cross-member + no user wallet). This proves the coalition model.

**Increment 3**: Phase 6 + Phase 7 (sequential + multi-issuer). Full protocol.

**Total tasks**: 47
- Setup: 11
- Foundational: 10
- US1 (Spend): 7
- US2 (Cross-Member): 6
- US3 (No Wallet): 3
- US4 (Sequential): 3
- US5 (Multi-Issuer): 4
- Polish: 3
