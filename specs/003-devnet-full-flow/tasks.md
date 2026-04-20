# Tasks: Devnet End-to-End Full Protocol Flow

**Input**: Design documents from `/code/harvest-009/specs/003-devnet-full-flow/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/ (all present)

**Tests**: Included. FR-001..FR-010 are test assertions; the contracts/ folder
pins the signatures under test. Test code IS the deliverable for #9 — there is
no non-test Haskell entry point.

**Organization**: By user story. P1 is the MVP (two-settlement happy path).
P2 adds redemption + topup-after-redemption. P3 splits into two orthogonal
stories (revert, revocation) that can land in either order once P1 is green.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: different files, no dependencies on incomplete tasks
- **[Story]**: US1, US2, US3, US4 — maps to spec.md's user stories
- Setup / Foundational / Polish: no story label
- Paths are absolute from the repo root `/code/harvest-009/`

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: on-disk structure and fixture regeneration that every story
consumes.

- [ ] T001 Create skeleton Aiken modules (empty bodies, valid syntax) at `onchain/validators/coalition_metadata.ak`, `onchain/validators/voucher_redeem.ak`, `onchain/validators/voucher_revert.ak`, and `onchain/lib/harvest/coalition_types.ak`
- [ ] T002 [P] Create skeleton Haskell modules at `offchain/src/Harvest/Actions.hs` (module header only, typed `undefined`) and `offchain/test/HarvestFlow.hs` (module header only, typed `undefined`). Register both in `offchain/harvest.cabal` under the test-suite stanza
- [ ] T003 [P] Extend `circuits/generate_fixtures.js` to emit customer `c2` with its own Ed25519 keypair and spend bundle, plus `cert-2` for `c1` (second cap from issuer) — per research D2. Do not invoke the generator yet
- [ ] T004 Run `cd circuits && node generate_fixtures.js` and commit the regenerated `offchain/test/fixtures/*.json` and `offchain/test/fixtures/applied-*.hex` artefacts

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: the pieces every story needs before any story-level test can be
written. Finishing this phase leaves the tree compiling, no test logic yet.

**⚠️ CRITICAL**: No user story work begins until this phase is complete.

### On-chain types and coalition validator

- [ ] T005 Define `CoalitionDatum { issuer_pk, shop_pks, reificator_pks }` and the three `GovernanceRedeemer` constructors (`AddShop` / `AddReificator` / `RevokeReificator`) in `onchain/lib/harvest/coalition_types.ak` per `contracts/coalition-metadata-datum.md` §Datum + §Governance redeemer
- [ ] T006 Implement the `coalition_metadata` spend validator in `onchain/validators/coalition_metadata.ak` per `contracts/coalition-metadata-datum.md` §Validator checks (one input/output at this address, issuer signature verification, sorted+unique list invariants, immutable `issuer_pk`)
- [ ] T007 Extend `onchain/lib/voucher/types.ak` `VoucherDatum` to `{ user_id, commit_spent, shop_pk, reificator_pk }` per `contracts/voucher-datum.md` §Datum — keep the #15 shape wire-compatible by defining the new constructor at `Constr 0` with the extra fields appended (validator reads positionally)

### Off-chain state mirror and harness skeleton

- [ ] T008 Implement pure `Harvest.Actions` state types (`HarvestState`, `VoucherEntry`, `Reject`, `Step`) in `offchain/src/Harvest/Actions.hs` per `contracts/actions.md` §The state and §Result type — no transition bodies yet, all typed `undefined`
- [ ] T009 [P] Add `ToData` / `FromData` instances for the new `CoalitionDatum` and extended `VoucherDatum` in `offchain/src/Harvest/Types.hs`, matching the PlutusData encoding in `contracts/coalition-metadata-datum.md` and `contracts/voucher-datum.md`
- [ ] T010 Expose coalition actor keys (issuer, shop, shop-master, reificator) in `offchain/test/DevnetEnv.hs` — extend the existing actor record, do not replace it. The `#15` single-spend keys must still be reachable under their current names
- [ ] T011 Implement `HarvestFlow` data type and `bootstrapCoalition :: ... -> IO HarvestFlow` in `offchain/test/HarvestFlow.hs` per `data-model.md` §`HarvestFlow` harness. `bootstrapCoalition` submits the coalition-create tx and returns the live `TxIn`/`TxOut` pair
- [ ] T012 Apply the coalition-metadata blueprint via `aiken blueprint apply` and expose it through `Harvest.Script.coalitionAddr` + `coalitionScript`; refresh `offchain/test/fixtures/applied-*.hex` for the coalition script

### Pure transition twins (signature parity only)

- [ ] T013 [P] Implement `bootstrap`, `addShop`, `addReificator`, `revokeReificator` pure transitions in `Harvest.Actions` per `contracts/actions.md`; each returns `Step = Either Reject HarvestState`. No QuickCheck yet (deferred per research D9). This is the Haskell twin of the corresponding Lean definitions in `lean/Harvest/Transitions.lean`
- [ ] T014 [P] Implement `settle`, `redeem`, `revert` pure transitions in `Harvest.Actions` per `contracts/actions.md`. Match the Lean guard semantics: guarded return of the input state, never `error`. The `ProofEvidence` parameter is opaque — define it as `newtype ProofEvidence = ProofEvidence ByteString`

**Checkpoint**: `cabal build all -O0` is green and `aiken build` is green. No test logic yet.

---

## Phase 3: User Story 1 — Customer completes two settlements against a freshly deployed coalition (Priority: P1) 🎯 MVP

**Goal**: demonstrate the full settlement path — coalition bootstrap, shop +
reificator onboarding, first settlement (non-membership branch), second
settlement at the same acceptor (membership branch) — and assert the
resulting on-chain state matches `data-model.md` §Invariants #1–#3.

**Independent Test**: `cabal test harvest-test-suite --test-options="--match DevnetFullFlowSpec"` against a fresh devnet produces a green run with:
- one coalition-metadata UTxO present with the onboarded shop + reificator in its datum
- exactly one voucher UTxO for `c1` with `commit_spent` equal to the Poseidon commit from the second settlement's public inputs

### Tests for User Story 1

- [ ] T015 [US1] Add `DevnetFullFlowSpec` module skeleton at `offchain/test/DevnetFullFlowSpec.hs` with its own `withDevnet` bracket, registered in `offchain/harvest.cabal` test-suite. Follow the #15 `DevnetSpendSpec` layout (per research D1)
- [ ] T016 [US1] Add scenario "coalition bootstraps on empty devnet" in `DevnetFullFlowSpec`: submit coalition-create tx via `HarvestFlow.bootstrapCoalition`, assert via `Provider.queryUTxOs` that exactly one UTxO sits at `coalitionAddr` with an empty-registry datum (invariant #1 of `data-model.md`)
- [ ] T017 [US1] Add scenario "shop + reificator onboard" in `DevnetFullFlowSpec`: submit `AddShop` governance tx, then `AddReificator` governance tx, assert post-datum contains the onboarded keys and nothing else changed
- [ ] T018 [US1] Add scenario "first settlement — non-membership branch" in `DevnetFullFlowSpec`: consume `c1` fixture bundle, submit settlement tx via extended `Harvest.Transaction.spendVoucher`, assert acceptance and invariant #2 (exactly one voucher UTxO for `c1`)
- [ ] T019 [US1] Add scenario "second settlement — membership branch" in `DevnetFullFlowSpec`: consume the voucher UTxO from T018, submit a second settlement at the same acceptor using `c1`'s `cert-1` and the next-counter proof, assert acceptance and invariant #3 (still one voucher UTxO, updated `commit_spent`)
- [ ] T020 [US1] Add negative scenario "settlement rejected when coalition ref input missing" in `DevnetFullFlowSpec` via the `Mutations` framework — builds a settlement tx with no reference input to the coalition, asserts `shouldSatisfy isRejected` (SC-005)

### Implementation for User Story 1

- [ ] T021 [US1] Extend `voucher_spend` validator in `onchain/validators/voucher_spend.ak` to enforce the three additional checks in `contracts/voucher-datum.md` §Validator checks — settlement: coalition ref input present, `shop_pk ∈ shop_pks`, reificator signatory is in `reificator_pks` and matches `datum.reificator_pk`. Backwards-compat: keep the #15 no-coalition-ref path behind a separate validator entry point (per quickstart.md §Run the single-spend baseline from #15)
- [ ] T022 [US1] Extend `Harvest.Transaction.spendVoucher` in `offchain/src/Harvest/Transaction.hs` to plumb the coalition `TxIn` as a reference input and to include the reificator key in `extra_signatories`. Keep the old single-arg signature as a helper that calls the new one with `Nothing`
- [ ] T023 [US1] Apply the updated `voucher_spend` blueprint and refresh `offchain/test/fixtures/applied-voucher-spend.hex`

**Checkpoint**: Story 1 runs end-to-end green. Commit + push. This is the MVP.

---

## Phase 4: User Story 2 — Customer redeems and tops up again after redemption (Priority: P2)

**Goal**: exercise the redemption path and a post-redemption re-settlement
under a fresh cap certificate (`cert-2`). Asserts invariant #4 (voucher UTxO
removed) and the re-creation path.

**Independent Test**: `cabal test harvest-test-suite --test-options="--match DevnetRedeemSpec"` is green, asserting zero voucher UTxOs for `c1` after redemption and exactly one voucher UTxO for `c1` after the post-redemption settlement with the new commit.

### Tests for User Story 2

- [ ] T024 [US2] Add `DevnetRedeemSpec` module skeleton at `offchain/test/DevnetRedeemSpec.hs` with its own `withDevnet` bracket, registered in `offchain/harvest.cabal`
- [ ] T025 [US2] Bootstrap into the Story 1 end state inline in `DevnetRedeemSpec` (same fixtures, same code path — SC-003 requires the spec to be runnable in isolation), then add scenario "reificator redeems c1 entry" — submit redemption tx, assert acceptance and invariant #4 (zero voucher UTxOs for `c1`)
- [ ] T026 [US2] Add scenario "issuer signs cert-2 and c1 re-settles" — submit post-redemption settlement using `cert-2` fixture, assert acceptance and a fresh voucher UTxO for `c1` with `commit_spent` matching the new proof output
- [ ] T027 [US2] Add negative scenario "redemption rejected when reificator is not in registry" — submit redemption tx where the reificator signing key's pk is absent from the coalition datum (use a pre-revocation state), assert `shouldSatisfy isRejected`

### Implementation for User Story 2

- [ ] T028 [US2] Implement the `voucher_redeem` validator in `onchain/validators/voucher_redeem.ak` per `contracts/voucher-datum.md` §Validator checks — redemption: coalition ref input, `reificator_pk ∈ reificator_pks`, exactly one `extra_signatory` matching `datum.reificator_pk`, Ed25519 sig over `txid || "REDEEM"`, and no output at this address with this `user_id`
- [ ] T029 [US2] Add `Harvest.Transaction.redeemVoucher :: HarvestFlow -> UserId -> ReificatorKey -> IO (Tx ConwayEra)` in `offchain/src/Harvest/Transaction.hs` that builds the redemption tx (consume voucher UTxO, no replacement output, reificator sig in `extra_signatories`, coalition ref input)
- [ ] T030 [US2] Apply `voucher_redeem` blueprint; expose via `Harvest.Script.redeemAddr` + `redeemScript`; commit the refreshed `offchain/test/fixtures/applied-voucher-redeem.hex`

**Checkpoint**: Stories 1 and 2 both green in isolation (SC-003). Commit + push.

---

## Phase 5: User Story 3 — Coalition reverts a pending entry using the shop master key (Priority: P3)

**Goal**: exercise the revert path for both the rollback branch (multi-
settlement entry) and the full-removal branch (single-settlement entry).
Asserts invariants #5–#6.

**Independent Test**: `cabal test harvest-test-suite --test-options="--match DevnetRevertSpec"` is green, asserting the `commit_spent` rollback on the happy path and the full-removal behaviour on the edge case.

### Tests for User Story 3

- [ ] T031 [US3] Add `DevnetRevertSpec` module skeleton at `offchain/test/DevnetRevertSpec.hs` with its own `withDevnet` bracket, registered in `offchain/harvest.cabal`
- [ ] T032 [US3] Bootstrap Story 1 end state inline in `DevnetRevertSpec`; add scenario "shop reverts second settlement" — consume the voucher UTxO at the two-settlement state, submit revert tx with `prior_commit_spent` = the first-settlement commit, assert acceptance and invariant #6 (one voucher UTxO with the rolled-back commit)
- [ ] T033 [US3] Add scenario "shop reverts the only settlement (full removal)" — bootstrap to the single-settlement state only, submit revert tx with no replacement output, assert invariant #5 (zero voucher UTxOs for `c1`)
- [ ] T034 [US3] Add negative scenario "revert signed by non-shop key" — shop-master signature replaced by a freshly-generated Ed25519 key, assert `shouldSatisfy isRejected` (SC-005)

### Implementation for User Story 3

- [ ] T035 [US3] Implement the `voucher_revert` validator in `onchain/validators/voucher_revert.ak` per `contracts/voucher-datum.md` §Validator checks — revert: coalition ref, `shop_pk ∈ shop_pks`, exactly one `extra_signatory` matching `datum.shop_pk`, Ed25519 sig over `txid || "REVERT" || prior_bytes`, and the either/or output branch (either no output at this address with this `user_id`, or one output with same bindings and `commit_spent = prior_commit_spent`)
- [ ] T036 [US3] Add `Harvest.Transaction.revertVoucher :: HarvestFlow -> UserId -> Commit -> ShopMasterKey -> RevertBranch -> IO (Tx ConwayEra)` in `offchain/src/Harvest/Transaction.hs` where `RevertBranch = FullRemove | Rollback Commit`. Encode the signed payload exactly as the contract specifies (32-byte BE zero-padded `prior_bytes`)
- [ ] T037 [US3] Apply `voucher_revert` blueprint; expose via `Harvest.Script.revertAddr` + `revertScript`; commit the refreshed `offchain/test/fixtures/applied-voucher-revert.hex`

**Checkpoint**: Stories 1, 2, 3 all green in isolation. Commit + push.

---

## Phase 6: User Story 4 — Reificator is revoked and can no longer authorise settlements (Priority: P3)

**Goal**: exercise the revocation governance path and its downstream effect
on settlement acceptance. Asserts invariant #7.

**Independent Test**: `cabal test harvest-test-suite --test-options="--match DevnetRevocationSpec"` is green, asserting the reificator is removed from the datum and a subsequent settlement under that reificator is rejected.

### Tests for User Story 4

- [ ] T038 [US4] Add `DevnetRevocationSpec` module skeleton at `offchain/test/DevnetRevocationSpec.hs` with its own `withDevnet` bracket, registered in `offchain/harvest.cabal`
- [ ] T039 [US4] Bootstrap through Story 1's onboarding inline in `DevnetRevocationSpec`; add scenario "coalition revokes reificator" — submit governance `RevokeReificator` tx, assert acceptance and the reificator's pk is absent from the post-datum (invariant #7 first clause)
- [ ] T040 [US4] Add scenario "settlement under revoked reificator rejected" — construct a settlement tx from `c2` fixture bundle using the now-revoked reificator key, assert `shouldSatisfy isRejected` (invariant #7 second clause, SC-005)
- [ ] T041 [US4] Add negative scenario "revocation of a key that was never registered is rejected" — submit `RevokeReificator` governance tx for a fresh Ed25519 key, assert `shouldSatisfy isRejected` per `contracts/coalition-metadata-datum.md` §Validator check 6

### Implementation for User Story 4

- [ ] T042 [US4] Add `Harvest.Transaction.governCoalition :: HarvestFlow -> GovOp -> IssuerKey -> IO (Tx ConwayEra)` in `offchain/src/Harvest/Transaction.hs` where `GovOp = AddShop PubKey | AddReificator PubKey | RevokeReificator PubKey`. Builds the coalition-spend tx with the updated list and the correct issuer signature domain-separator (`0x00`/`0x01`/`0x02` per contract)
- [ ] T043 [US4] Thread the existing `voucher_spend` check for `reificator_pk ∈ reificator_pks` (already landed in T021) through this story — no new validator code, only that T040 confirms the check is load-bearing

**Checkpoint**: All four stories green in isolation. Commit + push.

---

## Phase 7: Polish & Cross-Cutting Concerns

- [ ] T044 Update `docs/journey.md` — mark issue #9 as merged (green), remove the dashed-red `#8 → #9` caveat, and point the "where we are right now" section forward to #5 / #6 / #7 / #8
- [ ] T045 [P] Run `just ci` locally end-to-end; confirm `SC-001` (one `cabal test` invocation, zero P1 failures), `SC-002` (within 2× of the #15 suite runtime), `SC-003` (each story green in isolation), `SC-004` (`it` blocks read as a protocol narrative)
- [ ] T046 [P] Run `cd lean && lake build`; confirm the existing theorems in `lean/Harvest/Invariants.lean` still compile `sorry`-free after any signature refinements T013/T014 may have forced back into `lean/Harvest/Transitions.lean` — if Haskell diverged, push the fix to Lean in the same PR per `contracts/actions.md` §Synchronisation protocol
- [ ] T047 Update the PR description on `003-devnet-full-flow` with a tour of changes per each user story, the `data-model.md` invariant numbers each test asserts, and a note on the backwards-compat path for #15's single-spend suite (quickstart.md §Run the single-spend baseline from #15)
- [ ] T048 Invoke merge-guard via `mcp__merge-guard__guard-merge` before merging — NEVER direct `gh pr merge`

---

## Dependencies & Execution Order

### Phase dependencies

- Setup (1) → Foundational (2) → User Stories in priority order
  - US1 (P1) gates US2 / US3 / US4 — all downstream stories extend Story 1's end state
  - US2, US3, US4 are pairwise independent once US1 is green (any order, can parallelise)
- Polish (7) depends on all four stories landing

### Within each user story

- Test skeletons before implementation (documentation-first per FR-012) — note that US1's T015 and T021 can run in parallel only because the spec stub starts with `pendingWith "…"` until T021 lands the validator changes
- Validator (Aiken) must be applied via `aiken blueprint apply` before the off-chain tx builder can load it
- `Harvest.Transaction` changes before `DevnetFooSpec` flips from `pendingWith` to real assertions

### Parallel opportunities

- T002 / T003 in Setup can run parallel to T001
- T009 / T010 / T013 / T014 in Foundational are on disjoint files
- Across stories: US2 (T024–T030), US3 (T031–T037), US4 (T038–T043) can run in parallel once Foundational is done, if multiple contributors are available
- Within a story, the spec scenarios (T016–T020, T025–T027, T032–T034, T039–T041) can be written in parallel because each is a single `it` block in the same file but editing different `describe` subtrees — for a solo agent this is sequential; for multi-agent it's parallel with merge

---

## Parallel example: Phase 2 (Foundational)

```bash
# One agent per bullet:
Task: "Implement Harvest.Actions state types in offchain/src/Harvest/Actions.hs (T008)"
Task: "Add ToData/FromData for new datums in offchain/src/Harvest/Types.hs (T009)"
Task: "Expose coalition actor keys in offchain/test/DevnetEnv.hs (T010)"
# After T008 lands:
Task: "Implement pure bootstrap/add/revoke transitions in Harvest.Actions (T013)"
Task: "Implement pure settle/redeem/revert transitions in Harvest.Actions (T014)"
```

---

## Implementation strategy

### MVP (ship P1 only)

1. Phase 1 + Phase 2 (setup + foundational)
2. Phase 3 (US1) → **stop + validate** → push → open PR → continue on the same branch

### Incremental delivery

- After Phase 3 merges, open a follow-up PR per remaining story: P2, then P3 (revert), then P3 (revocation). Each story's spec file is self-contained so individual PRs are small.
- Do not bundle stories into one mega-PR unless `data-model.md` invariants need to change.

---

## Notes

- `data-model.md` invariants #1–#7 are the authoritative assertions. Each test
  names the invariant number it verifies.
- Negative assertions use `shouldSatisfy isRejected`; never pin error strings (SC-005).
- Every commit on this branch must keep `just ci` green (quickstart.md §Bisect-safe rule).
- Lean ↔ Haskell signature parity is enforced by `contracts/actions.md`
  §Synchronisation protocol. Do not merge a lagging twin.
- MPF / MPFS stay out of scope (FR-013). If you feel the need to touch
  `merkle_patricia_forestry` anywhere in this ticket, stop — that's #5 / #8.
