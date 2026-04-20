{-# LANGUAGE DataKinds #-}
{-# LANGUAGE EmptyCase #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : HarvestFlow
Description : Test harness state threaded through the Devnet*Spec modules.

Per @specs/003-devnet-full-flow/data-model.md@ §HarvestFlow harness.
Each @Devnet*Spec@ owns its own @withDevnet@ bracket and threads a
'HarvestFlow' value to share coalition + per-customer UTxOs between
scenarios in the spec.

T011 — data type plus 'bootstrapCoalition'. The coalition script
address is passed in rather than imported from 'Harvest.Script' so
this module compiles before T012 wires @coalitionAddr@ through.
-}
module HarvestFlow (
    HarvestFlow (..),
    bootstrapCoalition,
) where

import Cardano.Crypto.DSIGN (
    deriveVerKeyDSIGN,
    rawSerialiseVerKeyDSIGN,
 )
import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Tx.Out (TxOut, coinTxOutL)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Keys (
    KeyHash,
    KeyRole (..),
    VKey (..),
    hashKey,
 )
import Cardano.Ledger.Mary.Value (MaryValue)
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Ledger.Val (inject)
import Cardano.Node.Client.E2E.Setup (
    Ed25519DSIGN,
    SignKeyDSIGN,
    addKeyWitness,
    genesisAddr,
    genesisSignKey,
 )
import Cardano.Node.Client.Provider (Provider (..))
import Cardano.Node.Client.Submitter (
    SubmitResult (..),
    Submitter (..),
 )
import Cardano.Node.Client.TxBuild (
    Convergence (..),
    InterpretIO (..),
    TxBuild,
    build,
    payTo,
    payTo',
    peek,
    requireSignature,
    spend,
 )
import Control.Concurrent (threadDelay)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Lens.Micro ((^.))

import DevnetEnv (DevnetEnv (..))
import Harvest.Actions (UserId)
import Harvest.Types (CoalitionDatum (..))

-- | Empty query type — the setup prog has no 'ctx' calls.
data NoQ a
    deriving ()

{- | Live state threaded through the @Devnet*Spec@ scenarios.

Holds the coalition-metadata UTxO produced at bootstrap, plus a
fee-payer UTxO owned by the reificator that subsequent governance
and settlement txs can draw from. Per-customer voucher UTxOs are
accumulated in 'hfVoucherEntries' as settlements land.
-}
data HarvestFlow = HarvestFlow
    { hfCoalitionIn :: TxIn
    , hfCoalitionOut :: TxOut ConwayEra
    , hfReificatorFeeIn :: TxIn
    , hfReificatorFeeOut :: TxOut ConwayEra
    , hfReificatorCollateralIn :: TxIn
    , hfReificatorCollateralOut :: TxOut ConwayEra
    , hfVoucherEntries :: Map UserId (TxIn, TxOut ConwayEra)
    }

{- | Submit the coalition-create tx and build the initial 'HarvestFlow'.

Spends a genesis UTxO and produces:

  * one coalition-metadata UTxO at the given @coalitionAddr@ carrying
    an empty registry ('CoalitionDatum' with empty shop/reificator
    lists and @issuer_pk@ taken from 'deIssuerKey');
  * one fee-payer UTxO owned by the reificator so downstream txs
    have a funded input.

Change flows back to 'genesisAddr'. Errors become test failures via
'error' — this function is called from 'it' blocks.
-}
bootstrapCoalition ::
    DevnetEnv ->
    -- | Coalition-metadata script address (T012 supplies this from
    -- @Harvest.Script.coalitionAddr@; for now callers pass it
    -- explicitly).
    Addr ->
    IO HarvestFlow
bootstrapCoalition env coalitionAddress = do
    seed <- case deGenesisUtxos env of
        u : _ -> pure u
        [] -> error "bootstrapCoalition: genesis has no UTxOs"
    let (seedIn, _seedOut) = seed

        issuerPkBytes =
            rawSerialiseVerKeyDSIGN (deriveVerKeyDSIGN (deIssuerKey env))

        coalitionDatum =
            CoalitionDatum
                { cdShopPks = []
                , cdReificatorPks = []
                , cdIssuerPk = issuerPkBytes
                }

        -- Two reificator outputs because a Cardano tx can use a given
        -- UTxO as EITHER a regular input OR collateral, never both.
        reificatorFeePay = Coin 50_000_000
        reificatorCollateralPay = Coin 10_000_000
        coalitionPay = Coin 5_000_000

        signerHash :: KeyHash Guard
        signerHash = guardKeyHashFromSignKey genesisSignKey

        interpret :: InterpretIO NoQ
        interpret = InterpretIO (\case {})

        eval tx =
            fmap
                (Map.map (either (Left . show) Right))
                (evaluateTx (deProvider env) tx)

        prog = do
            _ <- spend seedIn
            _ <- payTo (deReificatorAddr env) (injectCoin reificatorFeePay)
            _ <-
                payTo
                    (deReificatorAddr env)
                    (injectCoin reificatorCollateralPay)
            _ <- payTo' coalitionAddress (injectCoin coalitionPay) coalitionDatum
            requireSignature signerHash
            _ <- peek (const (Ok ()))
            pure ()

        progT :: TxBuild NoQ () ()
        progT = prog

    result <-
        build
            (dePParams env)
            interpret
            eval
            [seed]
            genesisAddr
            progT
    case result of
        Left err ->
            error ("bootstrapCoalition: build failed: " <> show err)
        Right tx -> do
            let signed = addKeyWitness genesisSignKey tx
            submitTx (deSubmitter env) signed >>= \case
                Rejected reason ->
                    error
                        ( "bootstrapCoalition: submitTx rejected: "
                            <> show reason
                        )
                Submitted _txId -> pure ()

    reifUtxos <-
        waitForUtxos (deProvider env) (deReificatorAddr env) 30
    coalitionUtxos <-
        waitForUtxos (deProvider env) coalitionAddress 30

    (reifFeeIn, reifFeeOut) <-
        pickOne "reificator fee" reificatorFeePay reifUtxos
    (reifColIn, reifColOut) <-
        pickOne "reificator collateral" reificatorCollateralPay reifUtxos
    (coalIn, coalOut) <-
        pickOne "coalition" coalitionPay coalitionUtxos

    pure
        HarvestFlow
            { hfCoalitionIn = coalIn
            , hfCoalitionOut = coalOut
            , hfReificatorFeeIn = reifFeeIn
            , hfReificatorFeeOut = reifFeeOut
            , hfReificatorCollateralIn = reifColIn
            , hfReificatorCollateralOut = reifColOut
            , hfVoucherEntries = Map.empty
            }
  where
    pickOne ::
        String ->
        Coin ->
        [(TxIn, TxOut ConwayEra)] ->
        IO (TxIn, TxOut ConwayEra)
    pickOne label expected utxos =
        case filter (\(_, o) -> o ^. coinTxOutL == expected) utxos of
            (u : _) -> pure u
            [] ->
                error
                    ( "bootstrapCoalition: no "
                        <> label
                        <> " UTxO with expected value "
                        <> show expected
                    )

    injectCoin :: Coin -> MaryValue
    injectCoin = inject

guardKeyHashFromSignKey ::
    SignKeyDSIGN Ed25519DSIGN ->
    KeyHash Guard
guardKeyHashFromSignKey =
    hashKey . VKey . deriveVerKeyDSIGN

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
