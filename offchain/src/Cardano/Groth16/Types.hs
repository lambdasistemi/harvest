{-# LANGUAGE OverloadedStrings #-}

-- | Types for snarkjs Groth16 proof and verification key JSON.
module Cardano.Groth16.Types (
    SnarkjsProof (..),
    SnarkjsVK (..),
    G1Affine (..),
    G2Affine (..),
    CompressedProof (..),
    CompressedVK (..),
) where

import Data.Aeson (
    FromJSON (..),
    Value (..),
    withArray,
    withObject,
    (.:),
 )
import Data.Aeson.Types (Parser)
import Data.ByteString (ByteString)
import qualified Data.Text as T
import qualified Data.Vector as V

-- | A G1 affine point as two field element integers.
data G1Affine = G1Affine
    { g1x :: Integer
    , g1y :: Integer
    }
    deriving (Show, Eq)

-- | A G2 affine point as four field element integers (Fp2 = c0 + c1*u).
data G2Affine = G2Affine
    { g2x0 :: Integer
    , g2x1 :: Integer
    , g2y0 :: Integer
    , g2y1 :: Integer
    }
    deriving (Show, Eq)

-- | snarkjs proof JSON structure.
data SnarkjsProof = SnarkjsProof
    { proofA :: G1Affine
    , proofB :: G2Affine
    , proofC :: G1Affine
    }
    deriving (Show, Eq)

-- | snarkjs verification key JSON structure.
data SnarkjsVK = SnarkjsVK
    { vkAlpha :: G1Affine
    , vkBeta :: G2Affine
    , vkGamma :: G2Affine
    , vkDelta :: G2Affine
    , vkIC :: [G1Affine]
    }
    deriving (Show, Eq)

-- | Compressed proof (ready for PlutusData).
data CompressedProof = CompressedProof
    { cpA :: ByteString -- 48 bytes
    , cpB :: ByteString -- 96 bytes
    , cpC :: ByteString -- 48 bytes
    }
    deriving (Show, Eq)

-- | Compressed verification key (ready for PlutusData).
data CompressedVK = CompressedVK
    { cvAlpha :: ByteString -- 48 bytes
    , cvBeta :: ByteString -- 96 bytes
    , cvGamma :: ByteString -- 96 bytes
    , cvDelta :: ByteString -- 96 bytes
    , cvIC :: [ByteString] -- 48 bytes each
    }
    deriving (Show, Eq)

-- | Parse a decimal string as Integer.
instance FromJSON G1Affine where
    parseJSON = withArray "G1Affine" $ \arr -> do
        if V.length arr < 2
            then fail "G1Affine: need at least 2 elements"
            else do
                x <- parseCoord (arr V.! 0)
                y <- parseCoord (arr V.! 1)
                pure (G1Affine x y)

instance FromJSON G2Affine where
    parseJSON = withArray "G2Affine" $ \arr -> do
        if V.length arr < 2
            then fail "G2Affine: need at least 2 elements"
            else do
                (x0, x1) <- parseCoordPair (arr V.! 0)
                (y0, y1) <- parseCoordPair (arr V.! 1)
                pure (G2Affine x0 x1 y0 y1)

instance FromJSON SnarkjsProof where
    parseJSON = withObject "SnarkjsProof" $ \o ->
        SnarkjsProof
            <$> o .: "pi_a"
            <*> o .: "pi_b"
            <*> o .: "pi_c"

instance FromJSON SnarkjsVK where
    parseJSON = withObject "SnarkjsVK" $ \o ->
        SnarkjsVK
            <$> o .: "vk_alpha_1"
            <*> o .: "vk_beta_2"
            <*> o .: "vk_gamma_2"
            <*> o .: "vk_delta_2"
            <*> o .: "IC"

-- | Parse a single coordinate (decimal string or number).
parseCoord :: Value -> Parser Integer
parseCoord (String t) = pure (read (T.unpack t))
parseCoord (Number n) = pure (round n)
parseCoord v = fail ("expected coordinate, got: " <> show v)

-- | Parse an Fp2 coordinate pair [c0, c1].
parseCoordPair :: Value -> Parser (Integer, Integer)
parseCoordPair = withArray "Fp2" $ \arr -> do
    if V.length arr < 2
        then fail "Fp2: need 2 elements"
        else do
            c0 <- parseCoord (arr V.! 0)
            c1 <- parseCoord (arr V.! 1)
            pure (c0, c1)
