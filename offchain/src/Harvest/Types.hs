-- | Voucher on-chain types with ToData / FromData instances matching the Aiken encoding.
module Harvest.Types (
    VoucherDatum (..),
    SpendRedeemer (..),
    RedeemRedeemer (..),
    Groth16Proof (..),
    CoalitionDatum (..),
    GovernanceRedeemer (..),
) where

import Data.ByteString (ByteString)
import qualified PlutusCore.Data as PLC
import PlutusTx.Builtins.Internal (BuiltinData (..))
import PlutusTx.IsData.Class (FromData (..), ToData (..))

{- | On-chain state per (user, shop, reificator).

Aiken: @Constr 0 [Int user_id, Int commit_spent, Bytes shop_pk, Bytes reificator_pk]@
-}
data VoucherDatum = VoucherDatum
    { vdUserId :: Integer
    , vdCommitSpent :: Integer
    , vdShopPk :: ByteString
    , vdReificatorPk :: ByteString
    }

instance ToData VoucherDatum where
    toBuiltinData (VoucherDatum uid cs shop reif) =
        BuiltinData $
            PLC.Constr 0 [PLC.I uid, PLC.I cs, PLC.B shop, PLC.B reif]

instance FromData VoucherDatum where
    fromBuiltinData (BuiltinData d) = case d of
        PLC.Constr 0 [PLC.I uid, PLC.I cs, PLC.B shop, PLC.B reif] ->
            Just (VoucherDatum uid cs shop reif)
        _ -> Nothing

{- | Coalition-metadata registry datum.

Aiken: @Constr 0 [List Bytes shop_pks, List Bytes reificator_pks, Bytes issuer_pk]@
-}
data CoalitionDatum = CoalitionDatum
    { cdShopPks :: [ByteString]
    , cdReificatorPks :: [ByteString]
    , cdIssuerPk :: ByteString
    }

instance ToData CoalitionDatum where
    toBuiltinData (CoalitionDatum shops reifs issuer) =
        BuiltinData $
            PLC.Constr
                0
                [ PLC.List (map PLC.B shops)
                , PLC.List (map PLC.B reifs)
                , PLC.B issuer
                ]

instance FromData CoalitionDatum where
    fromBuiltinData (BuiltinData d) = case d of
        PLC.Constr 0 [PLC.List shops, PLC.List reifs, PLC.B issuer] -> do
            ss <- traverse unB shops
            rs <- traverse unB reifs
            Just (CoalitionDatum ss rs issuer)
        _ -> Nothing
      where
        unB (PLC.B b) = Just b
        unB _ = Nothing

{- | Governance redeemer for the coalition-metadata validator.

Aiken:

@
  Constr 0 [Bytes target_pk, Bytes issuer_sig]  -- AddShop
  Constr 1 [Bytes target_pk, Bytes issuer_sig]  -- AddReificator
  Constr 2 [Bytes target_pk, Bytes issuer_sig]  -- RevokeReificator
@
-}
data GovernanceRedeemer
    = AddShop ByteString ByteString
    | AddReificator ByteString ByteString
    | RevokeReificator ByteString ByteString

instance ToData GovernanceRedeemer where
    toBuiltinData r = BuiltinData $ case r of
        AddShop tgt sig -> PLC.Constr 0 [PLC.B tgt, PLC.B sig]
        AddReificator tgt sig -> PLC.Constr 1 [PLC.B tgt, PLC.B sig]
        RevokeReificator tgt sig -> PLC.Constr 2 [PLC.B tgt, PLC.B sig]

instance FromData GovernanceRedeemer where
    fromBuiltinData (BuiltinData d) = case d of
        PLC.Constr 0 [PLC.B tgt, PLC.B sig] -> Just (AddShop tgt sig)
        PLC.Constr 1 [PLC.B tgt, PLC.B sig] -> Just (AddReificator tgt sig)
        PLC.Constr 2 [PLC.B tgt, PLC.B sig] -> Just (RevokeReificator tgt sig)
        _ -> Nothing

{- | Redeemer for a redemption transaction.

Aiken: @Constr 0 [Bytes reificator_sig]@

The reificator signs @own_ref.transaction_id || "REDEEM"@ (38 bytes)
under the datum's @reificator_pk@.
-}
newtype RedeemRedeemer = RedeemRedeemer
    { rrReificatorSig :: ByteString
    -- ^ Ed25519 signature (64 bytes)
    }

instance ToData RedeemRedeemer where
    toBuiltinData (RedeemRedeemer sig) =
        BuiltinData $
            PLC.Constr 0 [PLC.B sig]

instance FromData RedeemRedeemer where
    fromBuiltinData (BuiltinData d) = case d of
        PLC.Constr 0 [PLC.B sig] -> Just (RedeemRedeemer sig)
        _ -> Nothing

{- | Groth16 proof: three compressed BLS12-381 curve points.

Aiken: @Constr 0 [Bytes a, Bytes b, Bytes c]@
-}
data Groth16Proof = Groth16Proof
    { gpA :: ByteString
    -- ^ G1 element (48 bytes)
    , gpB :: ByteString
    -- ^ G2 element (96 bytes)
    , gpC :: ByteString
    -- ^ G1 element (48 bytes)
    }

instance ToData Groth16Proof where
    toBuiltinData (Groth16Proof a b c) =
        BuiltinData $
            PLC.Constr 0 [PLC.B a, PLC.B b, PLC.B c]

{- | Redeemer for a spend transaction.

Aiken: @Constr 0 [Int d, Int commit_spent_new, Int issuer_ax, Int issuer_ay,
Int pk_c_hi, Int pk_c_lo, Bytes customer_pubkey, Bytes customer_signature,
Bytes signed_data, Groth16Proof]@
-}
data SpendRedeemer = SpendRedeemer
    { srD :: Integer
    , srCommitSpentNew :: Integer
    , srIssuerAx :: Integer
    , srIssuerAy :: Integer
    , srPkcHi :: Integer
    , srPkcLo :: Integer
    , srCustomerPubkey :: ByteString
    , srCustomerSignature :: ByteString
    , srSignedData :: ByteString
    , srProof :: Groth16Proof
    }

instance ToData SpendRedeemer where
    toBuiltinData
        ( SpendRedeemer
                d
                csn
                iax
                iay
                pkHi
                pkLo
                pkC
                sigC
                signedData
                proof
            ) =
            let BuiltinData proofData = toBuiltinData proof
             in BuiltinData $
                    PLC.Constr
                        0
                        [ PLC.I d
                        , PLC.I csn
                        , PLC.I iax
                        , PLC.I iay
                        , PLC.I pkHi
                        , PLC.I pkLo
                        , PLC.B pkC
                        , PLC.B sigC
                        , PLC.B signedData
                        , proofData
                        ]
