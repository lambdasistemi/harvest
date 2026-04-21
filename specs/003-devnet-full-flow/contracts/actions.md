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
data CardPair = CardPair
    { cpJubjub  :: PubKey    -- Jubjub EdDSA public key
    , cpEd25519 :: PubKey    -- Ed25519 public key
    }

data HarvestState = HarvestState
    { hsCards       :: Map PubKey [CardPair]  -- shop_pk -> [card pairs]
    , hsIssuer      :: PubKey
    , hsEntries     :: Map UserId VoucherEntry
    }

data VoucherEntry = VoucherEntry
    { veCommitSpent    :: Commit
    , veCardEd25519    :: PubKey    -- the accepting card's Ed25519 key
    }
```

```lean
-- Lean (lean/Harvest/Actions.lean)
structure CardPair where
    jubjub  : Key    -- Jubjub EdDSA public key
    ed25519 : Key    -- Ed25519 public key

structure VoucherEntry where
    commitSpent  : Commit
    cardEd25519  : Key    -- the accepting card's Ed25519 key

structure HarvestState where
    cards       : Finmap Key (List CardPair)  -- shop -> [card pairs]
    issuer      : Key
    entries     : Finmap UserId VoucherEntry
```

`PubKey` (Haskell) ↔ `Key` (Lean) is an abstract type alias; at the
prototype level it is an opaque identifier. `Commit` is likewise
opaque — its internal structure is Poseidon-specific and not needed
at this abstraction. `UserId` is an opaque identifier.

The flat `hsShops` and `hsReificators` sets from the previous model
are replaced by `hsCards`, a map from shop identity to registered
card pairs. Each card pair bundles the two keys that live on the same
secure element. Lookups by `ed25519_pk` across all shops replace the
old `reificator_pk ∈ reificator_pks` check.

## Result type

Each transition returns either a new state or a rejection reason. The
rejection reasons are an enum with one constructor per failure mode
the validator enforces — this keeps the Haskell twin close to the
node's `SubmitResult` granularity without pinning error strings.

```haskell
data Reject
    = ShopAlreadyRegistered
    | ShopNotRegistered
    | CardAlreadyRegistered
    | CardNotRegistered
    | IssuerSigInvalid
    | CustomerSigInvalid
    | CustomerProofInvalid
    | BindingMismatch          -- signed_data.d / pk_c / acceptor_pk / TxOutRef
    | NoEntryToRedeem
    | NoEntryToRevert
    | WrongShopForRevert
    | WrongCardForRedeem

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
- Rejects with `ShopAlreadyRegistered` if `shop ∈ keys hsCards`.
- Otherwise returns `st { hsCards = insert shop [] hsCards }`.

On-chain: governance tx, `Constr 0` on coalition redeemer.

### `addCard`

```haskell
addCard :: PubKey -> CardPair -> Sig -> HarvestState -> Step
-- Lean:
-- def addCard (shop : Key) (card : CardPair) (sig : Sig) (st : HarvestState) : Step
```

- Rejects with `IssuerSigInvalid` on bad signature.
- Rejects with `ShopNotRegistered` if `shop ∉ keys hsCards`.
- Rejects with `CardAlreadyRegistered` if `card.ed25519` or
  `card.jubjub` appears anywhere in the cards map.
- Otherwise appends `card` to `hsCards[shop]`.

On-chain: governance tx, `Constr 1`.

### `revokeCard`

```haskell
revokeCard :: PubKey -> Sig -> HarvestState -> Step
-- Lean:
-- def revokeCard (cardEd25519 : Key) (sig : Sig) (st : HarvestState) : Step
```

- Rejects with `IssuerSigInvalid` on bad signature.
- Rejects with `CardNotRegistered` if `cardEd25519` is not found
  in any shop's card list.
- Otherwise removes the card pair from the shop's list.

On-chain: governance tx, `Constr 2`.

### `settle`

```haskell
settle
    :: UserId
    -> PubKey            -- acceptor card's Ed25519 pk (from signed_data)
    -> Commit            -- commit_spent_new
    -> ProofEvidence     -- opaque; models the Groth16 + Ed25519 bundle
    -> HarvestState
    -> Step
```

Rejections:
- `CardNotRegistered` — `acceptorEd25519` not found in any shop's
  card list in `hsCards`.
- `CustomerProofInvalid` — abstract predicate over `ProofEvidence`.
- `CustomerSigInvalid` — Ed25519 binding fails.
- `BindingMismatch` — signed_data.d / pk_c / acceptor_pk / TxOutRef
  disagree.
- Otherwise:
  - If `user_id ∉ hsEntries`: insert fresh
    `VoucherEntry { commitSpent = commit_new, cardEd25519 = acceptorEd25519 }`.
  - If `user_id ∈ hsEntries` and `cardEd25519` matches: update
    `commitSpent = commit_new`.
  - If `user_id ∈ hsEntries` but existing entry has a different
    `cardEd25519`: *multi-card customer*. At N ∈ {1,2,3} the
    prototype keys entries on `(user_id, card_ed25519_pk)` — see
    §Abstraction note below.

On-chain: settlement tx, `Constr 0` on voucher redeemer.

### `redeem`

```haskell
redeem
    :: UserId
    -> PubKey            -- card's Ed25519 pk submitting
    -> Sig               -- signature under card's Ed25519 key
    -> HarvestState
    -> Step
```

Rejections:
- `NoEntryToRedeem` — `user_id ∉ hsEntries`.
- `CardNotRegistered` — card has been revoked.
- `WrongCardForRedeem` — `cardEd25519 ≠ hsEntries[user].veCardEd25519`.
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
- `WrongShopForRevert` — the shop that owns the entry's
  `veCardEd25519` (looked up in `hsCards`) doesn't match the
  signer.
- `CustomerSigInvalid` — sig doesn't verify.

Success: either delete (if the prior commit is the initial one — full
removal) or update `commitSpent = prior` (rollback). The pure model
chooses whichever branch the caller requests; the validator accepts
both and the shop is responsible for economic correctness.

## Abstraction note: multi-card entries

The prototype's `hsEntries :: Map UserId VoucherEntry` assumes a single
entry per customer. This is sufficient for the #9 stories (N ∈ {1,2,3}
all pick one card per customer). If the stories ever need a customer
with two concurrent cards, promote the key to `(UserId, PubKey)` —
card-scoped. The on-chain representation already supports this
(separate script UTxOs per (user_id, card_ed25519_pk)); only the model
key changes.

The Lean agent and the Haskell twin MUST apply the same key shape. If
one side promotes to a pair-keyed map before the other, the twin is
broken.

## Preservation theorems (deferred to a follow-up ticket)

The following Lean theorems are sketched by the parallel agent; each
maps to a QuickCheck property on the Haskell twin in a later ticket
(not in #9):

- `settle_preserves_card_binding`: if settle succeeds, the resulting
  entry's `cardEd25519` equals the input acceptor card parameter.
- `settle_monotone_commit`: `commitSpent` after settle ≥ `commitSpent`
  before, under the Poseidon commit ordering (abstract).
- `redeem_removes_entry`: if `redeem` succeeds, the entry is absent.
- `revocation_blocks_settle`: after `revokeCard`, any `settle`
  naming that card rejects.
- `revert_only_by_shop`: if `revert` succeeds with signature `sig`,
  `sig` verifies under the shop key that owns the entry's card.

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
