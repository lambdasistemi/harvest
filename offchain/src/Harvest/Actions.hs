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
) where

import qualified Data.ByteString as BS
import Data.ByteString (ByteString)
import Data.Map.Strict (Map)
import Data.Set (Set)
import qualified Data.Set as Set

-- | Opaque Ed25519 public key.
newtype PubKey = PubKey {unPubKey :: ByteString}
    deriving newtype (Eq, Ord, Show)

-- | Opaque customer identifier (the Poseidon hash of @user_secret@).
newtype UserId = UserId {unUserId :: Integer}
    deriving newtype (Eq, Ord, Show)

-- | Opaque Poseidon commitment. Internal structure is not needed at
-- this abstraction level.
newtype Commit = Commit {unCommit :: Integer}
    deriving newtype (Eq, Ord, Show)

-- | Opaque Ed25519 signature.
newtype Sig = Sig {unSig :: ByteString}
    deriving newtype (Eq, Ord, Show)

-- | Opaque bundle of customer-side proof material (Groth16 proof +
-- Ed25519 signature over @signed_data@). The pure model treats it as
-- a black box; its validity is an abstract predicate resolved by the
-- real validator.
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

-- | Transition rejection reasons — one constructor per validator
-- failure mode.
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
    | otherwise = Right st {hsShops = Set.insert shop (hsShops st)}

{- | Governance: add a reificator to the coalition.

Dual of 'addShop' against 'hsReificators'.
-}
addReificator :: PubKey -> Sig -> HarvestState -> Step
addReificator reif sig st
    | not (sigValid sig) = Left IssuerSigInvalid
    | reif `Set.member` hsReificators st = Left ReificatorAlreadyRegistered
    | otherwise =
        Right st {hsReificators = Set.insert reif (hsReificators st)}

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
        Right st {hsReificators = Set.delete reif (hsReificators st)}
