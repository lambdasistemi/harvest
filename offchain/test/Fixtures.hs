{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

{- |
Module      : Fixtures
Description : Load authoritative E2E fixtures as a single 'SpendBundle'.

Reads the JSON / hex artefacts produced by @circuits/generate_fixtures.js@
and @aiken blueprint apply@, compresses the Groth16 points via the existing
'Cardano.Groth16.Compress' path, and collects everything into 'SpendBundle'
so test modules do not repeat parsing logic.

FR-006: the new tests consume the authoritative fixtures as-is; no
parallel copies.
-}
module Fixtures (
    SpendBundle (..),
    loadBundle,
    loadBundleVariant,
    fixturesDir,
) where

import Cardano.Groth16.Compress (compressProof, compressVK)
import Cardano.Groth16.Types (CompressedProof (..), CompressedVK (..), SnarkjsProof, SnarkjsVK)
import Data.Aeson ((.:))
import qualified Data.Aeson as Aeson
import Data.ByteString (ByteString)
import qualified Data.ByteString.Base16 as Base16
import qualified Data.ByteString.Char8 as BS8
import qualified Data.ByteString.Lazy as LBS
import Data.Maybe (fromMaybe)
import Data.Word (Word16)
import System.Environment (lookupEnv)
import System.IO.Unsafe (unsafePerformIO)

-- | Everything a spend-bundle test needs.
data SpendBundle = SpendBundle
    { sbProof :: CompressedProof
    , sbVK :: CompressedVK
    , sbPublicInputs :: [Integer]
    {- ^ In the circuit's public-input order:
    [d, commit_S_old, commit_S_new, user_id,
    issuer_Ax, issuer_Ay, pk_c_hi, pk_c_lo]
    -}
    , sbAppliedScriptHex :: ByteString
    , sbCustomerPubkey :: ByteString
    -- ^ 32 bytes
    , sbCustomerSignature :: ByteString
    -- ^ 64 bytes
    , sbSignedData :: ByteString
    -- ^ 106 bytes, canonical layout
    , sbTxid :: ByteString
    -- ^ 32 bytes, raw
    , sbIx :: Word16
    , sbD :: Integer
    , sbPkCHi :: Integer
    , sbPkCLo :: Integer
    , sbSkC :: ByteString
    {- ^ 32-byte Ed25519 signing key, used by the devnet test to
    re-sign signed_data with a live TxOutRef. The production
    reificator never sees this value — the real customer keeps
    sk_c on their phone. It lives in the fixture only because the
    test needs to generate a valid signature at runtime.
    -}
    }
    deriving (Show)

{- | Directory containing the authoritative fixture files. Resolved, in
order: @$HARVEST_FIXTURES_DIR@ if set (used by the nix test wrapper),
otherwise @test/fixtures@ relative to the current working directory
(the cabal-test default when @cabal test@ runs from @offchain/@).
-}
fixturesDir :: FilePath
fixturesDir = unsafePerformIO $ fromMaybe "test/fixtures" <$> lookupEnv "HARVEST_FIXTURES_DIR"
{-# NOINLINE fixturesDir #-}

-- | Internal shape of @customer.json@.
data CustomerFixture = CustomerFixture
    { cfPkCHex :: String
    , cfSkCHex :: String
    , cfSignedDataHex :: String
    , cfCustomerSignatureHex :: String
    , cfTxidHex :: String
    , cfIx :: Integer
    , cfPkCHi :: Integer
    , cfPkCLo :: Integer
    }

instance Aeson.FromJSON CustomerFixture where
    parseJSON = Aeson.withObject "customer" $ \o ->
        CustomerFixture
            <$> o .: "pk_c_hex"
            <*> o .: "sk_c_hex"
            <*> o .: "signed_data_hex"
            <*> o .: "customer_signature_hex"
            <*> o .: "txid_hex"
            <*> o .: "ix"
            <*> (read <$> o .: "pk_c_hi")
            <*> (read <$> o .: "pk_c_lo")

-- | Load the default (c1) bundle from 'fixturesDir'.
loadBundle :: IO SpendBundle
loadBundle = loadBundleVariant Nothing

{- | Load a fixture bundle from 'fixturesDir'. Pass 'Nothing' for the
default (c1) variant, or @Just "c1-cert2"@ / @Just "c2"@ for an
alternate fixture set. The VK and applied-script hex are shared across
all variants; only @proof@, @customer@, and @public@ files differ.
-}
loadBundleVariant :: Maybe String -> IO SpendBundle
loadBundleVariant variant = do
    proof <- readJson @SnarkjsProof (suffixed "proof")
    vk <- readJson @SnarkjsVK "verification_key.json"
    publicSignals <- readJson @[String] (suffixed "public")
    customer <- readJson @CustomerFixture (suffixed "customer")
    appliedHex <- readByteString "applied-voucher-spend.hex"

    cp <- compressProof proof
    cvk <- compressVK vk

    let hex s = case Base16.decode (BS8.pack s) of
            Right b -> pure b
            Left e -> fail ("base16 decode failed for fixture field: " <> e)

    pkC <- hex (cfPkCHex customer)
    skC <- hex (cfSkCHex customer)
    sigC <- hex (cfCustomerSignatureHex customer)
    signedData <- hex (cfSignedDataHex customer)
    txid <- hex (cfTxidHex customer)

    pure
        SpendBundle
            { sbProof = cp
            , sbVK = cvk
            , sbPublicInputs = map read publicSignals
            , sbAppliedScriptHex = appliedHex
            , sbCustomerPubkey = pkC
            , sbCustomerSignature = sigC
            , sbSignedData = signedData
            , sbTxid = txid
            , sbIx = fromInteger (cfIx customer)
            , sbD = head (map read publicSignals)
            , sbPkCHi = cfPkCHi customer
            , sbPkCLo = cfPkCLo customer
            , sbSkC = skC
            }
  where
    suffixed :: String -> FilePath
    suffixed base = case variant of
        Nothing -> base <> ".json"
        Just v -> base <> "-" <> v <> ".json"

    readJson :: (Aeson.FromJSON a) => FilePath -> IO a
    readJson name = do
        bytes <- LBS.readFile (fixturesDir <> "/" <> name)
        case Aeson.eitherDecode bytes of
            Right a -> pure a
            Left e -> fail ("failed to parse " <> name <> ": " <> e)

    readByteString :: FilePath -> IO ByteString
    readByteString name = do
        bytes <- LBS.readFile (fixturesDir <> "/" <> name)
        pure (LBS.toStrict bytes)
