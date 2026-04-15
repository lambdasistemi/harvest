-- | PlutusData serialization for Groth16 voucher types.
module Cardano.Groth16.Serialize (
    groth16ProofToData,
    vkToData,
    spendRedeemerToData,
    voucherDatumToData,
    groth16ProofToCBOR,
    spendRedeemerToCBOR,
    voucherDatumToCBOR,
    vkToCBOR,
) where

import Cardano.Groth16.Types (CompressedProof (..), CompressedVK (..))
import Cardano.PlutusData (PlutusData (..), encodePlutusData)
import Data.ByteString (ByteString)

{- | Encode a compressed Groth16 proof as PlutusData.
Matches Aiken: Constr 0 [Bytes a, Bytes b, Bytes c]
-}
groth16ProofToData :: CompressedProof -> PlutusData
groth16ProofToData p =
    Constr
        0
        [ Bytes (cpA p)
        , Bytes (cpB p)
        , Bytes (cpC p)
        ]

{- | Encode a compressed verification key as PlutusData.
Matches Aiken: Constr 0 [Bytes alpha, Bytes beta, Bytes gamma, Bytes delta, List [Bytes ic..]]
-}
vkToData :: CompressedVK -> PlutusData
vkToData vk =
    Constr
        0
        [ Bytes (cvAlpha vk)
        , Bytes (cvBeta vk)
        , Bytes (cvGamma vk)
        , Bytes (cvDelta vk)
        , List (Bytes <$> cvIC vk)
        ]

{- | Encode a spend redeemer as PlutusData.
Matches Aiken: Constr 0 [Int d, Int commit_spent_new, Int issuer_ax, Int issuer_ay, Groth16Proof]
-}
spendRedeemerToData
    :: Integer -> Integer -> Integer -> Integer -> CompressedProof -> PlutusData
spendRedeemerToData d commitNew issuerAx issuerAy proof =
    Constr
        0
        [ Integer d
        , Integer commitNew
        , Integer issuerAx
        , Integer issuerAy
        , groth16ProofToData proof
        ]

{- | Encode a voucher datum as PlutusData.
Matches Aiken: Constr 0 [Int user_id, Int commit_spent]
-}
voucherDatumToData :: Integer -> Integer -> PlutusData
voucherDatumToData userId commitSpent =
    Constr
        0
        [ Integer userId
        , Integer commitSpent
        ]

groth16ProofToCBOR :: CompressedProof -> ByteString
groth16ProofToCBOR = encodePlutusData . groth16ProofToData

spendRedeemerToCBOR
    :: Integer -> Integer -> Integer -> Integer -> CompressedProof -> ByteString
spendRedeemerToCBOR d commitNew issuerAx issuerAy proof =
    encodePlutusData (spendRedeemerToData d commitNew issuerAx issuerAy proof)

voucherDatumToCBOR :: Integer -> Integer -> ByteString
voucherDatumToCBOR userId commitSpent =
    encodePlutusData (voucherDatumToData userId commitSpent)

vkToCBOR :: CompressedVK -> ByteString
vkToCBOR = encodePlutusData . vkToData
