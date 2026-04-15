-- | Compress snarkjs affine coordinates to BLS12-381 compressed form.
module Cardano.Groth16.Compress (
    compressProof,
    compressVK,
) where

import Cardano.Groth16.FFI (compressG1, compressG2)
import Cardano.Groth16.Types (
    CompressedProof (..),
    CompressedVK (..),
    G1Affine (..),
    G2Affine (..),
    SnarkjsProof (..),
    SnarkjsVK (..),
 )
import Data.ByteString (ByteString)

-- | Compress all points in a snarkjs proof.
compressProof :: SnarkjsProof -> IO CompressedProof
compressProof p = do
    a <- compressG1Point (proofA p)
    b <- compressG2Point (proofB p)
    c <- compressG1Point (proofC p)
    pure (CompressedProof a b c)

-- | Compress all points in a snarkjs verification key.
compressVK :: SnarkjsVK -> IO CompressedVK
compressVK vk = do
    alpha <- compressG1Point (vkAlpha vk)
    beta <- compressG2Point (vkBeta vk)
    gamma <- compressG2Point (vkGamma vk)
    delta <- compressG2Point (vkDelta vk)
    ic <- traverse compressG1Point (vkIC vk)
    pure (CompressedVK alpha beta gamma delta ic)

compressG1Point :: G1Affine -> IO ByteString
compressG1Point (G1Affine x y) = compressG1 x y

compressG2Point :: G2Affine -> IO ByteString
compressG2Point (G2Affine x0 x1 y0 y1) = compressG2 x0 x1 y0 y1
