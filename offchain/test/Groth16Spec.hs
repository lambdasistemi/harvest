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
        length (cvIC cvk) `shouldBe` 9
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
            issuerAx = 4704846161580081468346911840983759671196780515436681519191612393768338608159
            issuerAy = 34214411966183820933157791953903973357923378516047256783976067400851897240999
            acceptorAx = 6983986702542899954628519304086182057889757455360727493320948977468498651684
            acceptorAy = 11603074077413385000596357033630636871603057286790587959243768465754372931847
            pd = spendRedeemerToData 10 commitNew issuerAx issuerAy acceptorAx acceptorAy cp
            cbor = encodePlutusData pd
            decoded = decodePlutusData cbor
        decoded `shouldBe` Right pd

    it "encodes voucher datum as PlutusData CBOR round-trip" $ do
        let userId = 16194551325045813456199696102638278711129957240995407309199208567862169768429
            commitSpent = 15582956213402723687926053625819952146889630636005756883548712100509189278757
            pd = voucherDatumToData userId commitSpent
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
