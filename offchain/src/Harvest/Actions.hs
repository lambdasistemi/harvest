{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

{- |
Module      : Harvest.Actions
Description : Pure state-machine twin of the Aiken validators.

Lean ↔ Haskell twin per
`specs/003-devnet-full-flow/contracts/actions.md`. The Lean side
(`lean/Harvest/Actions.lean`) owns the invariants; this module mirrors
the signatures and guard semantics shape-for-shape.

T008 — state types only (@HarvestState@, @VoucherEntry@, @Reject@,
@Step@, @ProofEvidence@). Transitions are filled in by T013 / T014.
-}
module Harvest.Actions (
    -- * Opaque identifiers
    PubKey (..),
    UserId (..),
    Commit (..),
    Sig (..),
    ProofEvidence (..),

    -- * State
    HarvestState (..),
    VoucherEntry (..),

    -- * Result
    Reject (..),
    Step,

    -- * Coalition governance transitions
    bootstrap,
    addShop,
    addReificator,
    revokeReificator,

    -- * Customer-facing transitions
    settle,
    redeem,
    revert,
) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set

-- | Opaque Ed25519 public key.
newtype PubKey = PubKey {unPubKey :: ByteString}
    deriving newtype (Eq, Ord, Show)

-- | Opaque customer identifier (the Poseidon hash of @user_secret@).
newtype UserId = UserId {unUserId :: Integer}
    deriving newtype (Eq, Ord, Show)

{- | Opaque Poseidon commitment. Internal structure is not needed at
this abstraction level.
-}
newtype Commit = Commit {unCommit :: Integer}
    deriving newtype (Eq, Ord, Show)

-- | Opaque Ed25519 signature.
newtype Sig = Sig {unSig :: ByteString}
    deriving newtype (Eq, Ord, Show)

{- | Opaque bundle of customer-side proof material (Groth16 proof +
Ed25519 signature over @signed_data@). The pure model treats it as
a black box; its validity is an abstract predicate resolved by the
real validator.
-}
newtype ProofEvidence = ProofEvidence {unProofEvidence :: ByteString}
    deriving newtype (Eq, Ord, Show)

-- | Per-customer voucher entry in the off-chain state mirror.
data VoucherEntry = VoucherEntry
    { veCommitSpent :: Commit
    , veShop :: PubKey
    , veReificator :: PubKey
    }
    deriving stock (Eq, Show)

-- | Off-chain mirror of the coalition + per-customer registry.
data HarvestState = HarvestState
    { hsShops :: Set PubKey
    , hsReificators :: Set PubKey
    , hsIssuer :: PubKey
    , hsEntries :: Map UserId VoucherEntry
    }
    deriving stock (Eq, Show)

{- | Transition rejection reasons — one constructor per validator
failure mode.
-}
data Reject
    = ShopAlreadyRegistered
    | ShopNotRegistered
    | ReificatorAlreadyRegistered
    | ReificatorNotRegistered
    | IssuerSigInvalid
    | CustomerSigInvalid
    | CustomerProofInvalid
    | BindingMismatch
    | NoEntryToRedeem
    | NoEntryToRevert
    | WrongShopForRevert
    | WrongReificatorForRedeem
    deriving stock (Eq, Show)

-- | Transition result: either a rejection or a new state.
type Step = Either Reject HarvestState

-- * Signature-validity stub

--
-- The pure twin has no crypto; the on-chain validator is the real
-- gatekeeper. For signature-parity parity only (research D9) the
-- Haskell side treats a 'Sig' as valid iff its underlying
-- 'ByteString' is non-empty. Tests drive rejection paths by passing
-- @Sig mempty@.
sigValid :: Sig -> Bool
sigValid (Sig bs) = not (BS.null bs)

{- | Build an empty 'HarvestState' with the given issuer key.

Mirrors @Transitions.applyCreateCoalition@ on the Lean side. Always
succeeds — on-chain this is the coalition-create transaction and has
no policy gate beyond the signer paying its own fee.
-}
bootstrap :: PubKey -> HarvestState
bootstrap issuer =
    HarvestState
        { hsShops = Set.empty
        , hsReificators = Set.empty
        , hsIssuer = issuer
        , hsEntries = mempty
        }

{- | Governance: add a shop to the coalition.

Rejects with 'IssuerSigInvalid' if the issuer signature is invalid,
or 'ShopAlreadyRegistered' if the shop is already in the registry.
Otherwise inserts @shop@ into 'hsShops'.
-}
addShop :: PubKey -> Sig -> HarvestState -> Step
addShop shop sig st
    | not (sigValid sig) = Left IssuerSigInvalid
    | shop `Set.member` hsShops st = Left ShopAlreadyRegistered
    | otherwise = Right st{hsShops = Set.insert shop (hsShops st)}

{- | Governance: add a reificator to the coalition.

Dual of 'addShop' against 'hsReificators'.
-}
addReificator :: PubKey -> Sig -> HarvestState -> Step
addReificator reif sig st
    | not (sigValid sig) = Left IssuerSigInvalid
    | reif `Set.member` hsReificators st = Left ReificatorAlreadyRegistered
    | otherwise =
        Right st{hsReificators = Set.insert reif (hsReificators st)}

{- | Governance: remove a reificator from the coalition.

Rejects with 'IssuerSigInvalid' on a bad signature, or
'ReificatorNotRegistered' if the key isn't currently registered.
Otherwise deletes @reif@ from 'hsReificators'.
-}
revokeReificator :: PubKey -> Sig -> HarvestState -> Step
revokeReificator reif sig st
    | not (sigValid sig) = Left IssuerSigInvalid
    | reif `Set.notMember` hsReificators st = Left ReificatorNotRegistered
    | otherwise =
        Right st{hsReificators = Set.delete reif (hsReificators st)}

{- | Stub proof-validity predicate mirroring 'sigValid': a
'ProofEvidence' is treated as valid iff its bytestring is non-empty.
Tests drive the rejection path via @ProofEvidence mempty@.
-}
proofValid :: ProofEvidence -> Bool
proofValid (ProofEvidence bs) = not (BS.null bs)

{- | Settlement: mutate state for a successful customer settlement.

Checks — in order of declared rejection:

  * 'ShopNotRegistered' — @shop ∉ hsShops@.
  * 'ReificatorNotRegistered' — @reif ∉ hsReificators@.
  * 'CustomerProofInvalid' — the abstract proof predicate fails.
  * 'BindingMismatch' — if the customer already has an entry, its
    stored @(shop, reificator)@ must match the settlement's.

On success, insert-or-update the entry with the new @commitSpent@.
The pure twin uses a single 'UserId'-keyed map; multi-shop support
would promote the key to @(UserId, PubKey)@ per actions.md.
-}
settle ::
    UserId ->
    -- | Shop the settlement tx binds to.
    PubKey ->
    -- | Reificator submitting the tx.
    PubKey ->
    -- | New commitment for the entry after settlement.
    Commit ->
    -- | Opaque proof + signature bundle.
    ProofEvidence ->
    HarvestState ->
    Step
settle user shop reif commitNew evidence st
    | shop `Set.notMember` hsShops st = Left ShopNotRegistered
    | reif `Set.notMember` hsReificators st = Left ReificatorNotRegistered
    | not (proofValid evidence) = Left CustomerProofInvalid
    | otherwise = case Map.lookup user (hsEntries st) of
        Just existing
            | veShop existing /= shop || veReificator existing /= reif ->
                Left BindingMismatch
        _ ->
            let entry =
                    VoucherEntry
                        { veCommitSpent = commitNew
                        , veShop = shop
                        , veReificator = reif
                        }
             in Right
                    st
                        { hsEntries =
                            Map.insert user entry (hsEntries st)
                        }

{- | Redemption: remove the customer's entry.

Rejections:

  * 'NoEntryToRedeem' — the user has no live entry.
  * 'ReificatorNotRegistered' — the submitting reificator has been
    revoked.
  * 'WrongReificatorForRedeem' — the submitting reificator isn't the
    one that accepted the settlements.
  * 'CustomerSigInvalid' — the attached signature fails the stub.
-}
redeem :: UserId -> PubKey -> Sig -> HarvestState -> Step
redeem user reif sig st =
    case Map.lookup user (hsEntries st) of
        Nothing -> Left NoEntryToRedeem
        Just entry
            | reif `Set.notMember` hsReificators st ->
                Left ReificatorNotRegistered
            | veReificator entry /= reif ->
                Left WrongReificatorForRedeem
            | not (sigValid sig) ->
                Left CustomerSigInvalid
            | otherwise ->
                Right st{hsEntries = Map.delete user (hsEntries st)}

{- | Revert: roll the customer's entry back to a prior commitment.

The prototype models the \"rollback\" branch of revert — update the
stored @commitSpent@ to the supplied @prior@. The \"full removal\"
branch from actions.md is accessible by deleting the entry
out-of-band; the validator accepts both and the shop is responsible
for economic correctness.

Rejections:

  * 'NoEntryToRevert' — the user has no live entry.
  * 'CustomerSigInvalid' — the shop master-key signature stub fails.
-}
revert :: UserId -> Commit -> Sig -> HarvestState -> Step
revert user prior sig st =
    case Map.lookup user (hsEntries st) of
        Nothing -> Left NoEntryToRevert
        Just entry
            | not (sigValid sig) -> Left CustomerSigInvalid
            | otherwise ->
                let entry' = entry{veCommitSpent = prior}
                 in Right
                        st
                            { hsEntries =
                                Map.insert user entry' (hsEntries st)
                            }
