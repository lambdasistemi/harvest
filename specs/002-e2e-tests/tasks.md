---
description: "Dependency-ordered task list for end-to-end tests (issue #15)"
---

# Tasks: End-to-End Tests for Harvest Spending

**Input**: Design documents from `/specs/002-e2e-tests/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/signed-data-layout.md, quickstart.md

**Organization**: tasks are grouped by user story (US1 golden path, US2 tampered rejections, US3 byte-layout cross-check) so each can be developed, reviewed, and merged as an independent MVP increment.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel (different files, no dependencies)
- **[Story]**: user story the task belongs to (US1, US2, US3, or FND for foundational)
- Paths are absolute from the repo root unless noted

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: prepare the test environment and the cardano-node-clients dependency surface.

- [ ] **T001** Audit the public surface of `cardano-node-clients` (main library) and `cardano-node-clients:devnet` for the primitives the harness needs: `withDevnet`, `submitTx`, `Submitter`, `Provider`, `addKeyWitness`, `mkSignKey`, `Ed25519DSIGN`, `verifyDSIGN`. Record in `specs/002-e2e-tests/research.md` as an update to D4 which ones are already exposed and which (if any) require an upstream patch.
  - File: `/code/harvest-015/specs/002-e2e-tests/research.md` (edit D4 open-items section)

- [ ] **T002** [P] Add `cardano-node-clients:devnet` to the `test-suite unit-tests` `build-depends` in `offchain/harvest.cabal`. Confirm the package resolves via nix (no new `source-repository-package` needed at this stage).
  - File: `/code/harvest-015/offchain/harvest.cabal`

- [ ] **T003** [P] Update `flake.nix` so `checks.unit-tests` has `cardano-node` on the test derivation's `buildInputs` / closure. Pin the same version cardano-node-clients' own e2e tests use. Confirm `nix build .#checks.x86_64-linux.unit-tests --no-link` still succeeds with the empty new test file added in T004.
  - File: `/code/harvest-015/flake.nix` (and `/code/harvest-015/nix/checks.nix` if applicable)

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: anything that must be in place before any user story's tests can compile/run. Also absorbs any upstream `cardano-node-clients` patch found necessary in T001.

**⚠️ CRITICAL**: no user story work (T010+) can land until this phase is complete.

- [ ] **T004** Create the three new test module stubs, each exporting a `spec :: Spec` that is empty initially, and wire them into `offchain/test/Main.hs` so hspec discovers them.
  - Files:
    - `/code/harvest-015/offchain/test/DevnetSpendSpec.hs`
    - `/code/harvest-015/offchain/test/Ed25519Spec.hs`
    - `/code/harvest-015/offchain/test/SignedDataLayoutSpec.hs`
    - `/code/harvest-015/offchain/test/Main.hs` (edit to register the new specs)

- [ ] **T005** Write a fixture-loading helper that reads `customer.json`, `public.json`, `proof.json`, `verification_key.json`, `applied-script.hex` from `offchain/test/fixtures/` and produces the `SpendBundle` record defined in `data-model.md`. Compresses proof + VK via existing `Cardano.Groth16.Compress`. Pure `IO`, no side effects beyond file reads.
  - File: new `offchain/test/Fixtures.hs` (test-only module; register in `harvest.cabal`'s `other-modules`)

- [ ] **T006** *(only if T001 flagged gaps)* Patch `cardano-node-clients` to expose the missing Ed25519 primitive from its public surface. Follow D4's flow:
  1. Create a worktree of `/code/cardano-node-clients`.
  2. Minimal public export (prefer extending `Cardano.Node.Client.E2E.Setup`).
  3. Open and merge the upstream PR.
  4. Pin the merged main commit in `cabal.project` via `source-repository-package` with `--sha256:` in nix32 format (per constitution *Pins main only*).
  5. Confirm `just ci` still passes locally with the pin.
  - Files:
    - `/code/cardano-node-clients/...` (upstream changes, separate PR)
    - `/code/harvest-015/cabal.project` (add the pin)

- [ ] **T007** Document the canonical `signed_data` offsets in code as named constants colocated with the parsing logic, so the Haskell parser and the Aiken validator can both reference the same contract. Values from `contracts/signed-data-layout.md`.
  - File: new `offchain/test/SignedDataLayout.hs` (constants + `parseSignedData :: ByteString -> Either String ParsedSignedData`)

**Checkpoint**: test-suite compiles, `cardano-node` runs from the check derivation, fixtures load into a `SpendBundle`, shared parsing helper is ready. User stories US1–US3 can now proceed in parallel.

---

## Phase 3: User Story 3 - Byte-layout cross-check (Priority: P2)

**Goal**: confirm that the five fields (txid, ix, acceptor_ax, acceptor_ay, d) produced by the Node signer match what the Aiken-compatible parser extracts, bit-for-bit. Does NOT require devnet.

**Independent Test**: run `cabal test` and observe `SignedDataLayoutSpec` passes.

Sequenced before US1/US2 because it's the cheapest and proves the fixture's byte layout is sane before we invest in devnet tests on top of the same bytes. If this test fails, the devnet tests will also fail in confusing ways.

- [ ] **T010** [US3] Implement `SignedDataLayoutSpec`:
  - Load `customer.json`, `public.json`.
  - Decode `signed_data_hex` → 106-byte `ByteString`.
  - Call `parseSignedData` from T007; assert success.
  - Assert each parsed field equals the Node-side claim: `txid` matches `customer.json.txid_hex`; `ix` matches `customer.json.ix`; `acceptor_ax`/`acceptor_ay` match the values extracted from `public.json` (at the circuit's public-input positions); `d` matches `public.json[0]` / the `d` recorded elsewhere.
  - One `it` block per field plus one round-trip block for the full parse.
  - File: `/code/harvest-015/offchain/test/SignedDataLayoutSpec.hs`

**Checkpoint US3**: FR-004 and SC-003 delivered. This story is independently shippable.

---

## Phase 4: User Story 1 - Validator accepts a correctly-formed spend (Priority: P1, MVP)

**Goal**: exercise the deployed `voucher_spend` validator with a correctly-produced spend bundle on a real devnet and observe acceptance.

**Independent Test**: run `cabal test` and observe the `DevnetSpendSpec` golden-path test passes.

- [ ] **T020** [US1] Write the devnet fixture setup in `DevnetSpendSpec`:
  - `beforeAll`: start a devnet via `withDevnet`; fund an ephemeral "reificator" Ed25519 key from genesis; deploy a UTXO at the voucher script address carrying `VoucherDatum { user_id = sbUserId, commit_spent = sbCommitSOld }`.
  - `afterAll`: tear down the devnet.
  - Provide helpers: `buildSpendTx :: SpendBundle -> Tx`, `submitAndObserve :: Tx -> IO Verdict` where `Verdict = Accepted | Rejected _`.
  - File: `/code/harvest-015/offchain/test/DevnetSpendSpec.hs`

- [ ] **T021** [US1] Implement the golden-path scenario: load the `SpendBundle` from T005, call `buildSpendTx`, `submitAndObserve`, assert `Verdict == Accepted`.
  - File: `/code/harvest-015/offchain/test/DevnetSpendSpec.hs` (same file, separate `it` block)

- [ ] **T022** [US1] Separately, FR-003 requires an independent Ed25519 verifier test. Implement `Ed25519Spec`:
  - Load `customer.json`; reconstruct `VerKeyDSIGN`, `SigDSIGN`; call `verifyDSIGN` (via cardano-node-clients re-export — patched in T006 if necessary).
  - Positive case: valid bundle → `Right ()`.
  - Negative case: flip one byte of `signed_data_hex` → `Left _`.
  - File: `/code/harvest-015/offchain/test/Ed25519Spec.hs`

**Checkpoint US1**: FR-001, FR-003 delivered; SC-001 catches golden-path regressions.

---

## Phase 5: User Story 2 - Validator rejects a tampered spend (Priority: P1)

**Goal**: exercise each of the four documented rejection reasons with a mutation-paired negative test on the same devnet harness as US1.

**Independent Test**: run `cabal test` and observe each of the four negative tests ends with `Verdict == Rejected _`.

Depends on US1 (T020 shared harness, T021 golden path as the unmutated baseline). Can run after US1's `beforeAll` exists.

- [ ] **T030** [US2] Negative: tampered `signed_data`. In `DevnetSpendSpec`, add `mutateSignedData :: SpendBundle -> SpendBundle` (flip byte at offset 0 of `sbSignedData`, leave signature unchanged). Submit tx built from mutated bundle; assert `Verdict == Rejected _`. Do not match on specific error text.
  - File: `/code/harvest-015/offchain/test/DevnetSpendSpec.hs`

- [ ] **T031** [US2] Negative: `d` cross-check mismatch. Add `mutateDInRedeemer :: SpendBundle -> SpendBundle` (set `sbD := sbD + 1` without re-signing). Submit; assert reject.
  - File: `/code/harvest-015/offchain/test/DevnetSpendSpec.hs`

- [ ] **T032** [US2] Negative: customer-key split mismatch. Add `mutateCustomerPubkey :: SpendBundle -> SpendBundle` (replace `sbCustomerPubkey` with a different 32-byte blob whose hi/lo halves don't equal `sbPkCHi`/`sbPkCLo`). Submit; assert reject.
  - File: `/code/harvest-015/offchain/test/DevnetSpendSpec.hs`

- [ ] **T033** [US2] Negative: TxOutRef not consumed. Build a spend tx whose `tx.inputs` do NOT include `OutputReference(sbTxid, sbIx)` — consume a different UTXO instead. Submit; assert reject.
  - File: `/code/harvest-015/offchain/test/DevnetSpendSpec.hs`

**Checkpoint US2**: FR-002, FR-007, FR-008 delivered; SC-002 catches any disabled validator check.

---

## Phase 6: Polish & Cross-Cutting Concerns

- [ ] **T040** Run the full quality gate locally: `nix build .#checks.x86_64-linux.{aiken-check,circuit,circuit-tests,groth16-ffi,library,unit-tests,lint} --no-link`. Fix any lint or formatting issues surfaced. Must pass before push.
  - Files: as needed

- [ ] **T041** Write the PR description with a guided tour of the new tests (FR mapping, SC mapping, upstream cardano-node-clients patch reference if T006 was needed, devnet cost figures).
  - File: PR description (not in repo)

- [ ] **T042** Verify the standing rule is visible to future contributors: add one sentence to the repo's `README.md` (or `docs/`) noting that every new validator check must come with a mutation-paired negative devnet test, referencing `specs/002-e2e-tests/quickstart.md#adding-a-new-negative-test`.
  - File: `/code/harvest-015/README.md` (one-sentence insertion)

---

## Dependency Graph

```
T001 ──► T006 (conditional)
T002 ─┐                  ┌──► T010 (US3 ready)
T003 ─┼─► T004 ─► T005 ──┼──► T020 ─► T021 (US1 ready)
      │           │      │              └─► T022 (US1 Ed25519)
      │           T007 ──┘              └─► T030 T031 T032 T033 (US2 — after T020, in parallel)
      ▼
    T040 (after T010/T021/T022/T030-T033)
      ▼
    T041, T042
```

## Parallel Execution Suggestions

After Phase 2 completes:

- US3 (T010) can run in parallel with US1 setup (T020).
- US2 tasks (T030–T033) are independent of each other and can be written in parallel once T020 exists.
- Ed25519Spec (T022) is independent of the devnet and can be written any time after T005.

## Completeness Check

| Requirement | Covered by |
|-------------|------------|
| FR-001 validator accepts golden | T021 |
| FR-002 four negative rejections | T030, T031, T032, T033 |
| FR-003 independent Ed25519 verify | T022 |
| FR-004 byte-layout cross-check | T010 |
| FR-005 runs in standard gate | T002, T003, T040 |
| FR-006 uses authoritative fixtures | T005 (single loader) |
| FR-007 no brittle error-message match | T030–T033 (assertions on `Verdict` only) |
| FR-008 positive/negative paired | US2 tasks mutate the unchanged bundle from US1 |
| SC-005 standing rule advertised | T042 |
