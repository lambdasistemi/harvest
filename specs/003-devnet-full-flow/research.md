# Phase 0 Research: Devnet End-to-End Full Protocol Flow

This document resolves the unknowns raised by the feature spec before
Phase 1 design begins. Each decision carries its rationale and the
alternatives rejected, per the speckit workflow.

## D1. Reuse the `withDevnet` bracket verbatim

**Decision**: use the `withDevnet` bracket from
`Cardano.Node.Client.E2E.Setup` (already wired into this project by
#15) as-is for every one of the four new spec files. Each spec owns
its own bracket, not a shared one.

**Rationale**: the bracket is merged and working. The spec files are
independent per SC-003 (each story must remain green in isolation). A
per-spec bracket keeps the modules self-contained and avoids the
cross-file state footgun documented in `specs/002-e2e-tests/research.md`
§D2. The ~15 s startup cost per file is acceptable inside the 2×
budget (SC-002).

**Alternatives rejected**:
- One shared devnet across all four spec files: breaks SC-003 and
  couples module ordering to test outcomes.
- Restart devnet between each scenario inside a single file: loses
  the amortisation that makes the existing #15 pattern viable.

## D2. Keep the fixture generator; extend it for a second customer and a second certificate

**Decision**: extend `circuits/generate_fixtures.js` (the existing
snarkjs-driven producer) to emit:
- A **second customer** `c2` with its own `user_secret`, Ed25519
  keypair, and spend bundle — used by Story 4 to produce a rejection
  under a revoked reificator.
- A **second cap certificate for `c1`** signed by the issuer with a
  higher cap, used by Story 2 after redemption.
- A **per-certificate signed-data + proof** binding the new cap —
  produced in the same Node signer that #15 uses.

No new fixture-generation toolchain. The existing JSON/hex files remain
the single source of truth.

**Rationale**: Story 2's "topup-after-redemption" requires a fresh cap
certificate, and Story 4's rejection requires a second customer spend
bundle whose only variable is the authorising reificator (so the
negative can isolate revocation as the cause of rejection). Both can be
produced by the same deterministic pipeline as the #15 fixtures without
changing its structure.

**Alternatives rejected**:
- Generate the second customer's keys at runtime in Haskell and sign
  with them: possible, but then the "Ed25519 sig is produced on the
  user's phone" narrative drifts between Story 1 (Node) and Story 4
  (Haskell). Keeping the producer single-source is worth the small
  extension cost.
- Load a pre-existing multi-customer fixture tree from outside the
  repo: rejected — fixtures are part of the audit trail.

## D3. Coalition-metadata UTxO modelled as a single reference input carrying a set datum

**Decision**: the coalition registry lives in **one** script UTxO at a
dedicated validator address whose datum carries `(shop_pks,
reificator_pks, issuer_pk)`. Settlement, redemption, and revert
transactions consume it **only as a reference input** (never spend it).
Shop-onboarding and reificator-revocation transactions **do** consume
it and re-produce it at the same address with the updated datum.

**Rationale**:
- Matches the Lean model scope (per memory file
  `project_harvest_lean_scope.md`): sets and maps, not MPF roots.
- Avoids the MPF / MPFS path entirely, in line with FR-013.
- Reference-input semantics (CIP-31) mean multiple settlement txs
  can read the coalition state concurrently without conflicting on
  the same UTxO — which preserves the "no mediator needed for
  reads" property of MPFS in the prototype at N ∈ {1,2,3}.
- The coalition-governance validator can enforce the signature
  conditions (issuer key for registry mutations) in a straightforward
  Aiken predicate — linear scans over small lists fit comfortably
  within phase-2 budgets.

**Alternatives rejected**:
- Storing each shop / reificator in its own UTxO: scales better but
  the spec explicitly defers scale. Governance tx then has to consume
  N UTxOs — higher tx-size footprint, more script invocations, no
  security gain at N ∈ {1,2,3}.
- Encoding the registry in a minting policy NFT thread: conceptually
  neat but diverges from the "one UTxO holds the state" framing the
  constitution §IX already assumes (just with sets instead of MPF
  roots).
- Off-chain registry queried by oracle: rejected — breaks Principle
  III (smart contract as trust layer).

## D4. Per-customer script UTxO retains the #15 `VoucherDatum` shape, extended

**Decision**: extend `VoucherDatum` to carry `(user_id, commit_spent,
shop_pk, reificator_pk)`. The first two are inherited from #15; the
latter two bind the customer's entry to the shop and reificator that
authorised it — required by Principle V's reificator-authorisation
check and by Story 3's revert authorisation (only the originating
shop can revert).

**Rationale**: the datum is the natural home for role-binding data;
stuffing it in a redeemer would force every settlement to re-derive
bindings that the validator must cross-check. The extension is
additive — existing #15 fixtures continue to work with
`shop_pk = <issuer_pk>, reificator_pk = <reificator_pk>` derived from
the same fixture keys.

**Alternatives rejected**:
- Keep `VoucherDatum` unchanged and derive shop/reificator from the
  coalition datum by scanning for matching entries: not possible
  under Principle III — the validator cannot reverse-look-up who
  authorised an entry without reading that entry.
- Store the role-binding in a separate "authorisation UTxO": doubles
  the UTxO count per customer, no security gain.

## D5. Revert semantics — rebuild the datum with a rolled-back counter

**Decision**: a revert transaction consumes the customer's existing
per-customer script UTxO and re-produces a fresh UTxO at the same
address with `commit_spent` replaced by the **previous** commitment
value (Poseidon-committed). The previous commitment is supplied by the
shop as a redeemer witness; the validator does **not** try to
recompute it from the new `d` because commits are Poseidon hashes, not
plain integers. If the reverted entry was the customer's only
settlement, the revert instead consumes without replacement (identical
to redemption).

**Rationale**: the on-chain representation is a commitment, not a
counter. Rolling back a commitment requires the shop to carry the
prior commitment value (which it can always derive: the shop holds
the certificate history). Forcing the validator to recompute would
require on-chain Poseidon arithmetic that we are not investing in for
the prototype.

**Alternatives rejected**:
- Store the counter history in the datum and revert by popping: fits
  #15's philosophy but blows up the datum size linearly in history
  length, which the spec defers to post-MPF work.
- Store `commit_spent_old` alongside `commit_spent` in the datum:
  gains one revert step but not N. Worse per-byte.

## D6. Mock the reificator as an in-process Ed25519 key, not as a subprocess

**Decision**: every "reificator" in the suite is just an Ed25519
signing key and a funded UTxO — the same pattern #15 uses. No
reificator service, no gRPC, no separate process. The test `IO` does
the signing inline.

**Rationale**: the reificator's *behaviour* from the node's
perspective is fully captured by (a) a key that signs and (b) a
funded UTxO that pays fees. Running a real reificator daemon in the
test process adds deployment complexity without adding any property
the validator will check. Story 4 requires a *revoked* reificator —
which is exercised by letting the test reificator key sign a tx
after its public key has been removed from the coalition datum, and
asserting rejection.

**Alternatives rejected**:
- Spawn a real reificator daemon inside the test: adds a subprocess
  lifecycle to manage alongside `withDevnet`. No observable property
  gained.
- Wire the reificator to the MOOG oracle as a "light" stand-in:
  rejected — out of scope; #9 is explicitly a local prototype.

## D7. Proof generation — reuse #15 fixtures; do not generate proofs in tests

**Decision**: all ZK proofs consumed by the suite are produced
off-line by `circuits/generate_fixtures.js` and committed under
`offchain/test/fixtures/`. Tests do not re-generate proofs at
runtime. Mutation negatives (as in #15) alter bundle bytes, not
proof integers.

**Rationale**: proof generation takes 10–30 s per proof and is
flake-prone; running it per test run would blow the CI budget and
make the suite brittle. Fixture bundles are auditable artefacts
sharing the same refresh story as #15 (see `quickstart.md`).

**Alternatives rejected**:
- Generate proofs per test invocation: impossible under SC-002.
- Use a trivial "always-passes" proof fixture to speed up tests:
  destroys the Principle V assertion. The only proofs we submit are
  real, valid proofs; negatives mutate the non-proof inputs.

## D8. Negative assertions assert on `SubmitResult` constructors, not error text

**Decision**: inherit the #15 convention verbatim. Every rejection is
matched with `shouldSatisfy isRejected`. No `shouldBe "ApplyTxError …"`.

**Rationale**: ledger versions reword errors. Story 4 submits under a
revoked reificator; Story 1's edge cases submit with missing cap
certs; Story 3's edge cases submit reverts for already-redeemed
entries. In every case the story only claims "the validator did not
accept", not "the validator rejected with reason X". This is captured
as SC-005.

**Alternatives rejected**:
- Pin error strings for extra assertion power: flaky, coupled to
  ledger minor versions, explicitly rejected by SC-005.

## D9. Lean twin — contract parity, theorem parity deferred

**Decision**: `contracts/actions.md` enumerates the transition
signatures so the Haskell module `Harvest.Actions` can be authored
as a direct twin of `lean/Harvest/Actions.lean`. The plan does **not**
yet commit to QuickCheck theorem twins; those land in a follow-up
ticket once the Lean proofs compile `sorry`-free.

**Rationale**: the parallel Lean-scaffold agent is sketching the state
machine right now. Pinning signatures is cheap and de-risks later
theorem-to-property work. Committing to properties before the proofs
compile risks churn.

**Alternatives rejected**:
- Ship QuickCheck properties now from the provisional Lean theorems:
  rejected — theorem churn before `sorry`-free invalidates properties
  faster than they're written.

## D10. Target Cardano node version is 10.7.1

**Decision**: the node version pinned in the devnet bracket is 10.7.1,
per the user's explicit correction over the 10.7.0 stated in the spec.

**Rationale**: user correction, recorded here so `cabal.project`
and the devnet harness pins match. No behavioural difference expected
vs. 10.7.0 for the validators under test; the pin is for
reproducibility across the harness and the rest of the stack.

## Open items — none

All spec unknowns are resolved. Implementation may proceed to Phase 1
design (data model + contracts + quickstart).
