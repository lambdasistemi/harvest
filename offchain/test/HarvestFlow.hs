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

T011 introduced the data type plus 'bootstrapCoalition'.  T017 adds
'GovOp' + 'submitGovernance' — the reificator-paid helper that builds
a coalition-spend tx carrying an issuer-signed 'GovernanceRedeemer'
and returns a 'HarvestFlow' refreshed with the rotated coalition UTxO.
-}
module HarvestFlow (
    HarvestFlow (..),
    bootstrapCoalition,
    GovOp (..),
    submitGovernance,
    bumpExUnits,
) where

import Cardano.Crypto.DSIGN (
    deriveVerKeyDSIGN,
    rawSerialiseSigDSIGN,
    rawSerialiseVerKeyDSIGN,
    signDSIGN,
 )
import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Scripts.Data (Datum (Datum))
import Cardano.Ledger.Api.Tx.Out (TxOut, coinTxOutL, datumTxOutL)
import Cardano.Ledger.Plutus.Data (
    binaryDataToData,
    getPlutusData,
 )
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
import Cardano.Ledger.Plutus.ExUnits (ExUnits (..))
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import qualified Cardano.Ledger.BaseTypes as BaseTypes
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
    attachScript,
    build,
    collateral,
    payTo,
    payTo',
    peek,
    requireSignature,
    spend,
    spendScript,
 )
import Cardano.Crypto.Hash.Class (hashToBytes)
import qualified Codec.Serialise as CBOR
import Control.Concurrent (threadDelay)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.ByteString.Short as SBS
import Lens.Micro ((^.))
import qualified PlutusCore.Data as PLC

import DevnetEnv (DevnetEnv (..))
import qualified Harvest.Script as Script
import Harvest.Actions (UserId)
import Harvest.Types (CoalitionDatum (..), GovernanceRedeemer (..))
import PlutusTx.IsData.Class (fromData)

-- | Empty query type — these progs have no 'ctx' calls.
data NoQ a
    deriving ()

{- | Live state threaded through the @Devnet*Spec@ scenarios.

Holds the coalition-metadata UTxO, plus a fee-payer + collateral pair
owned by the reificator that governance and settlement txs draw from.
Per-customer voucher UTxOs accumulate in 'hfVoucherEntries' as
settlements land.
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
  * one fee-payer and one collateral UTxO owned by the reificator so
    downstream txs have a funded input and collateral.

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

{- | Governance operation applied to a 'CoalitionDatum'.

Mirrors the three 'GovernanceRedeemer' constructors but at the harness
abstraction level: 'submitGovernance' takes a 'GovOp' and fabricates
the signed redeemer + transitioned datum internally.
-}
data GovOp
    = GovAddShop ByteString
    | GovAddReificator ByteString
    | GovRevokeReificator ByteString
    deriving (Eq, Show)

{- | Submit a coalition-governance tx and return an updated
'HarvestFlow' whose 'hfCoalitionIn'/'hfCoalitionOut' point to the
rotated UTxO.

The reificator pays fees and posts collateral; no genesis UTxO is
touched.  The issuer_sig is computed over @serialise(own_ref) ||
op_tag || target_pk@ where @own_ref@ is the 'OutputReference' of the
coalition UTxO being spent (see
@specs/003-devnet-full-flow/contracts/coalition-metadata-datum.md@
§Governance redeemer for why @own_ref@ rather than @txid@).
-}
submitGovernance ::
    DevnetEnv ->
    -- | Applied coalition-metadata script bytes.
    SBS.ShortByteString ->
    -- | Coalition-metadata script address.
    Addr ->
    HarvestFlow ->
    GovOp ->
    IO HarvestFlow
submitGovernance env coalitionBytes coalitionAddress flow op = do
    let coalitionScript :: AlonzoScript ConwayEra
        coalitionScript = Script.coalitionScript coalitionBytes

        -- Current coalition datum reconstruction: the bootstrap and
        -- every prior 'submitGovernance' leave a fresh empty-or-sorted
        -- 'CoalitionDatum' on-chain, but we do not parse it out here
        -- — instead we keep a Haskell-side shadow by projecting the
        -- intended post-state from (op, existing state).  For T017
        -- the prior state is the bootstrap datum: both lists empty.
        -- T039 and beyond will thread a parsed datum through
        -- HarvestFlow; for now we reconstruct it from the op itself.
        issuerPk =
            rawSerialiseVerKeyDSIGN (deriveVerKeyDSIGN (deIssuerKey env))

        -- Determine (priorShops, priorReifs) by reading them out of
        -- the live coalition output's datum.  Fall back to empty
        -- lists if the datum is missing (bootstrap-only case).
        (priorShops, priorReifs) =
            coalitionLists (hfCoalitionOut flow) issuerPk

        (newDatum, opTag, targetPk) = case op of
            GovAddShop pk ->
                ( CoalitionDatum
                    { cdShopPks = insertSorted pk priorShops
                    , cdReificatorPks = priorReifs
                    , cdIssuerPk = issuerPk
                    }
                , BS.singleton 0x00
                , pk
                )
            GovAddReificator pk ->
                ( CoalitionDatum
                    { cdShopPks = priorShops
                    , cdReificatorPks = insertSorted pk priorReifs
                    , cdIssuerPk = issuerPk
                    }
                , BS.singleton 0x01
                , pk
                )
            GovRevokeReificator pk ->
                ( CoalitionDatum
                    { cdShopPks = priorShops
                    , cdReificatorPks = filter (/= pk) priorReifs
                    , cdIssuerPk = issuerPk
                    }
                , BS.singleton 0x02
                , pk
                )

        TxIn (TxId txIdHash) (BaseTypes.TxIx ix) = hfCoalitionIn flow
        txIdBytes = hashToBytes (extractHash txIdHash)

        -- Serialise via 'PlutusCore.Data.Data' so the bytes match
        -- Aiken's @builtin.serialise_data@ byte-for-byte.  Our local
        -- 'Cardano.PlutusData' encoder uses definite-length CBOR lists
        -- whereas Plutus canonical uses @encodeListLenIndef@ for the
        -- Constr payload, so we MUST go through 'PLC.Data' here.
        ownRefBytes =
            LBS.toStrict . CBOR.serialise $
                PLC.Constr 0 [PLC.B txIdBytes, PLC.I (fromIntegral ix)]

        message = ownRefBytes <> opTag <> targetPk

        issuerSig =
            rawSerialiseSigDSIGN
                (signDSIGN () message (deIssuerKey env))

        redeemer = case op of
            GovAddShop _ -> AddShop targetPk issuerSig
            GovAddReificator _ -> AddReificator targetPk issuerSig
            GovRevokeReificator _ -> RevokeReificator targetPk issuerSig

        reifFeeUtxo = (hfReificatorFeeIn flow, hfReificatorFeeOut flow)
        coalitionUtxo = (hfCoalitionIn flow, hfCoalitionOut flow)

        coalitionPay = hfCoalitionOut flow ^. coinTxOutL

        reifSignerHash :: KeyHash Guard
        reifSignerHash = guardKeyHashFromSignKey (deReificatorKey env)

        interpret :: InterpretIO NoQ
        interpret = InterpretIO (\case {})

        -- TxBuild's 'patchExUnits' uses 'evaluateTx' output verbatim.
        -- Between bisect (where we evaluate) and finalize (where we
        -- balance + bumpFee), the body changes — so the ScriptContext
        -- seen by the validator at submission can need marginally
        -- more units than the evaluator reported. Add a 10% margin
        -- on both axes to absorb that drift without making the
        -- transaction fail on a 142-byte overshoot.
        eval tx =
            fmap
                (Map.map (either (Left . show) (Right . bumpExUnits)))
                (evaluateTx (deProvider env) tx)

        prog :: TxBuild NoQ () ()
        prog = do
            attachScript coalitionScript
            collateral (hfReificatorCollateralIn flow)
            _ <- spend (hfReificatorFeeIn flow)
            _ <- spendScript (hfCoalitionIn flow) redeemer
            _ <- payTo' coalitionAddress (inject coalitionPay) newDatum
            requireSignature reifSignerHash
            _ <- peek (const (Ok ()))
            pure ()

    result <-
        build
            (dePParams env)
            interpret
            eval
            [reifFeeUtxo, coalitionUtxo]
            (deReificatorAddr env)
            prog
    case result of
        Left err ->
            error ("submitGovernance: build failed: " <> show err)
        Right tx -> do
            let signed = addKeyWitness (deReificatorKey env) tx
            submitTx (deSubmitter env) signed >>= \case
                Rejected reason ->
                    error
                        ( "submitGovernance: submitTx rejected: "
                            <> show reason
                        )
                Submitted _txId -> pure ()

    coalitionUtxos <-
        waitForNewCoalitionUtxo
            (deProvider env)
            coalitionAddress
            (hfCoalitionIn flow)
            30

    (coalIn', coalOut') <-
        case coalitionUtxos of
            u : _ -> pure u
            [] ->
                error
                    "submitGovernance: no rotated coalition UTxO after submit"

    -- The governance tx consumed 'hfReificatorFeeIn' and produced a
    -- change output back to 'deReificatorAddr'. Refresh the flow's
    -- fee slot with that change UTxO so chained 'submitGovernance'
    -- calls do not reference a spent input.
    (reifFeeIn', reifFeeOut') <-
        waitForFreshReificatorUtxo
            (deProvider env)
            (deReificatorAddr env)
            [hfReificatorFeeIn flow, hfReificatorCollateralIn flow]
            30

    pure
        flow
            { hfCoalitionIn = coalIn'
            , hfCoalitionOut = coalOut'
            , hfReificatorFeeIn = reifFeeIn'
            , hfReificatorFeeOut = reifFeeOut'
            }

{- | Lookup the sorted-unique insertion of @x@ into @xs@ (byte order).
-}
insertSorted :: ByteString -> [ByteString] -> [ByteString]
insertSorted x [] = [x]
insertSorted x (y : ys)
    | x == y = y : ys
    | x < y = x : y : ys
    | otherwise = y : insertSorted x ys

{- | Project @(shops, reifs)@ from the live coalition 'TxOut'.

Parses the inline datum; if it cannot be parsed as a 'CoalitionDatum'
the harness errors out rather than silently losing the prior
registry (which would then cause the validator to reject the next
governance tx for dropping entries).
-}
coalitionLists ::
    TxOut ConwayEra ->
    -- | Expected @issuer_pk@, used purely as the default in the
    -- fallback branch below (not checked against the datum here).
    ByteString ->
    ([ByteString], [ByteString])
coalitionLists out _issuerPk =
    case out ^. datumTxOutL of
        Datum bd ->
            case fromData (getPlutusData (binaryDataToData bd)) of
                Just cd -> (cdShopPks cd, cdReificatorPks cd)
                Nothing ->
                    error
                        "coalitionLists: inline datum is not a CoalitionDatum"
        _ ->
            error
                "coalitionLists: coalition output has no inline datum"

{- | Bump 'ExUnits' by 10% on both axes. Absorbs the drift between
'evaluateTx' (which runs on the mid-bisect tx) and the final
submission tx, whose ScriptContext can differ slightly because
'finalize' re-balances and bumps the fee after patching ExUnits.
-}
bumpExUnits :: ExUnits -> ExUnits
bumpExUnits eu =
    ExUnits
        { exUnitsMem = (exUnitsMem eu * 11) `div` 10 + 1
        , exUnitsSteps = (exUnitsSteps eu * 11) `div` 10 + 1
        }

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

{- | Poll until the coalition address holds a UTxO whose 'TxIn' is not
the given old one (the rotated-out input).  Returns all coalition
UTxOs in that state.
-}
waitForNewCoalitionUtxo ::
    Provider IO ->
    Addr ->
    TxIn ->
    Int ->
    IO [(TxIn, TxOut ConwayEra)]
waitForNewCoalitionUtxo provider addr oldIn attempts
    | attempts <= 0 =
        error ("waitForNewCoalitionUtxo: timed out at " <> show addr)
    | otherwise = do
        utxos <- queryUTxOs provider addr
        let fresh = filter (\(i, _) -> i /= oldIn) utxos
        if null fresh
            then do
                threadDelay 1_000_000
                waitForNewCoalitionUtxo provider addr oldIn (attempts - 1)
            else pure fresh

{- | Poll until the reificator address holds a UTxO whose 'TxIn' is
NOT in the given exclusion list (typically: the just-spent fee input
plus the still-locked collateral input).  Returns the first such
UTxO — the change output of the governance tx.
-}
waitForFreshReificatorUtxo ::
    Provider IO ->
    Addr ->
    [TxIn] ->
    Int ->
    IO (TxIn, TxOut ConwayEra)
waitForFreshReificatorUtxo provider addr excluded attempts
    | attempts <= 0 =
        error
            ( "waitForFreshReificatorUtxo: timed out at "
                <> show addr
            )
    | otherwise = do
        utxos <- queryUTxOs provider addr
        case filter (\(i, _) -> i `notElem` excluded) utxos of
            (u : _) -> pure u
            [] -> do
                threadDelay 1_000_000
                waitForFreshReificatorUtxo
                    provider
                    addr
                    excluded
                    (attempts - 1)
