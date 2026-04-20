{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : DevnetFullFlowSpec
Description : End-to-end documentation of the #9 full protocol flow.

== Reading this module as documentation

This test file is the executable narrative of the full harvest
protocol flow against a real Cardano devnet:

  1. Coalition bootstrap on an empty devnet.
  2. Shop + reificator onboarding via governance txs.
  3. First settlement — non-membership branch of the voucher
     validator (customer has no prior entry).
  4. Second settlement — membership branch (customer's prior entry
     is reused, @commit_spent@ rotates).

Follows the @DevnetSpendSpec@ layout from #15 — own @withDevnet@
bracket, one actor per 'it' block, no matching on error text.

Scenarios land incrementally per @specs/003-devnet-full-flow/tasks.md@
T015 (skeleton) → T016 (coalition bootstrap) → T017-T020.
-}
module DevnetFullFlowSpec (spec) where

import Cardano.Crypto.DSIGN (
    deriveVerKeyDSIGN,
    rawSerialiseVerKeyDSIGN,
 )
import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Scripts.Data (Datum (Datum))
import Cardano.Ledger.Plutus.Data (
    binaryDataToData,
    getPlutusData,
 )
import Cardano.Ledger.Api.Tx.Out (datumTxOutL)
import Cardano.Ledger.BaseTypes (Network (..))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base16 as Base16
import qualified Data.ByteString.Char8 as BS8
import qualified Data.ByteString.Short as SBS
import Data.Char (isHexDigit)
import DevnetEnv (DevnetEnv (..), withEnv)
import qualified Harvest.Script as Script
import Harvest.Types (CoalitionDatum (..))
import HarvestFlow (
    GovOp (..),
    HarvestFlow (..),
    bootstrapCoalition,
    submitGovernance,
 )
import Lens.Micro ((^.))
import PlutusTx.IsData.Class (fromData)
import Test.Hspec (
    Spec,
    around,
    describe,
    it,
    runIO,
    shouldBe,
    shouldSatisfy,
 )

{- | Load the applied coalition-metadata script hex and derive the
corresponding Testnet address. The hex ships in the fixture tree
alongside the voucher-spend applied script.
-}
loadCoalitionAddr :: IO (SBS.ShortByteString, Addr)
loadCoalitionAddr = do
    raw <- BS.readFile "test/fixtures/applied-coalition-metadata.hex"
    let sbs = decodeHex raw
    pure (sbs, Script.coalitionAddr Testnet sbs)
  where
    decodeHex bs = case Base16.decode (BS8.filter isHexDigit bs) of
        Right decoded -> SBS.toShort decoded
        Left e -> error ("applied-coalition-metadata.hex: " <> e)

spec :: Spec
spec = describe "Devnet full protocol flow (US1 — #9)" $ do
    (coalitionBytes, coalitionAddr) <- runIO loadCoalitionAddr

    around withEnv $ do
        it "devnet comes up with a funded genesis address" $ \env ->
            deGenesisUtxos env `shouldSatisfy` (not . null)

        -- == Coalition bootstrap (T016, invariant #1 of data-model.md) ==
        --
        -- A freshly-spun devnet has no coalition state. The issuer
        -- runs the coalition-create transaction, which pays a
        -- 5-ADA UTxO to the coalition-metadata script address with
        -- an empty registry (no shops, no reificators) and the
        -- issuer's Ed25519 pk locked in the datum.
        --
        -- What this test proves when it passes:
        --   * The applied coalition-metadata script bytecode
        --     (hash-identical to @aiken build@ output) loads and
        --     addresses round-trip.
        --   * 'HarvestFlow.bootstrapCoalition' lands exactly one
        --     script UTxO at the coalition address.
        --   * The inline datum round-trips as a 'CoalitionDatum'
        --     with empty shop/reificator lists and the expected
        --     issuer pk.
        it "coalition bootstraps on an empty devnet" $ \env -> do
            flow <- bootstrapCoalition env coalitionAddr
            let coalDatumLedger = hfCoalitionOut flow ^. datumTxOutL
                expectedIssuer =
                    rawSerialiseVerKeyDSIGN
                        (deriveVerKeyDSIGN (deIssuerKey env))
            case coalDatumLedger of
                Datum bd ->
                    case fromData (getPlutusData (binaryDataToData bd)) of
                        Just cd -> do
                            cdShopPks cd `shouldBe` []
                            cdReificatorPks cd `shouldBe` []
                            cdIssuerPk cd `shouldBe` expectedIssuer
                        Nothing ->
                            error
                                "coalition output datum did not parse as CoalitionDatum"
                _ ->
                    error "coalition output has no inline datum"

        -- == Shop + reificator onboarding (T017, Story 1 step 2) ==
        --
        -- After bootstrap the coalition registry is empty.  The issuer
        -- runs two governance txs back-to-back: 'AddShop' for the
        -- shop's public key, then 'AddReificator' for the reificator's
        -- public key.  Each tx consumes the current coalition UTxO,
        -- carries an issuer Ed25519 signature over @serialise(own_ref)
        -- || op_tag || target_pk@, and re-pays the coalition address
        -- with the extended datum.  The reificator funds fees and
        -- collateral from its bootstrap-seeded UTxOs.
        --
        -- What this test proves when it passes:
        --   * 'submitGovernance' constructs signed redeemers the
        --     on-chain validator accepts for both 'AddShop' and
        --     'AddReificator'.
        --   * The rotated coalition UTxO carries the transitioned
        --     datum: exactly one shop pk, exactly one reificator pk,
        --     and the original issuer pk preserved.
        --   * 'HarvestFlow' correctly forwards to the rotated UTxO
        --     (invariant #1 of @data-model.md@ — only the registry
        --     lists change; everything else is stable).
        it "shop + reificator onboard extends the coalition datum" $ \env -> do
            flow0 <- bootstrapCoalition env coalitionAddr
            let expectedIssuer =
                    rawSerialiseVerKeyDSIGN
                        (deriveVerKeyDSIGN (deIssuerKey env))
                shopPk =
                    rawSerialiseVerKeyDSIGN
                        (deriveVerKeyDSIGN (deShopKey env))
                reificatorPk =
                    rawSerialiseVerKeyDSIGN
                        (deriveVerKeyDSIGN (deReificatorKey env))
            flow1 <-
                submitGovernance
                    env
                    coalitionBytes
                    coalitionAddr
                    flow0
                    (GovAddShop shopPk)
            flow2 <-
                submitGovernance
                    env
                    coalitionBytes
                    coalitionAddr
                    flow1
                    (GovAddReificator reificatorPk)
            let coalDatumLedger = hfCoalitionOut flow2 ^. datumTxOutL
            case coalDatumLedger of
                Datum bd ->
                    case fromData (getPlutusData (binaryDataToData bd)) of
                        Just cd -> do
                            cdShopPks cd `shouldBe` [shopPk]
                            cdReificatorPks cd `shouldBe` [reificatorPk]
                            cdIssuerPk cd `shouldBe` expectedIssuer
                        Nothing ->
                            error
                                "coalition output datum did not parse as CoalitionDatum"
                _ ->
                    error "coalition output has no inline datum"
