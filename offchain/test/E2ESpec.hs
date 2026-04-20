{-# LANGUAGE OverloadedStrings #-}

{- | Integration test: load all E2E fixtures (applied script, proof, VK)
and verify they parse, compress, and encode correctly.
-}
module E2ESpec (spec) where

import Cardano.Groth16.Compress (compressProof, compressVK)
import Cardano.Groth16.Serialize (
    groth16ProofToData,
    spendRedeemerToData,
    voucherDatumToData,
 )
import Cardano.Groth16.Types (CompressedProof (..), CompressedVK (..), SnarkjsProof, SnarkjsVK)
import Cardano.Ledger.BaseTypes (Network (..)) -- re-exported via harvest
import Cardano.PlutusData (encodePlutusData)
import qualified Data.Aeson as Aeson
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base16 as Base16
import qualified Data.ByteString.Lazy as LBS
import qualified Data.ByteString.Short as SBS
import Fixtures (fixturesDir)
import Harvest.Script (loadScript, scriptAddr)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

spec :: Spec
spec = describe "E2E fixture validation" $ do
    it "loads and parses the applied PlutusV3 script" $ do
        scriptHex <- BS.readFile (fixturesDir <> "/applied-voucher-spend.hex")
        let Right scriptBytes = Base16.decode scriptHex
            script = loadScript (SBS.toShort scriptBytes)
            addr = scriptAddr Testnet script
        -- Script loaded without error, address computed
        show addr `shouldSatisfy` (not . null)

    it "compresses proof from fixtures" $ do
        proofJson <- LBS.readFile (fixturesDir <> "/proof.json")
        let Right proof = Aeson.eitherDecode proofJson :: Either String SnarkjsProof
        cp <- compressProof proof
        BS.length (cpA cp) `shouldBe` 48
        BS.length (cpB cp) `shouldBe` 96
        BS.length (cpC cp) `shouldBe` 48

    it "compresses VK from fixtures with 9 IC points" $ do
        vkJson <- LBS.readFile (fixturesDir <> "/verification_key.json")
        let Right vk = Aeson.eitherDecode vkJson :: Either String SnarkjsVK
        cvk <- compressVK vk
        length (cvIC cvk) `shouldBe` 9
        BS.length (cvAlpha cvk) `shouldBe` 48
        BS.length (cvBeta cvk) `shouldBe` 96

    it "encodes spend redeemer with proof as valid CBOR" $ do
        proofJson <- LBS.readFile (fixturesDir <> "/proof.json")
        let Right proof = Aeson.eitherDecode proofJson :: Either String SnarkjsProof
        cp <- compressProof proof
        let issuerAx = 38027910944389743520483063064820863072988122188084404123017356326968334007437
            issuerAy = 42941175320000579223328167288954972786414509136882026862597282785302372595651
            pkcHi = 163730017189585948769029599285347051146
            pkcLo = 115007363968725112145270370819144465957
            customerPubkey = BS.replicate 32 0x01
            customerSignature = BS.replicate 64 0x02
            signedData = BS.replicate 106 0x03
            redeemer =
                spendRedeemerToData
                    10
                    999
                    issuerAx
                    issuerAy
                    pkcHi
                    pkcLo
                    customerPubkey
                    customerSignature
                    signedData
                    cp
            cbor = encodePlutusData redeemer
        BS.length cbor `shouldSatisfy` (> 0)
