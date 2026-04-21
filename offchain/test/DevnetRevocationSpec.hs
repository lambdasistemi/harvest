{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : DevnetRevocationSpec
Description : End-to-end documentation of reificator revocation (US4 — #9).

== Reading this module as documentation

This test file exercises the coalition's power to revoke a reificator's
authority from the on-chain registry.  After revocation the reificator's
public key is absent from @CoalitionDatum.reificator_pks@, so any
subsequent settlement signed by that reificator is rejected by the
voucher validator's membership check.

Scenarios:

  1. Revocation accepted — the coalition issues a @RevokeReificator@
     governance tx; the rotated datum no longer contains the
     reificator's public key (invariant #7, part 1).
  2. Settlement rejected after revocation — the revoked reificator
     attempts a settlement; the voucher validator rejects it because
     the reificator key is no longer in the coalition datum
     (invariant #7, part 2).
  3. Negative: revocation of a non-registered key is rejected by the
     coalition-metadata validator.

Each @it@ block gets a fresh devnet via @around withEnv@.
-}
module DevnetRevocationSpec (spec) where

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
import Cardano.Node.Client.E2E.Setup (mkSignKey)
import Cardano.Node.Client.Submitter (SubmitResult (..))
import Control.Exception (SomeException, try)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base16 as Base16
import qualified Data.ByteString.Char8 as BS8
import qualified Data.ByteString.Short as SBS
import Data.Char (isHexDigit)
import DevnetEnv (DevnetEnv (..), withEnv)
import Fixtures (fixturesDir, loadBundle)
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
import SpendScenario (CoalitionEnv (..), identityMutations, submitSpend)
import SpendSetup (deploySpendState)
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

loadCoalitionAddr :: IO (SBS.ShortByteString, Addr)
loadCoalitionAddr = do
    raw <- BS.readFile (fixturesDir <> "/applied-coalition-metadata.hex")
    let sbs = decodeHex raw
    pure (sbs, Script.coalitionAddr Testnet sbs)

decodeHex :: BS.ByteString -> SBS.ShortByteString
decodeHex bs = case Base16.decode (BS8.filter isHexDigit bs) of
    Right decoded -> SBS.toShort decoded
    Left e -> error ("decodeHex: " <> e)

spec :: Spec
spec = describe "Devnet reificator revocation (US4 — #9)" $ do
    (coalitionBytes, coalitionAddr) <- runIO loadCoalitionAddr

    around withEnv $ do
        -- == Revocation accepted (T039, invariant #7 part 1) ==
        --
        -- The issuer revokes the reificator's public key from the
        -- coalition registry.  The rotated datum must no longer
        -- contain the revoked key.
        it "coalition revokes reificator (key removed from datum)" $ \env -> do
            let shopPk =
                    rawSerialiseVerKeyDSIGN
                        (deriveVerKeyDSIGN (deShopKey env))
                reificatorPk =
                    rawSerialiseVerKeyDSIGN
                        (deriveVerKeyDSIGN (deReificatorKey env))
                expectedIssuer =
                    rawSerialiseVerKeyDSIGN
                        (deriveVerKeyDSIGN (deIssuerKey env))

            flow0 <- bootstrapCoalition env coalitionAddr
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

            -- Revoke the reificator
            flow3 <-
                submitGovernance
                    env
                    coalitionBytes
                    coalitionAddr
                    flow2
                    (GovRevokeReificator reificatorPk)

            -- Assert: reificator key absent, shop key preserved
            let coalDatum = hfCoalitionOut flow3 ^. datumTxOutL
            case coalDatum of
                Datum bd ->
                    case fromData (getPlutusData (binaryDataToData bd)) of
                        Just cd -> do
                            cdReificatorPks cd `shouldBe` []
                            cdShopPks cd `shouldBe` [shopPk]
                            cdIssuerPk cd `shouldBe` expectedIssuer
                        Nothing ->
                            expectationFailure
                                "coalition datum did not parse"
                _ ->
                    expectationFailure
                        "coalition output has no inline datum"

        -- == Settlement rejected after revocation (T040, invariant #7 part 2) ==
        --
        -- After the reificator is revoked, a settlement attempt using
        -- the revoked key is rejected by the voucher validator's
        -- membership check on @reificator_pk in reificator_pks@.
        it "settlement rejected after reificator revocation" $ \env -> do
            let shopPk =
                    rawSerialiseVerKeyDSIGN
                        (deriveVerKeyDSIGN (deShopKey env))
                reificatorPk =
                    rawSerialiseVerKeyDSIGN
                        (deriveVerKeyDSIGN (deReificatorKey env))

            flow0 <- bootstrapCoalition env coalitionAddr
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

            -- Revoke the reificator
            flow3 <-
                submitGovernance
                    env
                    coalitionBytes
                    coalitionAddr
                    flow2
                    (GovRevokeReificator reificatorPk)

            -- Attempt settlement with the revoked reificator
            bundle <- loadBundle
            deployed <- deploySpendState env bundle
            let coalEnv =
                    CoalitionEnv
                        { ceCoalitionTxIn = hfCoalitionIn flow3
                        , ceCoalitionTxOut = hfCoalitionOut flow3
                        , ceReificatorKey = deReificatorKey env
                        }
            result <-
                submitSpend
                    env
                    bundle
                    deployed
                    coalEnv
                    identityMutations
            result `shouldSatisfy` isRejected

        -- == Negative: revoke non-registered key (T041) ==
        --
        -- Revoking a key that was never registered is rejected by the
        -- coalition-metadata validator's @contains@ check.
        it "revocation of non-registered key is rejected" $ \env -> do
            let shopPk =
                    rawSerialiseVerKeyDSIGN
                        (deriveVerKeyDSIGN (deShopKey env))
                reificatorPk =
                    rawSerialiseVerKeyDSIGN
                        (deriveVerKeyDSIGN (deReificatorKey env))
                -- A key that was never added to the coalition
                bogusKey = mkSignKey (BS8.pack (replicate 32 'X'))
                bogusPk =
                    rawSerialiseVerKeyDSIGN
                        (deriveVerKeyDSIGN bogusKey)

            flow0 <- bootstrapCoalition env coalitionAddr
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

            -- Attempt to revoke a key that was never registered.
            -- submitGovernance calls 'error' on build failure, so we
            -- catch the exception to verify rejection.
            rejected <-
                tryRevokeRejected
                    env
                    coalitionBytes
                    coalitionAddr
                    flow2
                    bogusPk
            rejected `shouldBe` True

-- | True iff the node rejected the tx.
isRejected :: SubmitResult -> Bool
isRejected (Rejected _) = True
isRejected _ = False

{- | Try a revocation governance tx. Returns 'True' if the validator
rejected it (which is what the negative test expects).

'submitGovernance' calls 'error' on build failure (including phase-2
validator rejection), so we catch the exception.
-}
tryRevokeRejected ::
    DevnetEnv ->
    SBS.ShortByteString ->
    Addr ->
    HarvestFlow ->
    BS.ByteString ->
    IO Bool
tryRevokeRejected env coalitionBytes' coalitionAddr' flow targetPk = do
    result <-
        try
            ( submitGovernance
                env
                coalitionBytes'
                coalitionAddr'
                flow
                (GovRevokeReificator targetPk)
            )
    case result of
        Left (_ :: SomeException) -> pure True
        Right _ -> pure False
