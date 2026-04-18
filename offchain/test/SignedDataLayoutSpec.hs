{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : SignedDataLayoutSpec
Description : Cross-implementation check for the 106-byte @signed_data@
              payload (FR-004, SC-003, user story US3).

Loads @offchain/test/fixtures/customer.json@ produced by the Node-side
signer, parses its @signed_data@ bytes with the layout rules in
'SignedDataLayout', and asserts each parsed field equals the value the
Node-side signer claims to have set.

If the JS signer and the Aiken validator ever disagree on the byte
layout, this test fails before the devnet-based tests get a chance to
surface the mismatch as a cryptic Ed25519 verify error.
-}
module SignedDataLayoutSpec (spec) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Base16 as Base16
import Data.Either (isLeft, isRight)
import Fixtures (SpendBundle (..), loadBundle)
import SignedDataLayout (
    ParsedSignedData (..),
    parseSignedData,
    signedDataSize,
 )
import Test.Hspec (Spec, describe, it, runIO, shouldBe, shouldSatisfy)

spec :: Spec
spec = describe "signed_data byte layout cross-check" $ do
    bundle <- runIO loadBundle
    let parsed = case parseSignedData (sbSignedData bundle) of
            Right p -> p
            Left e -> error ("parseSignedData failed at spec load: " <> e)

    it "is 106 bytes" $
        BS.length (sbSignedData bundle) `shouldBe` signedDataSize

    it "parses cleanly" $
        parseSignedData (sbSignedData bundle) `shouldSatisfy` isRight

    it "txid matches Node's txid_hex" $
        Base16.encode (psdTxid parsed) `shouldBe` Base16.encode (sbTxid bundle)

    it "ix matches Node's ix" $
        psdIx parsed `shouldBe` fromIntegral (sbIx bundle)

    it "d matches public-signals d" $
        psdD parsed `shouldBe` sbD bundle

    it "acceptor_ax fits in 256 bits" $
        (psdAcceptorAx parsed >= 0 && psdAcceptorAx parsed < bound256)
            `shouldBe` True

    it "acceptor_ay fits in 256 bits" $
        (psdAcceptorAy parsed >= 0 && psdAcceptorAy parsed < bound256)
            `shouldBe` True

    it "rejects a one-byte-short payload" $
        parseSignedData (BS.take (signedDataSize - 1) (sbSignedData bundle))
            `shouldSatisfy` isLeft

bound256 :: Integer
bound256 = 2 ^ (256 :: Int)
