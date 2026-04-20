# Phase 1 Data Model: Devnet Full-Flow Harness

This document enumerates the entities, UTxO shapes, and redeemer
shapes that cross the on-chain / off-chain boundary in issue #9's
prototype scope. It reflects the research decisions in `research.md`
(D3: set-valued coalition UTxO; D4: extended `VoucherDatum`; D5:
revert semantics).

## Entities

### Coalition-metadata UTxO

A single UTxO at a dedicated validator address
`coalition_metadata.ak`. Carries the full registry. Consumed only by
governance transactions; referenced (never consumed) by settlement,
redemption, and revert transactions.

**Datum**: `CoalitionDatum`

```text
CoalitionDatum
  ├── shop_pks         : Set(Ed25519 pk, 32 bytes)
  ├── reificator_pks   : Set(Ed25519 pk, 32 bytes)
  └── issuer_pk        : Ed25519 pk (32 bytes)
```

- `issuer_pk` is immutable for the life of this prototype; rotating
  the issuer is out of scope (not exercised by any story).
- `shop_pks` grows via shop-onboarding tx (governance), can be
  reverted only by a subsequent governance tx (not a story).
- `reificator_pks` grows via shop-onboarding (binding shop ↔
  reificator is recorded in the per-customer datum at settlement
  time, not in the coalition datum — Story 1 is a single shop, so
  the spec does not require a shop↔reificators mapping on-chain;
  once N > 1 shop we'd promote this to a map rather than a flat
  set). Entries can be removed via reificator-revocation tx (Story 4).

**Aiken encoding**: `Constr 0 [List Bytes, List Bytes, Bytes]` — a
list-encoded set because Aiken lacks native sets; the validator
enforces "no duplicates" at every governance transition.

**On-chain value**: minimum UTxO ADA only. No tokens.

**Address**: script address of the `coalition_metadata` validator,
computed in Haskell by `Harvest.Script.coalitionAddr`.

### Per-customer script UTxO

One UTxO per customer, at the address of `voucher_spend.ak` (the
existing validator, extended by FR-003). Created by the customer's
first settlement; updated by each subsequent settlement at the same
shop; consumed without replacement by redemption; updated with a
rolled-back commit by revert.

**Datum**: `VoucherDatum` (extended from #15)

```text
VoucherDatum
  ├── user_id        : Integer        -- Poseidon hash of user_secret
  ├── commit_spent   : Integer        -- current Poseidon commitment S_curr
  ├── shop_pk        : Bytes (32)     -- the shop this entry is bound to
  └── reificator_pk  : Bytes (32)     -- the reificator that authorised it
```

- `user_id` and `commit_spent` are inherited from #15. Under #9,
  `commit_spent` evolves: each accepted settlement updates it to
  `commit_spent_new` (the proof's public output); revert restores
  it to the pre-settlement value supplied by the shop in the revert
  redeemer.
- `shop_pk` / `reificator_pk` pin the authorisation trail per D4.
  The validator cross-checks these against the coalition ref input
  (both must be present in the appropriate set) and against the
  redeemer (acceptor_pk signed in signed_data must match shop_pk).

**Aiken encoding**: `Constr 0 [Int, Int, Bytes, Bytes]`.

**On-chain value**: minimum UTxO ADA only. No tokens.

**Address**: script address of `voucher_spend`, computed by
`Harvest.Script.scriptAddr` (already present).

### Cap certificate

An off-chain, issuer-signed artefact binding a customer's public key,
user_id, and cap amount for a cycle. Not stored on-chain. Verified
inside the Groth16 circuit's issuer-signature check, which the
validator consumes via the proof — exactly the mechanism from #15,
unchanged.

### Settlement transaction

Submitted by a reificator. Exercises the voucher_spend validator.

**Inputs**:
- The customer's per-customer script UTxO (if any — first settlement
  is non-membership, subsequent are membership per FR-005 / FR-006).
- The reificator's fee UTxO.
- The reificator's collateral UTxO.

**Reference inputs**:
- The coalition-metadata UTxO (read-only — CIP-31).

**Outputs**:
- Replacement per-customer script UTxO with updated `commit_spent`.
- Change back to the reificator.

**Redeemer**: `SpendRedeemer` — unchanged from #15 plus a pointer
field to the coalition ref. The coalition datum is accessed via
`tx.reference_inputs`, not via a redeemer field, so no shape change.

**Validator checks** (in addition to #15's three bindings):
1. Coalition ref input present and at the expected validator address.
2. Redeemer's acceptor belongs to `CoalitionDatum.shop_pks`.
3. Submitting reificator's public key (extracted from tx witness set
   via `ScriptContext`) belongs to `CoalitionDatum.reificator_pks`.
4. Output `VoucherDatum` pins the same `shop_pk` / `reificator_pk`
   as the input (membership case) or as authorised (non-membership).

### Redemption transaction

Submitted by the originating reificator. Consumes the customer's
per-customer script UTxO without a replacement.

**Inputs**:
- The per-customer script UTxO to consume.
- Reificator fee + collateral UTxOs.

**Reference inputs**: coalition-metadata UTxO.

**Outputs**: none at the validator address (the entry is being
removed). Change back to the reificator.

**Redeemer**: `RedeemRedeemer` — a new constructor under the voucher
script, distinguished by `Constr 1`:

```text
RedeemRedeemer
  └── reificator_sig : Bytes (64)     -- Ed25519 sig by reificator over txid
```

The validator checks:
1. Reificator's public key is in `CoalitionDatum.reificator_pks`.
2. Signature verifies against the reificator key pinned in the
   input `VoucherDatum.reificator_pk`.
3. No output at this script address with this `user_id` (can't
   sneak a replacement through).

### Revert transaction

Submitted by the shop's master key (a separate Ed25519 key from the
reificator — see constitution §VII on the key ceremony). Rolls back a
counter.

**Inputs**: per-customer script UTxO + fee UTxO + collateral.
**Reference inputs**: coalition-metadata UTxO.
**Outputs**: either a replacement per-customer UTxO with
`commit_spent` reset to a prior value, or nothing (full removal).

**Redeemer**: `RevertRedeemer` — `Constr 2`:

```text
RevertRedeemer
  ├── prior_commit_spent : Integer    -- the commit value to restore
  └── shop_sig           : Bytes (64) -- Ed25519 sig by shop master key over (txid || prior_commit_spent)
```

Validator checks:
1. Shop master key corresponds to `VoucherDatum.shop_pk` in the input.
2. Signature verifies.
3. If a replacement output is produced, it sits at the same address
   with the same `user_id`, `shop_pk`, `reificator_pk`, and
   `commit_spent = prior_commit_spent`.

### Revocation transaction

Submitted by the coalition (holder of `issuer_pk`, matching the
reference-level `CoalitionDatum.issuer_pk`). Consumes the coalition
UTxO and re-produces it with a `reificator_pk` removed.

**Redeemer**: `GovernanceRedeemer` on the coalition validator:

```text
GovernanceRedeemer
  ├── op          : AddShop | RevokeReificator | AddReificator
  ├── target_pk   : Bytes (32)
  └── issuer_sig  : Bytes (64)        -- Ed25519 sig by issuer_pk over (txid || op_tag || target_pk)
```

Validator checks:
1. `issuer_sig` verifies under `CoalitionDatum.issuer_pk`.
2. Output coalition UTxO is at the same address with the correct
   datum mutation applied (list has one more / one fewer entry, no
   other fields change).

## Derived test-side types

### `Harvest.Actions.HarvestState` (pure-Haskell twin of Lean `Harvest.State`)

```haskell
data HarvestState = HarvestState
    { hsShops         :: Set PubKey
    , hsReificators   :: Set PubKey
    , hsIssuer        :: PubKey
    , hsEntries       :: Map UserId VoucherEntry
    }

data VoucherEntry = VoucherEntry
    { veCommitSpent :: Integer
    , veShop        :: PubKey
    , veReificator  :: PubKey
    }
```

Under Lean this is `Harvest.State`: `{ shops : Finset Key,
reificators : Finset Key, issuer : Key, entries : Finmap UserId
Entry }`. The Haskell `Set`/`Map` are the pure isomorphs.

### `HarvestFlow` harness (offchain/test/HarvestFlow.hs)

Owns the live UTxO references that tests thread through scenarios:

```haskell
data HarvestFlow = HarvestFlow
    { hfCoalitionIn     :: TxIn
    , hfCoalitionOut    :: TxOut ConwayEra
    , hfReificatorFeeIn :: TxIn
    , hfVoucherEntries  :: Map UserId (TxIn, TxOut ConwayEra)
    }
```

`HarvestFlow` is produced by `bootstrapCoalition` at the start of
each spec file and updated after each submitted tx so downstream
scenarios see the current UTxO set. No persistent state across
spec files (per SC-003).

## Invariants asserted by the test harness

1. After shop-onboard, `CoalitionDatum.shop_pks` contains the new
   shop and nothing else changed.
2. After settlement #1 for a given `user_id`, exactly one UTxO
   exists at the voucher address with that `user_id`.
3. After settlement #2 for the same `user_id`, still exactly one
   UTxO at the voucher address with that `user_id`, and its
   `commit_spent` equals the declared `commit_spent_new`.
4. After redemption, zero UTxOs at the voucher address with that
   `user_id`.
5. After revert of a single-settlement entry, zero UTxOs at the
   voucher address with that `user_id` (the full-removal branch).
6. After revert of a multi-settlement entry, one UTxO at the voucher
   address with that `user_id` and `commit_spent ==
   prior_commit_spent`.
7. After reificator-revocation, `CoalitionDatum.reificator_pks` no
   longer contains the revoked key; any subsequent settlement
   redeemed under that key is rejected.

Each invariant is checked by the test via `Provider.queryUTxOs` after
the relevant `Submitter.submitTx`. No invariant is checked via
round-tripping an ADT — the node's view of the UTxO set is the
ground truth.
