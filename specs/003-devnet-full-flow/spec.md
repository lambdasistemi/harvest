# Feature Specification: Devnet End-to-End Full Protocol Flow

**Feature Branch**: `003-devnet-full-flow`
**Created**: 2026-04-20
**Status**: Draft
**Input**: Harvest issue #9 — devnet end-to-end test covering the complete Harvest protocol flow.

## Scope boundary — prototype, not production

This ticket delivers a **working end-to-end prototype** that exercises
every protocol role (coalition, issuer, shop, reificator, customer)
and every flow step (onboard, topup, settle, redeem, revert, revoke)
against a real Cardano devnet.

**Security is not weakened.** Every cryptographic and validator
invariant the constitution requires — proof binding of `d` and
`commit_spent`, customer Ed25519 binding of acceptor_pk and TxOutRef,
issuer cap-certificate binding, enforced reificator authorisation on
settlement txs — holds in this prototype exactly as it holds in the
eventual MPF version.

What this ticket **does not** solve is **scale / usability**:

- Capital efficiency at scale (min-ADA lockup grows linearly in
  customer count).
- Succinct on-chain membership proofs for large sets (linear list
  scan instead of MPF proof).
- Mediated concurrent writes to a shared trie (one registry-update
  transaction at a time, no MPFS mediator).

In short: security has nothing to do with usability. The prototype is
operationally unusable at scale but correct and complete at N ∈
{1,2,3}. Every role becomes a first-class on-chain concept (registry
entries for shops/reificators, enforced reificator authorisation on
settlement txs, shop-bound per-customer entries) so that the full
protocol narrative is expressible in devnet tests. Scale concerns are
explicitly deferred to #5 / #8.

## User Scenarios & Testing *(mandatory)*

Each user story below names an actor in the Harvest protocol and a
journey that can be demonstrated end-to-end against a real Cardano
devnet, as an executable narrative. The stories are prioritised so
that shipping P1 alone is already a meaningful MVP (the full spend
journey from nothing to a second settlement), and each subsequent
priority adds an orthogonal capability on top of the previous
baseline.

### User Story 1 — Customer completes two settlements against a freshly deployed coalition (Priority: P1)

A coalition bootstraps on an empty devnet, onboards a single shop, and
a single customer settles twice at the same acceptor. The second
settlement exercises the update path that the first one could not: the
customer's spend-trie entry already exists and its counter is
incremented. From the perspective of the reificator submitting to the
chain, both transactions are accepted by the validator and the on-chain
state evolves as specified in the constitution.

**Why this priority**: This is the shortest end-to-end path that
actually exercises every constitutional invariant: the ZK proof binding
of `d` and `commit_spent`, the customer's Ed25519 signature binding the
acceptor and TxOutRef, the reificator's authorisation to submit, and —
critically — the membership vs. non-membership branches of the spend
trie. Without this story the devnet harness proves nothing beyond the
single-spend baseline already delivered by #15. Once it is green, every
subsequent story adds one kind of capability on top of a known-good
baseline rather than validating the baseline itself.

**Independent Test**: Running only this story against a freshly-spun
devnet must produce: (a) a coalition-metadata UTxO with an empty
registry datum (no shops, no reificators), (b) one shop and one
reificator observable in the coalition-metadata datum after onboarding,
(c) two accepted settlement transactions in sequence, (d) exactly one
per-customer voucher UTxO whose `commit_spent` equals the Poseidon
commitment declared in the second settlement's public inputs.

**Acceptance Scenarios**:

1. **Given** a fresh devnet and a funded genesis address, **When** the
   coalition-creation transaction is submitted, **Then** the node
   accepts it and a coalition-metadata UTxO with an empty-registry
   datum (no shops, no reificators) is observable at the coalition
   address.

2. **Given** a deployed coalition, **When** a shop-onboarding
   transaction registers `shop_pk` and `reificator_pk`, **Then** the
   node accepts it and the coalition-metadata datum reflects the new
   entries.

3. **Given** a deployed coalition with one registered shop and a
   customer who already holds a signed cap certificate from the
   issuer, **When** the reificator submits the first settlement
   transaction (ZK proof, customer Ed25519 signature over
   `signed_data`, bound to a live TxOutRef), **Then** the validator
   accepts the transaction and a fresh per-customer voucher UTxO
   exists for this customer.

4. **Given** the state after scenario 3, **When** the reificator
   submits a second settlement from the same customer at the same
   acceptor, **Then** the validator accepts the transaction (updating
   the existing per-customer UTxO in place) and the new UTxO's
   `commit_spent` matches the Poseidon commitment declared in the
   settlement's public inputs.

---

### User Story 2 — Customer redeems and tops up again after redemption (Priority: P2)

After completing one or more settlements, the customer requests
redemption at the acceptor. The reificator authorises the removal of
the customer's pending entry. The customer then receives a fresh cap
certificate for the next cycle; the certificate is signed off-line by
the issuer and is usable in a subsequent settlement.

**Why this priority**: Redemption is the exit door of the protocol and
the topup-after-redemption journey closes the loop. Without it the
protocol has no termination for a customer's lifecycle and the devnet
harness cannot demonstrate that the ledger returns to a state in which
a subsequent settlement is possible. Lower priority than P1 because it
depends on the P1 baseline being green, and because a defective
redemption path does not invalidate the P1 settlement assertions.

**Independent Test**: Starting from the final state of User Story 1,
running only this story must produce: (a) a redemption transaction
accepted by the validator that removes the customer's pending spend-
trie entry, (b) a fresh cap certificate derivable off-line and
verifiable by the validator, (c) at least one further settlement
accepted against the new certificate.

**Acceptance Scenarios**:

1. **Given** a spend-trie entry for a customer (outcome of Story 1),
   **When** the reificator submits a redemption transaction signed
   with the reificator key, **Then** the validator accepts the
   transaction and the customer's spend-trie entry is removed.

2. **Given** a redeemed customer, **When** the issuer off-line signs a
   new cap certificate and the customer submits a further settlement,
   **Then** the validator accepts the settlement and the spend trie
   shows a new (or re-created) entry for the customer.

---

### User Story 3 — Coalition reverts a pending entry using the shop master key (Priority: P3)

Before a pending entry is redeemed, the shop holder can use the shop
master key to revert a settlement that was already accepted on-chain
— for instance because a legitimate dispute was raised off-line. The
revert transaction rolls the counter back by exactly the reverted
`d`, or removes the entry entirely if it was the customer's only
settlement.

**Why this priority**: Revert is the recovery path required by the
constitution for dispute resolution. It is lower-priority than
redemption because the happy-path lifecycle can be demonstrated
without it, but it must be covered to give confidence that the
shop retains control of the entries it authorised. Depends on
Story 1 (needs a spend-trie entry to revert).

**Independent Test**: Starting from at least one per-customer voucher
UTxO, running only this story must produce a revert transaction that
the validator accepts, and the resulting voucher UTxO must reflect the
rollback (or be removed entirely).

**Acceptance Scenarios**:

1. **Given** a per-customer voucher UTxO created by Story 1, **When** a
   revert transaction signed by the shop master key is submitted for
   that entry, **Then** the validator accepts it and the voucher UTxO's
   `commit_spent` is rolled back to the shop-supplied prior value (or
   the UTxO is consumed without a replacement, if the reverted
   settlement was the customer's only one).

---

### User Story 4 — Reificator is revoked and can no longer authorise settlements (Priority: P3)

The coalition removes a reificator's key from the registry trie. After
revocation, any settlement transaction submitted under that
reificator's credentials is rejected by the validator.

**Why this priority**: Revocation is the negative control for
reificator trust. It proves that coalition-metadata membership is
load-bearing rather than informational. Depends on Story 1 for a
baseline "settlement is accepted when the reificator is registered"
assertion.

**Independent Test**: Starting from a registered reificator that can
produce accepted settlements, running only this story must produce:
(a) a reificator-removal transaction accepted by the validator, (b) a
subsequent settlement attempt under the revoked reificator rejected by
the validator with any rejection constructor.

**Acceptance Scenarios**:

1. **Given** a reificator currently registered in the coalition-
   metadata datum, **When** the coalition submits a reificator-removal
   transaction for that reificator, **Then** the validator accepts it
   and the coalition-metadata datum no longer contains the
   reificator's public key.

2. **Given** the state after revocation, **When** a settlement is
   submitted whose redeemer references the revoked reificator, **Then**
   the validator rejects the transaction.

---

### Edge Cases

- What happens when the first settlement for a customer is submitted
  but the customer has no cap certificate (or an expired/unsigned one)?
  The validator must reject; covered as an implicit negative for
  Story 1.
- What happens when a redemption is submitted for a customer that has
  no spend-trie entry? The validator must reject (no entry to remove).
- What happens when a revert is submitted but the named entry has
  already been redeemed? The validator must reject (nothing to revert).
- What happens when two reificators attempt concurrent settlements
  against overlapping UTxOs? Out of scope for this ticket — handled
  by MPFS integration under issue #8.
- What happens when the customer's signed_data names a TxOutRef not
  consumed by the tx? Already covered by the #15 negative suite; this
  ticket does not re-assert it.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The test suite MUST bring up a single-node Cardano devnet
  on demand and tear it down when the test run completes, such that
  each test run starts from a known genesis state.

- **FR-002**: The test suite MUST deploy a coalition-metadata UTxO
  whose datum encodes the set of registered shops, the set of
  registered reificators, and the issuer public key. This UTxO acts
  as a protocol-wide registry record, not a scalable trie.

- **FR-003**: The test suite MUST register a shop and its reificator
  via a transaction that updates the coalition-metadata UTxO's datum
  to include their public keys, and MUST assert that the post-
  transaction datum reflects the additions.

- **FR-004**: The test suite MUST produce (or load from fixtures) a
  cap certificate signed off-line by an issuer, such that the
  certificate is verifiable by the validator under the Harvest
  constitution's binding rules.

- **FR-005**: The test suite MUST submit a settlement transaction that
  exercises the spend-trie non-membership branch (first settlement for
  a given customer), built through the shared Harvest transaction
  builder, and MUST assert the validator accepts it without pinning
  the node's error text if any.

- **FR-006**: The test suite MUST submit a second settlement
  transaction that exercises the membership branch (customer already
  has a spend-trie entry), and MUST assert the counter update matches
  the declared `d`.

- **FR-007**: The test suite MUST submit a redemption transaction
  signed by the reificator key and MUST assert the validator accepts
  it and the customer's script UTxO is consumed without a replacement
  produced (i.e., the customer's pending entry is removed).

- **FR-008**: The test suite MUST submit a post-redemption settlement
  against a freshly-issued cap certificate and MUST assert the
  validator accepts it.

- **FR-009**: The test suite MUST submit a revert transaction signed
  with the shop master key and MUST assert the validator accepts it
  and the counter is rolled back by the reverted `d`.

- **FR-010**: The test suite MUST submit a reificator revocation
  transaction that updates the coalition-metadata UTxO's datum to
  remove the reificator's public key, assert the datum reflects the
  removal, then submit a follow-on settlement naming the revoked
  reificator and assert the validator rejects it with any rejection
  constructor.

- **FR-011**: The test suite MUST reuse the devnet bracket, spend-
  scenario builder, and Mutations framework introduced by the
  single-spend E2E work (issue #15, merged).

- **FR-012**: Each "it" block in the test suite MUST name an actor or
  a constitutional invariant in the vocabulary of the Harvest spec,
  and the block body MUST read as a narrative of the protocol step,
  matching the documentation-first style established in
  `DevnetSpendSpec`.

- **FR-013**: The test suite MUST NOT depend on MPF tries or MPFS
  mediation. On-chain membership checks are expressed as linear scans
  over lists carried in the coalition-metadata UTxO's datum, consumed
  as a reference input by settlement transactions. (MPF on-chain —
  issue #5 — and MPFS mediation — issue #8 — are out of scope here
  and will later replace the list-based registry without changing
  the security guarantees.)

- **FR-014**: The test suite MUST NOT exercise multi-certificate
  spend paths (combining caps from multiple issuers); these are
  tracked separately under issue #7.

### Key Entities

- **Coalition-metadata UTxO**: A single protocol-wide UTxO whose
  datum enumerates the registered shops (`shop_pk` list), the
  registered reificators (`reificator_pk` list), and the issuer
  public key. Consumed only by coalition-governance transactions
  (shop onboarding, reificator revocation). Referenced — never
  consumed — by settlement, redemption, and revert transactions.
- **Per-customer script UTxO**: One script UTxO per customer,
  carrying the customer's `user_id` and `commit_spent`, plus the
  `shop_pk` and `reificator_pk` that authorised the customer's
  entry. Consumed and re-produced by each settlement, consumed
  without replacement by redemption.
- **Cap certificate**: Off-line, issuer-signed authorisation binding a
  customer's identity and spending cap for a cycle.
- **Settlement transaction**: Submitted by the reificator on behalf of
  the customer, carrying the ZK proof, Ed25519 customer signature,
  redeemer cross-check values, and a reference to the coalition UTxO.
- **Redemption transaction**: Reificator-signed transaction that
  removes a customer's pending spend-trie entry.
- **Revert transaction**: Shop-master-key-signed transaction that
  decrements a spend-trie counter previously accepted.
- **Revocation transaction**: Coalition-signed transaction that
  removes a reificator from the registry trie.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A single `cabal test` invocation exercises all P1
  scenarios against a freshly-spun devnet and terminates with zero
  failures in the P1 block.

- **SC-002**: Test suite runtime fits within the CI budget established
  by the #15 suite (target: within 2× of the #15 devnet-spec runtime).

- **SC-003**: Each user story's tests remain green when run in
  isolation (i.e., only that story's `it` blocks are selected),
  with no cross-story dependencies beyond the state each story
  explicitly constructs.

- **SC-004**: A new reader of the test suite can understand the
  protocol flow by reading `it` block descriptions top-to-bottom
  without needing to cross-reference implementation files —
  verified by the "E2E as documentation" rule from issue #15.

- **SC-005**: Every negative assertion (Story 4 rejection, edge-case
  rejections) uses `shouldSatisfy isRejected` without pinning the
  node's error text, so that ledger-version wording changes do not
  flake the suite.

## Assumptions

- The single-spend devnet harness delivered by issue #15 is available
  on `main` and can be extended rather than redesigned.
- Fixture tooling (proof generation, Ed25519 signing, cap certificate
  signing) can be extended to produce the additional artefacts each
  new story needs, using the same fixture layout under
  `offchain/test/fixtures/`.
- Off-chain tooling that already exists for issue #15 (cardano-node-
  clients devnet bracket, TxBuild DSL, Harvest.Transaction builder) is
  the baseline for every transaction submitted in this suite; no new
  dependency on `cardano-api` is introduced.
- Target Cardano node version is 10.7.1.
- MPF on-chain (issue #5), MPFS mediation (issue #8), multi-
  certificate spend (issue #7), and v2 privacy redesign (issue #13)
  are out of scope for this ticket. The issue body listed #8 as a
  blocker; this spec overrides that decision because security does
  not depend on scale infrastructure and #15 already shipped along
  this path. When #5 / #8 land, the on-chain registry moves from
  "list carried in a reference UTxO" to "MPF root with membership
  proofs" without changing any of the invariants asserted here.
- Ledger version changes may reword rejection reasons; tests therefore
  assert only on `SubmitResult` constructors, not error strings.
