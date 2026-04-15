{-# LANGUAGE OverloadedStrings #-}

module Groth16Spec (spec) where

import Cardano.Groth16.Compress (compressProof, compressVK)
import Cardano.Groth16.Serialize (
    groth16ProofToData,
    spendRedeemerToData,
    vkToData,
    voucherDatumToData,
 )
import Cardano.Groth16.Types (CompressedProof (..), CompressedVK (..), SnarkjsProof, SnarkjsVK)
import Cardano.PlutusData (decodePlutusData, encodePlutusData)
import qualified Data.Aeson as Aeson
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

spec :: Spec
spec = describe "Groth16" $ do
    it "parses proof.json" $ do
        proof <- loadProof
        proof `shouldSatisfy` const True

    it "parses verification_key.json" $ do
        vk <- loadVK
        vk `shouldSatisfy` const True

    it "compresses G1 proof points to 48 bytes" $ do
        proof <- loadProof
        cp <- compressProof proof
        BS.length (cpA cp) `shouldBe` 48
        BS.length (cpC cp) `shouldBe` 48

    it "compresses G2 proof point to 96 bytes" $ do
        proof <- loadProof
        cp <- compressProof proof
        BS.length (cpB cp) `shouldBe` 96

    it "compresses VK points" $ do
        vk <- loadVK
        cvk <- compressVK vk
        BS.length (cvAlpha cvk) `shouldBe` 48
        BS.length (cvBeta cvk) `shouldBe` 96
        BS.length (cvGamma cvk) `shouldBe` 96
        BS.length (cvDelta cvk) `shouldBe` 96
        length (cvIC cvk) `shouldBe` 4
        all (\bs -> BS.length bs == 48) (cvIC cvk) `shouldBe` True

    it "encodes proof as PlutusData CBOR round-trip" $ do
        proof <- loadProof
        cp <- compressProof proof
        let pd = groth16ProofToData cp
            cbor = encodePlutusData pd
            decoded = decodePlutusData cbor
        decoded `shouldBe` Right pd

    it "encodes VK as PlutusData CBOR round-trip" $ do
        vk <- loadVK
        cvk <- compressVK vk
        let pd = vkToData cvk
            cbor = encodePlutusData pd
            decoded = decodePlutusData cbor
        decoded `shouldBe` Right pd

    it "encodes spend redeemer as PlutusData CBOR round-trip" $ do
        proof <- loadProof
        cp <- compressProof proof
        let commitNew = 28195311164484447918780156773062160077584542861722122307398165012434720062639
            pd = spendRedeemerToData 10 commitNew cp
            cbor = encodePlutusData pd
            decoded = decodePlutusData cbor
        decoded `shouldBe` Right pd

    it "encodes voucher datum as PlutusData CBOR round-trip" $ do
        let userPk = BS.replicate 28 0x42
            commitSpent = 15582956213402723687926053625819952146889630636005756883548712100509189278757
            pd = voucherDatumToData userPk commitSpent
            cbor = encodePlutusData pd
            decoded = decodePlutusData cbor
        decoded `shouldBe` Right pd

loadProof :: IO SnarkjsProof
loadProof = do
    bytes <- LBS.readFile "../circuits/build/proof.json"
    case Aeson.eitherDecode bytes of
        Right p -> pure p
        Left e -> error ("failed to parse proof.json: " <> e)

loadVK :: IO SnarkjsVK
loadVK = do
    bytes <- LBS.readFile "../circuits/build/verification_key.json"
    case Aeson.eitherDecode bytes of
        Right vk -> pure vk
        Left e -> error ("failed to parse verification_key.json: " <> e)
