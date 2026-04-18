{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : SpendHarnessSpec
Description : Unit tests for the re-sign helper that the devnet
              scenarios will use.

Exercises 'SpendHarness.resignedData' directly — no devnet involved.
Once the full devnet bracket lands, these cases prove the
re-sign path is correct in isolation, so a devnet failure cannot
masquerade as a re-sign bug.
-}
module SpendHarnessSpec (spec) where

import Cardano.Node.Client.E2E.Setup (
    Ed25519DSIGN,
    VerKeyDSIGN,
    rawDeserialiseSigDSIGN,
    rawDeserialiseVerKeyDSIGN,
    verifyDSIGN,
 )
import qualified Data.ByteString as BS
import Data.Either (isRight)
import Data.Maybe (fromMaybe)
import Fixtures (SpendBundle (..), loadBundle)
import SignedDataLayout (
    lengthTxid,
    offsetD,
    offsetIx,
    signedDataSize,
 )
import SpendHarness (resignedData, u16BigEndian)
import Test.Hspec (Spec, describe, it, runIO, shouldBe, shouldSatisfy)

spec :: Spec
spec = describe "SpendHarness.resignedData" $ do
    bundle <- runIO loadBundle

    let
        -- A fake TxId the harness might pick off a live devnet.
        liveTxid = BS.pack (replicate lengthTxid 0x42)
        liveIx = 1
        Just (signedData', sig') =
            resignedData
                (sbSkC bundle)
                (sbSignedData bundle)
                liveTxid
                liveIx

        vk :: VerKeyDSIGN Ed25519DSIGN
        vk =
            fromMaybe
                (error "vk decode failed")
                (rawDeserialiseVerKeyDSIGN (sbCustomerPubkey bundle))
        sigParsed =
            fromMaybe
                (error "sig decode failed")
                (rawDeserialiseSigDSIGN sig')

    it "produces a 106-byte signed_data'" $
        BS.length signedData' `shouldBe` signedDataSize

    it "produces a 64-byte signature" $
        BS.length sig' `shouldBe` 64

    it "rewrites txid" $
        BS.take lengthTxid signedData' `shouldBe` liveTxid

    it "rewrites ix" $
        BS.take 2 (BS.drop offsetIx signedData')
            `shouldBe` u16BigEndian liveIx

    it "preserves the tail (acceptor_ax, acceptor_ay, d)" $
        BS.drop (offsetIx + 2) signedData'
            `shouldBe` BS.drop (offsetIx + 2) (sbSignedData bundle)

    it "d in the re-signed payload still matches the public-signals d" $
        let dBytes = BS.drop offsetD signedData'
         in toInteger (BS.foldl' (\a b -> a * 256 + fromIntegral b) 0 dBytes)
                `shouldBe` sbD bundle

    it "verifyDSIGN accepts the re-signed payload under the customer's pk" $
        verifyDSIGN () vk signedData' sigParsed `shouldSatisfy` isRight
