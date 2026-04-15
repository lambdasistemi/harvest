-- | PlutusData serialization for Groth16 voucher types.
module Cardano.Groth16.Serialize (
  groth16ProofToData
, vkToData
, spendRedeemerToData
, voucherDatumToData
, groth16ProofToCBOR
, spendRedeemerToCBOR
, voucherDatumToCBOR
, vkToCBOR
) where

import Cardano.PlutusData (PlutusData (..), encodePlutusData)
import Cardano.Groth16.Types (CompressedProof (..), CompressedVK (..))
import Data.ByteString (ByteString)

-- | Encode a compressed Groth16 proof as PlutusData.
-- Matches Aiken: Constr 0 [Bytes a, Bytes b, Bytes c]
groth16ProofToData :: CompressedProof -> PlutusData
groth16ProofToData p =
  Constr
    0
    [ Bytes (cpA p)
    , Bytes (cpB p)
    , Bytes (cpC p)
    ]

-- | Encode a compressed verification key as PlutusData.
-- Matches Aiken: Constr 0 [Bytes alpha, Bytes beta, Bytes gamma, Bytes delta, List [Bytes ic..]]
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

-- | Encode a spend redeemer as PlutusData.
-- Matches Aiken: Constr 0 [Int d, Int commit_spent_new, Groth16Proof]
spendRedeemerToData :: Integer -> Integer -> CompressedProof -> PlutusData
spendRedeemerToData d commitNew proof =
  Constr
    0
    [ Integer d
    , Integer commitNew
    , groth16ProofToData proof
    ]

-- | Encode a voucher datum as PlutusData.
-- Matches Aiken: Constr 0 [Bytes user_pk, Int commit_spent]
voucherDatumToData :: ByteString -> Integer -> PlutusData
voucherDatumToData userPk commitSpent =
  Constr
    0
    [ Bytes userPk
    , Integer commitSpent
    ]

groth16ProofToCBOR :: CompressedProof -> ByteString
groth16ProofToCBOR = encodePlutusData . groth16ProofToData

spendRedeemerToCBOR :: Integer -> Integer -> CompressedProof -> ByteString
spendRedeemerToCBOR d commitNew proof =
  encodePlutusData (spendRedeemerToData d commitNew proof)

voucherDatumToCBOR :: ByteString -> Integer -> ByteString
voucherDatumToCBOR userPk commitSpent =
  encodePlutusData (voucherDatumToData userPk commitSpent)

vkToCBOR :: CompressedVK -> ByteString
vkToCBOR = encodePlutusData . vkToData
