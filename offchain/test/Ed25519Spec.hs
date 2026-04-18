{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Ed25519Spec
Description : Independent Ed25519 verify of the customer signature bundle
              (FR-003, SC-003, user story US1 cross-toolchain check).

Verifies the @(customer_pubkey, signed_data, customer_signature)@
produced by Node's @crypto.sign(null, signed_data, skcObj)@ against the
'verifyDSIGN' primitive re-exported by
@Cardano.Node.Client.E2E.Setup@. If Node's output is byte-compatible
with @cardano-crypto-class@ (which is what the Plutus builtin calls
internally), this confirms the validator will accept the same bytes
the devnet tests submit.

A negative case flips one byte of @signed_data@ and asserts verification
fails, proving the test has teeth.
-}
module Ed25519Spec (spec) where

import Cardano.Node.Client.E2E.Setup (
    Ed25519DSIGN,
    SigDSIGN,
    VerKeyDSIGN,
    rawDeserialiseSigDSIGN,
    rawDeserialiseVerKeyDSIGN,
    verifyDSIGN,
 )
import qualified Data.ByteString as BS
import Data.Bits (xor)
import Data.Maybe (fromMaybe)
import Data.Word (Word8)
import Fixtures (SpendBundle (..), loadBundle)
import Test.Hspec (Spec, describe, it, runIO, shouldBe, shouldSatisfy)

spec :: Spec
spec = describe "Ed25519 independent verifier (FR-003)" $ do
    bundle <- runIO loadBundle

    let vk :: VerKeyDSIGN Ed25519DSIGN
        vk = fromMaybe
            (error "rawDeserialiseVerKeyDSIGN failed on customer_pubkey")
            (rawDeserialiseVerKeyDSIGN (sbCustomerPubkey bundle))

        sig :: SigDSIGN Ed25519DSIGN
        sig = fromMaybe
            (error "rawDeserialiseSigDSIGN failed on customer_signature")
            (rawDeserialiseSigDSIGN (sbCustomerSignature bundle))

    it "customer_pubkey is 32 bytes" $
        BS.length (sbCustomerPubkey bundle) `shouldBe` 32

    it "customer_signature is 64 bytes" $
        BS.length (sbCustomerSignature bundle) `shouldBe` 64

    it "verifyDSIGN accepts the untouched fixture bundle" $
        verifyDSIGN () vk (sbSignedData bundle) sig `shouldBe` Right ()

    it "verifyDSIGN rejects signed_data with one byte flipped" $ do
        let tampered = flipFirstByte (sbSignedData bundle)
        verifyDSIGN () vk tampered sig `shouldSatisfy` isLeft

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft _ = False

-- | Flip the low bit of the first byte of a non-empty ByteString.
flipFirstByte :: BS.ByteString -> BS.ByteString
flipFirstByte bs = case BS.uncons bs of
    Just (b, rest) -> BS.cons (xorOne b) rest
    Nothing -> bs
  where
    xorOne :: Word8 -> Word8
    xorOne = (`xor` 1)
