# Contract: Harvest transition signatures (Lean ↔ Haskell twin)

**Status**: Authoritative for issue #9. The Haskell module
`offchain/src/Harvest/Actions.hs` is a pure twin of the Lean module
`lean/Harvest/Actions.lean` (owned by the parallel Lean-scaffold
agent). Signatures on both sides MUST match shape-for-shape; deviation
is a bug in whichever side diverged last.

This file captures the prototype set-based model (per project memory
`project_harvest_lean_scope.md`). When issues #5 / #8 land, a refined
MPF-based module will be added; this contract remains valid for the
set-based layer as the logical specification even then.

## The state

```haskell
-- Haskell (offchain/src/Harvest/Actions.hs)
data HarvestState = HarvestState
    { hsShops       :: Set PubKey
    , hsReificators :: Set PubKey
    , hsIssuer      :: PubKey
    , hsEntries     :: Map UserId VoucherEntry
    }

data VoucherEntry = VoucherEntry
    { veCommitSpent :: Commit
    , veShop        :: PubKey
    , veReificator  :: PubKey
    }
```

```lean
-- Lean (lean/Harvest/Actions.lean)
structure VoucherEntry where
    commitSpent : Commit
    shop        : Key
    reificator  : Key

structure HarvestState where
    shops       : Finset Key
    reificators : Finset Key
    issuer      : Key
    entries     : Finmap UserId VoucherEntry
```

`PubKey` (Haskell) ↔ `Key` (Lean) is an abstract type alias; at the
prototype level it is an opaque identifier. `Commit` is likewise
opaque — its internal structure is Poseidon-specific and not needed
at this abstraction. `UserId` is an opaque identifier.

## Result type

Each transition returns either a new state or a rejection reason. The
rejection reasons are an enum with one constructor per failure mode
the validator enforces — this keeps the Haskell twin close to the
node's `SubmitResult` granularity without pinning error strings.

```haskell
data Reject
    = ShopAlreadyRegistered
    | ShopNotRegistered
    | ReificatorAlreadyRegistered
    | ReificatorNotRegistered
    | IssuerSigInvalid
    | CustomerSigInvalid
    | CustomerProofInvalid
    | BindingMismatch          -- signed_data.d / pk_c / acceptor_pk / TxOutRef
    | NoEntryToRedeem
    | NoEntryToRevert
    | WrongShopForRevert
    | WrongReificatorForRedeem

type Step = Either Reject HarvestState
```

Lean twin: `inductive Reject | ... ` with the same constructor names;
`abbrev Step := Except Reject HarvestState`.

## Transitions

### `bootstrap`

```haskell
bootstrap :: PubKey -> HarvestState
-- Lean:
-- def bootstrap (issuer : Key) : HarvestState
```

Returns the empty state with the given `issuer`. No failure mode.
On-chain: the coalition-create transaction.

### `addShop`

```haskell
addShop :: PubKey -> Sig -> HarvestState -> Step
-- Lean:
-- def addShop (shop : Key) (sig : Sig) (st : HarvestState) : Step
```

- Rejects with `IssuerSigInvalid` if `sig` doesn't verify under
  `hsIssuer` on the shop-onboard domain.
- Rejects with `ShopAlreadyRegistered` if `shop ∈ hsShops`.
- Otherwise returns `st { hsShops = insert shop hsShops }`.

On-chain: governance tx, `Constr 0` on coalition redeemer.

### `addReificator`

```haskell
addReificator :: PubKey -> Sig -> HarvestState -> Step
```

Same pattern as `addShop` against `hsReificators`. Dual failure modes.
On-chain: governance tx, `Constr 1`.

### `revokeReificator`

```haskell
revokeReificator :: PubKey -> Sig -> HarvestState -> Step
```

- Rejects with `IssuerSigInvalid` on bad signature.
- Rejects with `ReificatorNotRegistered` if `reif ∉ hsReificators`.
- Otherwise returns `st { hsReificators = delete reif hsReificators }`.

On-chain: governance tx, `Constr 2`.

### `settle`

```haskell
settle
    :: UserId
    -> PubKey            -- shop_pk the tx binds to
    -> PubKey            -- reificator_pk submitting
    -> Commit            -- commit_spent_new
    -> ProofEvidence     -- opaque; models the Groth16 + Ed25519 bundle
    -> HarvestState
    -> Step
```

Rejections:
- `ShopNotRegistered` — `shop ∉ hsShops`.
- `ReificatorNotRegistered` — `reif ∉ hsReificators`.
- `CustomerProofInvalid` — abstract predicate over `ProofEvidence`.
- `CustomerSigInvalid` — Ed25519 binding fails.
- `BindingMismatch` — signed_data.d / pk_c / acceptor_pk / TxOutRef
  disagree.
- Otherwise:
  - If `user_id ∉ hsEntries`: insert fresh
    `VoucherEntry { commitSpent = commit_new, shop, reificator }`.
  - If `user_id ∈ hsEntries` and `(shop, reificator)` match the
    existing entry: update `commitSpent = commit_new`.
  - If `user_id ∈ hsEntries` but the existing entry has a different
    `(shop, reificator)`: *this is a multi-shop customer*. At N ∈
    {1,2,3} the prototype models this by keying the entries map on
    `(user_id, shop_pk)` — see §Abstraction note below.

On-chain: settlement tx, `Constr 0` on voucher redeemer.

### `redeem`

```haskell
redeem
    :: UserId
    -> PubKey            -- reificator_pk submitting
    -> Sig               -- signature under reificator key
    -> HarvestState
    -> Step
```

Rejections:
- `NoEntryToRedeem` — `user_id ∉ hsEntries`.
- `ReificatorNotRegistered` — reif has been revoked.
- `WrongReificatorForRedeem` — `reif ≠ hsEntries[user].veReificator`.
- `CustomerSigInvalid` — sig doesn't verify.

Success: `st { hsEntries = delete user_id hsEntries }`.

### `revert`

```haskell
revert
    :: UserId
    -> Commit            -- prior_commit_spent
    -> Sig               -- shop master-key sig
    -> HarvestState
    -> Step
```

Rejections:
- `NoEntryToRevert` — `user_id ∉ hsEntries`.
- `WrongShopForRevert` — shop key doesn't match
  `hsEntries[user].veShop`.
- `CustomerSigInvalid` — sig doesn't verify.

Success: either delete (if the prior commit is the initial one — full
removal) or update `commitSpent = prior` (rollback). The pure model
chooses whichever branch the caller requests; the validator accepts
both and the shop is responsible for economic correctness.

## Abstraction note: multi-shop entries

The prototype's `hsEntries :: Map UserId VoucherEntry` assumes a single
entry per customer. This is sufficient for the #9 stories (N ∈ {1,2,3}
all pick one shop per customer). If the stories ever need a customer
with two concurrent shops, promote the key to `(UserId, PubKey)` —
shop-scoped. The on-chain representation already supports this
(separate script UTxOs per (user_id, shop_pk)); only the model key
changes.

The Lean agent and the Haskell twin MUST apply the same key shape. If
one side promotes to a pair-keyed map before the other, the twin is
broken.

## Preservation theorems (deferred to a follow-up ticket)

The following Lean theorems are sketched by the parallel agent; each
maps to a QuickCheck property on the Haskell twin in a later ticket
(not in #9):

- `settle_preserves_shop_binding`: if settle succeeds, the resulting
  entry's `shop` equals the input shop parameter.
- `settle_monotone_commit`: `commitSpent` after settle ≥ `commitSpent`
  before, under the Poseidon commit ordering (abstract).
- `redeem_removes_entry`: if `redeem` succeeds, the entry is absent.
- `revocation_blocks_settle`: after `revokeReificator`, any `settle`
  naming that reificator rejects.
- `revert_only_by_shop`: if `revert` succeeds with signature `sig`,
  `sig` verifies under the entry's bound `shop` key.

For #9, the plan commits only to signature parity. The QuickCheck
module is filed as a follow-up scope and does not block this ticket.

## Synchronisation protocol

When either side changes a signature:

1. The author updates this document first.
2. The author updates their own side (Lean or Haskell) to match.
3. The author files a cross-repo note in the other side's module
   header pointing at this commit.
4. The other side catches up in a follow-up commit within the same
   PR.

No lagging twin may be merged. Both sides land together or the PR
waits.
