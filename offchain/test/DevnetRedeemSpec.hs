{-# LANGUAGE DataKinds #-}
{-# LANGUAGE EmptyCase #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : DevnetRedeemSpec
Description : End-to-end documentation of voucher redemption (US2 — #9).

== Reading this module as documentation

This test file exercises the voucher redemption path against a real
Cardano devnet. Each scenario bootstraps a full coalition, settles
a voucher, then redeems it — proving the entry is removed from the
chain.

Scenarios:

  1. Redeem an existing voucher entry — the entry is destroyed, no
     voucher UTxO remains at the script address for this user_id.
  2. Re-settle after redemption — deploy a fresh voucher with the
     cert-2 fixture and settle, proving the address is reusable.
  3. Negative: redemption rejected when the reificator is not in
     the coalition registry.

Each @it@ block gets a fresh devnet via @around withEnv@.
-}
module DevnetRedeemSpec (spec) where

import Cardano.Crypto.DSIGN (
    deriveVerKeyDSIGN,
    rawSerialiseSigDSIGN,
    rawSerialiseVerKeyDSIGN,
    signDSIGN,
 )
import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Tx.Out (TxOut, coinTxOutL)
import Cardano.Ledger.BaseTypes (Network (..))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Conway.Scripts (AlonzoScript)
import Cardano.Ledger.Hashes (extractHash)
import Cardano.Ledger.Keys (
    KeyHash,
    KeyRole (..),
    VKey (..),
    hashKey,
 )
import Cardano.Ledger.Mary.Value (MaryValue)
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Cardano.Ledger.Val (inject)
import Cardano.Node.Client.E2E.Setup (
    addKeyWitness,
    deriveVerKeyDSIGN,
    genesisAddr,
    genesisSignKey,
    mkSignKey,
 )
import Cardano.Node.Client.Provider (Provider (..))
import Cardano.Node.Client.Submitter (
    SubmitResult (..),
    Submitter (..),
 )
import Cardano.Node.Client.TxBuild (
    BuildError (..),
    Convergence (..),
    InterpretIO (..),
    TxBuild,
    build,
    payTo,
    peek,
    requireSignature,
    spend,
 )
import Control.Concurrent (threadDelay)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base16 as Base16
import qualified Data.ByteString.Char8 as BS8
import qualified Data.ByteString.Short as SBS
import Data.Char (isHexDigit)
import qualified Data.Map.Strict as Map
import DevnetEnv (DevnetEnv (..), withEnv)
import Fixtures (fixturesDir, loadBundle, loadBundleVariant)
import qualified Harvest.Script as Script
import Harvest.Transaction (redeemVoucher)
import HarvestFlow (
    GovOp (..),
    HarvestFlow (..),
    bumpExUnits,
    bootstrapCoalition,
    submitGovernance,
 )
import Lens.Micro ((^.))
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

-- | Empty query type.
data NoQ a
    deriving ()

{- | Load the applied coalition-metadata script.
-}
loadCoalitionAddr :: IO (SBS.ShortByteString, Addr)
loadCoalitionAddr = do
    raw <- BS.readFile (fixturesDir <> "/applied-coalition-metadata.hex")
    let sbs = decodeHex raw
    pure (sbs, Script.coalitionAddr Testnet sbs)

{- | Load the unified voucher script (spend/redeem/revert share the same
applied script and address).
-}
loadVoucherScript :: IO (AlonzoScript ConwayEra, Addr)
loadVoucherScript = do
    raw <- BS.readFile (fixturesDir <> "/applied-voucher-spend.hex")
    let sbs = decodeHex raw
        script = Script.loadScript sbs
        addr = Script.scriptAddr Testnet script
    pure (script, addr)

decodeHex :: BS.ByteString -> SBS.ShortByteString
decodeHex bs = case Base16.decode (BS8.filter isHexDigit bs) of
    Right decoded -> SBS.toShort decoded
    Left e -> error ("decodeHex: " <> e)

spec :: Spec
spec = describe "Devnet redemption flow (US2 — #9)" $ do
    (coalitionBytes, coalitionAddr) <- runIO loadCoalitionAddr
    (voucherScript, _voucherAddr) <- runIO loadVoucherScript
    bundle <- runIO loadBundle

    around withEnv $ do
        -- == Redeem an existing entry (T025, invariant #4) ==
        --
        -- The reificator settles c1's voucher, then redeems it.
        -- After redemption, no voucher UTxO should remain at the
        -- spend-script address for this user_id.
        --
        -- What this test proves when it passes:
        --   * The voucher_redeem validator accepts a properly
        --     signed redemption tx with a valid coalition ref.
        --   * The entry is destroyed: zero UTxOs at the voucher
        --     script address after the redeem tx confirms.
        it "reificator redeems c1 entry — voucher removed" $ \env -> do
            coalEnv <- setupCoalition env coalitionBytes coalitionAddr
            deployed <- deploySpendState env bundle
            -- First: settle to create the voucher entry
            settleResult <-
                submitSpend env bundle deployed coalEnv identityMutations
            case settleResult of
                Rejected reason ->
                    expectationFailure
                        ("settlement rejected: " <> show reason)
                Submitted _txId -> pure ()

            -- Wait for the rotated voucher UTxO
            voucherUtxos <-
                waitForNewUtxo
                    (deProvider env)
                    (dsScriptAddr deployed)
                    (dsScriptTxIn deployed)
                    30
            (voucherIn, voucherOut) <- case voucherUtxos of
                (u : _) -> pure u
                [] -> error "no rotated voucher UTxO after settlement"

            -- Now redeem it
            redeemResult <-
                submitRedeem
                    env
                    voucherScript
                    coalEnv
                    voucherIn
                    voucherOut
            case redeemResult of
                Rejected reason ->
                    expectationFailure
                        ("redemption rejected: " <> show reason)
                Submitted _txId -> pure ()

            -- After redemption: no UTxOs at the voucher script address
            threadDelay 2_000_000
            remaining <- queryUTxOs (deProvider env) (dsScriptAddr deployed)
            remaining `shouldBe` []

        -- == Re-settle after redeem (T026) ==
        --
        -- After redeeming c1's entry, deploy a fresh voucher with
        -- the c1-cert2 fixture and settle. Proves the script address
        -- is reusable and the validator accepts a new entry.
        it "re-settle after redemption with cert-2" $ \env -> do
            coalEnv <- setupCoalition env coalitionBytes coalitionAddr
            -- Settle with c1
            deployed1 <- deploySpendState env bundle
            settleResult1 <-
                submitSpend env bundle deployed1 coalEnv identityMutations
            case settleResult1 of
                Rejected reason ->
                    expectationFailure
                        ("first settlement rejected: " <> show reason)
                Submitted _txId -> pure ()

            -- Wait for rotated voucher, then redeem
            voucherUtxos1 <-
                waitForNewUtxo
                    (deProvider env)
                    (dsScriptAddr deployed1)
                    (dsScriptTxIn deployed1)
                    30
            (voucherIn1, voucherOut1) <- case voucherUtxos1 of
                (u : _) -> pure u
                [] -> error "no rotated voucher UTxO after first settlement"

            redeemResult <-
                submitRedeem
                    env
                    voucherScript
                    coalEnv
                    voucherIn1
                    voucherOut1
            case redeemResult of
                Rejected reason ->
                    expectationFailure
                        ("redemption rejected: " <> show reason)
                Submitted _txId -> pure ()

            -- Wait for redemption to confirm
            threadDelay 2_000_000

            -- Now re-settle with cert-2
            bundle2 <- loadBundleVariant (Just "c1-cert2")
            deployed2 <- deploySpendState env bundle2
            settleResult2 <-
                submitSpend env bundle2 deployed2 coalEnv identityMutations
            case settleResult2 of
                Rejected reason ->
                    expectationFailure
                        ("cert-2 re-settlement rejected: " <> show reason)
                Submitted _txId -> do
                    voucherUtxos2 <-
                        waitForNewUtxo
                            (deProvider env)
                            (dsScriptAddr deployed2)
                            (dsScriptTxIn deployed2)
                            30
                    voucherUtxos2
                        `shouldSatisfy` (not . null)

        -- == Negative: non-member reificator (T027) ==
        --
        -- A reificator whose key is not in the coalition registry
        -- attempts to redeem. The validator's membership check
        -- (datum.reificator_pk ∈ coalition.reificator_pks) fails.
        --
        -- We use a freshly-generated key that was never onboarded.
        it "redemption rejected when reificator not in registry" $ \env -> do
            coalEnv <- setupCoalition env coalitionBytes coalitionAddr
            deployed <- deploySpendState env bundle
            settleResult <-
                submitSpend env bundle deployed coalEnv identityMutations
            case settleResult of
                Rejected reason ->
                    expectationFailure
                        ("settlement rejected: " <> show reason)
                Submitted _txId -> pure ()

            voucherUtxos <-
                waitForNewUtxo
                    (deProvider env)
                    (dsScriptAddr deployed)
                    (dsScriptTxIn deployed)
                    30
            (voucherIn, voucherOut) <- case voucherUtxos of
                (u : _) -> pure u
                [] -> error "no rotated voucher UTxO after settlement"

            -- Use an unknown key (not onboarded) as the reificator
            let bogusCoalEnv =
                    coalEnv
                        { ceReificatorKey = mkSignKey (BS8.pack (replicate 32 'X'))
                        }
            redeemResult <-
                submitRedeem
                    env
                    voucherScript
                    bogusCoalEnv
                    voucherIn
                    voucherOut
            redeemResult `shouldSatisfy` isRejected
  where
    setupCoalition ::
        DevnetEnv ->
        SBS.ShortByteString ->
        Addr ->
        IO CoalitionEnv
    setupCoalition env coalitionBytes' coalitionAddr' = do
        let shopPk =
                rawSerialiseVerKeyDSIGN
                    (Cardano.Crypto.DSIGN.deriveVerKeyDSIGN (deShopKey env))
            reificatorPk =
                rawSerialiseVerKeyDSIGN
                    (Cardano.Crypto.DSIGN.deriveVerKeyDSIGN (deReificatorKey env))
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

{- | Build and submit a redemption tx. The reificator signs
@own_ref.transaction_id || "REDEEM"@ and submits the tx.
-}
submitRedeem ::
    DevnetEnv ->
    AlonzoScript ConwayEra ->
    CoalitionEnv ->
    TxIn ->
    TxOut ConwayEra ->
    IO SubmitResult
submitRedeem env voucherScript' coalEnv voucherIn voucherOut = do
    -- Fund a fresh fee + collateral UTxO for the redeem tx.
    -- We can't reuse the settlement's reificator UTxOs — they're
    -- spent. Fund from genesis.
    (feeIn, feeOut, colIn, _colOut) <-
        fundReificator env

    let TxIn (TxId txIdHash) _ = voucherIn
        txIdBytes = hashToBytes (extractHash txIdHash)
        message = txIdBytes <> "REDEEM"
        reificatorSig =
            rawSerialiseSigDSIGN
                (signDSIGN () message (ceReificatorKey coalEnv))

        reificatorKeyHash :: KeyHash Guard
        reificatorKeyHash =
            hashKey
                (VKey (Cardano.Crypto.DSIGN.deriveVerKeyDSIGN (ceReificatorKey coalEnv)))

        prog :: TxBuild NoQ () ()
        prog = do
            _ <-
                redeemVoucher
                    voucherIn
                    colIn
                    (ceCoalitionTxIn coalEnv)
                    reificatorKeyHash
                    voucherScript'
                    reificatorSig
            _ <- spend feeIn
            pure ()

        interpret :: InterpretIO NoQ
        interpret = InterpretIO (\case {})

        eval tx =
            fmap
                (Map.map (either (Left . show) (Right . bumpExUnits)))
                (evaluateTx (deProvider env) tx)

        -- Coalition UTxO is a reference input only — must NOT be in
        -- inputUtxos to avoid BabbageNonDisjointRefInputs.
        inputUtxos =
            [ (voucherIn, voucherOut)
            , (feeIn, feeOut)
            ]

    result <-
        build
            (dePParams env)
            interpret
            eval
            inputUtxos
            (deReificatorAddr env)
            prog
    case result of
        Left (EvalFailure _purpose msg) -> pure (Rejected (BS8.pack msg))
        Left err -> error ("submitRedeem: build failed: " <> show err)
        Right tx -> do
            let signed = addKeyWitness (ceReificatorKey coalEnv) tx
            submitTx (deSubmitter env) signed

{- | Fund the reificator with a fee and collateral UTxO from genesis.
Returns (feeIn, feeOut, collateralIn, collateralOut).
-}
fundReificator ::
    DevnetEnv ->
    IO (TxIn, TxOut ConwayEra, TxIn, TxOut ConwayEra)
fundReificator env = do
    utxos <- queryUTxOs (deProvider env) genesisAddr
    seed <- case utxos of
        (u : _) -> pure u
        [] -> error "fundReificator: no genesis UTxOs"
    let (seedIn, _) = seed
        feePay = Coin 50_000_000
        collateralPay = Coin 10_000_000

        signerHash :: KeyHash Guard
        signerHash = hashKey (VKey (Cardano.Node.Client.E2E.Setup.deriveVerKeyDSIGN genesisSignKey))

        interpret :: InterpretIO NoQ
        interpret = InterpretIO (\case {})

        eval tx =
            fmap
                (Map.map (either (Left . show) Right))
                (evaluateTx (deProvider env) tx)

        prog :: TxBuild NoQ () ()
        prog = do
            _ <- spend seedIn
            _ <- payTo (deReificatorAddr env) (inject feePay :: MaryValue)
            _ <- payTo (deReificatorAddr env) (inject collateralPay :: MaryValue)
            requireSignature signerHash
            _ <- peek (const (Ok ()))
            pure ()

    result <-
        build
            (dePParams env)
            interpret
            eval
            [seed]
            genesisAddr
            prog
    case result of
        Left err -> error ("fundReificator: build failed: " <> show err)
        Right tx -> do
            let signed = addKeyWitness genesisSignKey tx
            submitTx (deSubmitter env) signed >>= \case
                Rejected reason ->
                    error
                        ("fundReificator: rejected: " <> show reason)
                Submitted _txId -> pure ()

    -- Poll until UTxOs with the exact funded amounts appear.
    -- The reificator address may already have change UTxOs from the
    -- spend phase, so 'waitForUtxos' would return immediately with
    -- stale UTxOs before the funding tx is confirmed.
    (fIn, fOut, cIn, cOut) <-
        waitForFunded (deProvider env) (deReificatorAddr env) feePay collateralPay 30
    pure (fIn, fOut, cIn, cOut)

waitForNewUtxo ::
    Provider IO ->
    Addr ->
    TxIn ->
    Int ->
    IO [(TxIn, TxOut ConwayEra)]
waitForNewUtxo provider addr oldIn attempts
    | attempts <= 0 =
        error ("waitForNewUtxo: timed out at " <> show addr)
    | otherwise = do
        utxos <- queryUTxOs provider addr
        let fresh = filter (\(i, _) -> i /= oldIn) utxos
        if null fresh
            then do
                threadDelay 1_000_000
                waitForNewUtxo provider addr oldIn (attempts - 1)
            else pure fresh

waitForUtxos ::
    Provider IO ->
    Addr ->
    Int ->
    IO [(TxIn, TxOut ConwayEra)]
waitForUtxos provider addr attempts
    | attempts <= 0 =
        error ("waitForUtxos: timed out at " <> show addr)
    | otherwise = do
        utxos <- queryUTxOs provider addr
        if null utxos
            then do
                threadDelay 1_000_000
                waitForUtxos provider addr (attempts - 1)
            else pure utxos

{- | Poll until UTxOs with the exact fee and collateral amounts appear
at the given address. Returns (feeIn, feeOut, collateralIn, collateralOut).
-}
waitForFunded ::
    Provider IO ->
    Addr ->
    Coin ->
    Coin ->
    Int ->
    IO (TxIn, TxOut ConwayEra, TxIn, TxOut ConwayEra)
waitForFunded provider addr feePay collateralPay attempts
    | attempts <= 0 =
        error "waitForFunded: timed out waiting for funded UTxOs"
    | otherwise = do
        utxos <- queryUTxOs provider addr
        let fees = filter (\(_, o) -> o ^. coinTxOutL == feePay) utxos
            cols = filter (\(_, o) -> o ^. coinTxOutL == collateralPay) utxos
        case (fees, cols) of
            ((f : _), (c : _)) -> pure (fst f, snd f, fst c, snd c)
            _ -> do
                threadDelay 1_000_000
                waitForFunded provider addr feePay collateralPay (attempts - 1)

isRejected :: SubmitResult -> Bool
isRejected (Rejected _) = True
isRejected _ = False
