{-# LANGUAGE DataKinds #-}
{-# LANGUAGE EmptyCase #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : SpendSetup
Description : Deploy the initial voucher state on a running devnet.

Runs a single setup transaction that:

  1. Spends a genesis UTxO.
  2. Pays a generous fee-payer output to the reificator address.
  3. Creates the voucher script UTxO at the applied validator's address
     with an inline @VoucherDatum@ matching the fixture bundle's
     @commit_S_old@.
  4. Sends change back to the genesis address.

After submission it waits until both outputs are visible via
'queryUTxOs' and returns the pair of 'TxIn's the spend scenario will
later consume.

The 'witnessKeyHashFromSignKey' and 'waitForUtxos' helpers are copied
inline from cardano-node-clients' own 'TxBuildSpec' — they are not
exported from the public surface.
-}
module SpendSetup (
    DeployedSpend (..),
    deploySpendState,
) where

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Tx.Out (TxOut, coinTxOutL)
import Cardano.Ledger.BaseTypes (Network (..))
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
    deriveVerKeyDSIGN,
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
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base16 as Base16
import qualified Data.ByteString.Char8 as BS8
import qualified Data.ByteString.Short as SBS
import Data.Char (isHexDigit)
import qualified Data.Map.Strict as Map
import Lens.Micro ((^.))

import DevnetEnv (DevnetEnv (..))
import Fixtures (SpendBundle (..))
import qualified Harvest.Script as Script
import Harvest.Types (VoucherDatum (..))

-- | Empty query type — the setup prog has no 'ctx' calls.
data NoQ a
    deriving ()

{- | What the setup transaction left behind on-chain: the two
'TxOutRef's the spend scenario is going to consume, plus the
reified script address so tests can assert outputs landed there.
-}
data DeployedSpend = DeployedSpend
    { dsScriptTxIn :: TxIn
    , dsScriptTxOut :: TxOut ConwayEra
    , dsScriptAddr :: Addr
    , dsReificatorTxIn :: TxIn
    , dsReificatorTxOut :: TxOut ConwayEra
    , dsReificatorPay :: Coin
    {- ^ Value the setup tx paid to the reificator — exposed so tests
    can cross-check the funding amount.
    -}
    , dsScriptPay :: Coin
    -- ^ Value locked at the script address in the VoucherDatum UTxO.
    }

{- | Submit the setup tx and wait for the two outputs to appear.

Spends a genesis UTxO, outputs 100 ADA to the reificator's address
and a 5 ADA script UTxO carrying the fixture's 'VoucherDatum', then
lets 'build' balance the change back to 'genesisAddr'.

Throws on any error — the caller is an 'it' block and the error
message bubbles up as a test failure.
-}
deploySpendState :: DevnetEnv -> SpendBundle -> IO DeployedSpend
deploySpendState env bundle = do
    seed <- case deGenesisUtxos env of
        u : _ -> pure u
        [] -> error "deploySpendState: genesis has no UTxOs"
    let (seedIn, _seedOut) = seed

        script = Script.loadScript (decodeHex (sbAppliedScriptHex bundle))
        scriptAddress = Script.scriptAddr Testnet script

        -- The user_id and commit_S_old live at these positions in
        -- the circuit's public-input list (see 'Fixtures.SpendBundle'):
        -- [d, commit_S_old, commit_S_new, user_id, ...].
        userId = sbPublicInputs bundle !! 3
        commitOld = sbPublicInputs bundle !! 1

        voucherDatum =
            VoucherDatum
                { vdUserId = userId
                , vdCommitSpent = commitOld
                }

        reificatorPay = Coin 100_000_000
        scriptPay = Coin 5_000_000

        signerHash :: KeyHash Guard
        signerHash = guardKeyHashFromSignKey genesisSignKey

        -- No 'ctx' queries in this prog, so the interpreter never
        -- fires; a GADT with no constructors lets us write the
        -- handler as an empty case.
        interpret :: InterpretIO NoQ
        interpret = InterpretIO (\case {})

        eval tx =
            fmap
                (Map.map (either (Left . show) Right))
                (evaluateTx (deProvider env) tx)

        prog = do
            _ <- spend seedIn
            _ <- payTo (deReificatorAddr env) (injectCoin reificatorPay)
            _ <- payTo' scriptAddress (injectCoin scriptPay) voucherDatum
            requireSignature signerHash
            _ <- peek (const (Ok ()))
            pure ()

        -- Explicit annotation: the prog never raises a custom error.
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
        Left err -> error ("deploySpendState: build failed: " <> show err)
        Right tx -> do
            let signed = addKeyWitness genesisSignKey tx
            submitTx (deSubmitter env) signed >>= \case
                Rejected reason ->
                    error
                        ( "deploySpendState: submitTx rejected: "
                            <> show reason
                        )
                Submitted _txId -> pure ()

    reifUtxos <- waitForUtxos (deProvider env) (deReificatorAddr env) 30
    scriptUtxos <- waitForUtxos (deProvider env) scriptAddress 30

    (reifIn, reifOut) <- pickOne "reificator" reificatorPay reifUtxos
    (scriptIn, scriptOut) <- pickOne "script" scriptPay scriptUtxos

    pure
        DeployedSpend
            { dsScriptTxIn = scriptIn
            , dsScriptTxOut = scriptOut
            , dsScriptAddr = scriptAddress
            , dsReificatorTxIn = reifIn
            , dsReificatorTxOut = reifOut
            , dsReificatorPay = reificatorPay
            , dsScriptPay = scriptPay
            }
  where
    pickOne :: String -> Coin -> [(TxIn, TxOut ConwayEra)] -> IO (TxIn, TxOut ConwayEra)
    pickOne label expected utxos =
        case filter (\(_, o) -> o ^. coinTxOutL == expected) utxos of
            (u : _) -> pure u
            [] ->
                error
                    ( "deploySpendState: no "
                        <> label
                        <> " UTxO with expected value "
                        <> show expected
                        <> " (found: "
                        <> show (map (\(_, o) -> o ^. coinTxOutL) utxos)
                        <> ")"
                    )

    injectCoin :: Coin -> MaryValue
    injectCoin = inject

decodeHex :: BS.ByteString -> SBS.ShortByteString
decodeHex bs =
    case Base16.decode (BS8.filter isHexDigit bs) of
        Right decoded -> SBS.toShort decoded
        Left e -> error ("decodeHex: " <> e)

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
