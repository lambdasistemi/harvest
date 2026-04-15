-- | Voucher on-chain types with ToData instances matching the Aiken encoding.
module Cardano.Vouchers.Types (
    VoucherDatum (..)
    , SpendRedeemer (..)
    , Groth16Proof (..)
) where

import Data.ByteString (ByteString)
import qualified PlutusCore.Data as PLC
import PlutusTx.IsData.Class (ToData (..))
import PlutusTx.Builtins.Internal (BuiltinData (..))

-- | On-chain state per user.
--
-- Aiken: @Constr 0 [Int user_id, Int commit_spent]@
data VoucherDatum = VoucherDatum
    { vdUserId :: Integer
    , vdCommitSpent :: Integer
    }

instance ToData VoucherDatum where
    toBuiltinData (VoucherDatum uid cs) =
        BuiltinData
            $ PLC.Constr 0 [PLC.I uid, PLC.I cs]

-- | Groth16 proof: three compressed BLS12-381 curve points.
--
-- Aiken: @Constr 0 [Bytes a, Bytes b, Bytes c]@
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
        BuiltinData
            $ PLC.Constr 0 [PLC.B a, PLC.B b, PLC.B c]

-- | Redeemer for a spend transaction.
--
-- Aiken: @Constr 0 [Int d, Int commit_spent_new, Int issuer_ax, Int issuer_ay, Groth16Proof]@
data SpendRedeemer = SpendRedeemer
    { srD :: Integer
    , srCommitSpentNew :: Integer
    , srIssuerAx :: Integer
    , srIssuerAy :: Integer
    , srProof :: Groth16Proof
    }

instance ToData SpendRedeemer where
    toBuiltinData (SpendRedeemer d csn iax iay proof) =
        let BuiltinData proofData = toBuiltinData proof
        in  BuiltinData
                $ PLC.Constr
                    0
                    [ PLC.I d
                    , PLC.I csn
                    , PLC.I iax
                    , PLC.I iay
                    , proofData
                    ]
