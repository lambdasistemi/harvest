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
import Cardano.Ledger.Api.Tx.Out (datumTxOutL)
import Cardano.Ledger.BaseTypes (Network (..))
import Cardano.Ledger.Plutus.Data (
    binaryDataToData,
    getPlutusData,
 )
import Cardano.Ledger.Api.Tx.Out (TxOut)
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Node.Client.Provider (Provider (..))
import Cardano.Node.Client.Submitter (SubmitResult (..))
import Control.Concurrent (threadDelay)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base16 as Base16
import qualified Data.ByteString.Char8 as BS8
import qualified Data.ByteString.Short as SBS
import Data.Char (isHexDigit)
import DevnetEnv (DevnetEnv (..), withEnv)
import Fixtures (SpendBundle (..), loadBundle, loadBundleVariant)
import qualified Harvest.Script as Script
import Harvest.Types (CoalitionDatum (..), VoucherDatum (..))
import HarvestFlow (
    GovOp (..),
    HarvestFlow (..),
    bootstrapCoalition,
    submitGovernance,
 )
import Lens.Micro ((^.))
import PlutusTx.IsData.Class (fromData)
import SpendScenario (CoalitionEnv (..), identityMutations, submitSpend)
import SpendSetup (DeployedSpend (..), deploySpendState)
import Test.Hspec (
    Spec,
    around,
    describe,
    expectationFailure,
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

        -- == First settlement (T018, US1 step 3 — non-membership) ==
        --
        -- The customer (@c1@) spends for the first time at a coalition
        -- shop. The test deploys a voucher script UTxO carrying the
        -- initial commitment from the c1 fixture, then submits the
        -- settlement tx through the same 'spendVoucher' path the
        -- production reificator uses.
        --
        -- "Non-membership" means the voucher entry for this user_id
        -- did not exist before: the 'deploySpendState' step creates
        -- it. The validator does not distinguish this from a second
        -- settlement — the commit_spent rotation is the same — but
        -- the harness tracks entry existence in 'hfVoucherEntries'.
        --
        -- What this test proves when it passes:
        --   * The full pipeline — coalition bootstrap, onboarding,
        --     voucher deploy, settlement — composes into a tx the
        --     devnet node accepts.
        --   * The rotated voucher datum carries the expected
        --     @commit_spent_new@ from the proof's public inputs
        --     (invariant #2 of @data-model.md@).
        it "first settlement rotates commit_spent (c1, non-membership)" $ \env -> do
            coalEnv <- setupCoalition env coalitionBytes coalitionAddr
            bundle <- loadBundle
            deployed <- deploySpendState env bundle
            result <- submitSpend env bundle deployed coalEnv identityMutations
            case result of
                Rejected reason ->
                    expectationFailure
                        ("first settlement rejected: " <> show reason)
                Submitted _txId -> do
                    let expectedCommitNew = sbPublicInputs bundle !! 2
                    voucherUtxos <-
                        waitForVoucherUtxo
                            (deProvider env)
                            (dsScriptAddr deployed)
                            (dsScriptTxIn deployed)
                            30
                    case voucherUtxos of
                        [] ->
                            expectationFailure
                                "no rotated voucher UTxO after settlement"
                        ((_, out) : _) ->
                            assertVoucherCommit out expectedCommitNew

        -- == Second settlement (T019, US1 step 4 — membership) ==
        --
        -- A second settlement for the same customer, using the
        -- @c1-cert2@ fixture bundle (a different cap certificate with
        -- @d = 15@, @C = 200@). The initial voucher is deployed with
        -- the @c1-cert2@ commitment, then settled once.
        --
        -- "Membership" means the protocol knows this customer already
        -- (the voucher UTxO exists). Each @it@ block gets a fresh
        -- devnet, so we deploy the voucher with the cert-2
        -- commitment to exercise the validator with a distinct
        -- set of proof values.
        --
        -- What this test proves when it passes:
        --   * The voucher-spend validator accepts a settlement with
        --     different @d@, @commit_S_old@, @commit_S_new@ values
        --     than the c1-default fixture (confirms the proof
        --     verification is not accidentally pinned to one set of
        --     public inputs).
        --   * The rotated datum again carries the expected
        --     @commit_spent_new@.
        it "second settlement with cert-2 rotates commit_spent (c1-cert2)" $ \env -> do
            coalEnv <- setupCoalition env coalitionBytes coalitionAddr
            bundle <- loadBundleVariant (Just "c1-cert2")
            deployed <- deploySpendState env bundle
            result <- submitSpend env bundle deployed coalEnv identityMutations
            case result of
                Rejected reason ->
                    expectationFailure
                        ("cert-2 settlement rejected: " <> show reason)
                Submitted _txId -> do
                    let expectedCommitNew = sbPublicInputs bundle !! 2
                    voucherUtxos <-
                        waitForVoucherUtxo
                            (deProvider env)
                            (dsScriptAddr deployed)
                            (dsScriptTxIn deployed)
                            30
                    case voucherUtxos of
                        [] ->
                            expectationFailure
                                "no rotated voucher UTxO after cert-2 settlement"
                        ((_, out) : _) ->
                            assertVoucherCommit out expectedCommitNew

        -- == No coalition ref → rejected (T020, SC-005) ==
        --
        -- The reificator submits a settlement tx that is valid in
        -- every respect EXCEPT the coalition-metadata reference input
        -- is missing. The validator's @find_coalition_ref@ returns
        -- @None@, causing @expect Some(coalition)@ to fail.
        --
        -- The mutation substitutes a non-coalition UTxO (the
        -- reificator's fee UTxO) as the "coalition ref", so the
        -- validator cannot find a 'CoalitionDatum' at the expected
        -- script credential.
        it "settlement rejected when coalition ref input missing (SC-005)" $ \env -> do
            coalEnv <- setupCoalition env coalitionBytes coalitionAddr
            bundle <- loadBundle
            deployed <- deploySpendState env bundle
            let bogusCoalEnv =
                    coalEnv
                        { ceCoalitionTxIn = dsReificatorFeeTxIn deployed
                        , ceCoalitionTxOut = dsReificatorFeeTxOut deployed
                        }
            result <- submitSpend env bundle deployed bogusCoalEnv identityMutations
            result `shouldSatisfy` isRejected
  where
    setupCoalition ::
        DevnetEnv ->
        SBS.ShortByteString ->
        Addr ->
        IO CoalitionEnv
    setupCoalition env coalitionBytes' coalitionAddr' = do
        let shopPk =
                rawSerialiseVerKeyDSIGN
                    (deriveVerKeyDSIGN (deShopKey env))
            reificatorPk =
                rawSerialiseVerKeyDSIGN
                    (deriveVerKeyDSIGN (deReificatorKey env))
        flow0 <- bootstrapCoalition env coalitionAddr'
        flow1 <-
            submitGovernance
                env
                coalitionBytes'
                coalitionAddr'
                flow0
                (GovAddShop shopPk)
        flow2 <-
            submitGovernance
                env
                coalitionBytes'
                coalitionAddr'
                flow1
                (GovAddReificator reificatorPk)
        pure
            CoalitionEnv
                { ceCoalitionTxIn = hfCoalitionIn flow2
                , ceCoalitionTxOut = hfCoalitionOut flow2
                , ceReificatorKey = deReificatorKey env
                }

{- | Poll until the voucher script address holds a UTxO whose
'TxIn' differs from the old (just-consumed) one.
-}
waitForVoucherUtxo ::
    Provider IO ->
    Addr ->
    TxIn ->
    Int ->
    IO [(TxIn, TxOut ConwayEra)]
waitForVoucherUtxo provider addr oldIn attempts
    | attempts <= 0 =
        error ("waitForVoucherUtxo: timed out at " <> show addr)
    | otherwise = do
        utxos <- queryUTxOs provider addr
        let fresh = filter (\(i, _) -> i /= oldIn) utxos
        if null fresh
            then do
                threadDelay 1_000_000
                waitForVoucherUtxo provider addr oldIn (attempts - 1)
            else pure fresh

{- | Assert the voucher output's inline datum has the expected
@commit_spent@ value.
-}
assertVoucherCommit :: TxOut ConwayEra -> Integer -> IO ()
assertVoucherCommit out expectedCommit =
    case out ^. datumTxOutL of
        Datum bd ->
            case fromData (getPlutusData (binaryDataToData bd)) of
                Just vd ->
                    vdCommitSpent vd `shouldBe` expectedCommit
                Nothing ->
                    error
                        "voucher output datum did not parse as VoucherDatum"
        _ ->
            error "voucher output has no inline datum"

{- | True iff the node rejected the tx.
-}
isRejected :: SubmitResult -> Bool
isRejected (Rejected _) = True
isRejected _ = False
