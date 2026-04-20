{-# LANGUAGE DataKinds #-}
{-# LANGUAGE EmptyCase #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : SpendScenario
Description : Submit the voucher spend tx on a running devnet.

Takes a 'SpendBundle' (the customer's ZK proof + Ed25519 bundle) and a
'DeployedSpend' (the UTxOs the setup tx left on-chain), re-signs
@signed_data@ against the reificator's live fee TxOutRef, builds the
settlement tx through the shared 'Harvest.Transaction.spendVoucher'
builder, balances via 'build', signs with the reificator's key, and
submits.

Returns the node's 'SubmitResult' verbatim so each scenario can
assert on 'Submitted' / 'Rejected' without the harness editorialising
the outcome.

Negative tests pass a non-identity 'Mutations' record to corrupt
exactly one input at the point of the pipeline that matches the
documented attack vector. Four hooks are exposed:

  * 'mBundle': rewrites the 'SpendBundle' before anything else. Affects
    both the re-sign inputs and the redeemer fields pulled out of the
    bundle (so a mutation here can desync redeemer vs signed_data).
  * 'mLiveTxid' / 'mLiveIx': rewrite the 'TxOutRef' bound into
    @signed_data@ by the re-sign step. The tx's @inputs@ still come
    from the real 'DeployedSpend' UTxOs, so a mutation here exercises
    the validator's @signed_data.txOutRef ∈ tx.inputs@ check.
  * 'mSignedData': flips bytes in @signed_data@ AFTER the re-sign.
    The signature was computed over the un-mutated bytes, so any
    mutation here breaks the Ed25519 coupling.
-}
module SpendScenario (
    Mutations (..),
    identityMutations,
    CoalitionEnv (..),
    submitSpend,
) where

import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Groth16.Types (CompressedProof (..))
import Cardano.Ledger.Api.Tx.Out (TxOut)
import Cardano.Ledger.BaseTypes (TxIx (..))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
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
    Ed25519DSIGN,
    SignKeyDSIGN,
    addKeyWitness,
    deriveVerKeyDSIGN,
 )
import Cardano.Node.Client.Provider (Provider (..))
import Cardano.Node.Client.Submitter (
    SubmitResult (..),
    Submitter (..),
 )
import Cardano.Node.Client.TxBuild (
    BuildError (..),
    InterpretIO (..),
    TxBuild,
    build,
 )
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base16 as Base16
import qualified Data.ByteString.Char8 as BS8
import qualified Data.ByteString.Short as SBS
import Data.Char (isHexDigit)
import qualified Data.Map.Strict as Map
import Data.Word (Word16)

import DevnetEnv (DevnetEnv (..))
import Fixtures (SpendBundle (..))
import qualified Harvest.Script as Script
import Harvest.Transaction (spendVoucher)
import Harvest.Types (Groth16Proof (..))
import qualified SpendHarness
import SpendSetup (DeployedSpend (..))

{- | Four orthogonal hooks into the spend pipeline. The golden path
uses 'identityMutations'; each negative test overrides exactly the
hook that matches its documented attack vector.
-}
data Mutations = Mutations
    { mBundle :: SpendBundle -> SpendBundle
    -- ^ Rewrite the bundle before anything else.
    , mLiveTxid :: BS.ByteString -> BS.ByteString
    -- ^ Rewrite the 32-byte @txid@ bound into @signed_data@.
    , mLiveIx :: Word16 -> Word16
    -- ^ Rewrite the @ix@ bound into @signed_data@.
    , mSignedData :: BS.ByteString -> BS.ByteString
    -- ^ Rewrite @signed_data@ AFTER re-signing (breaks the sig coupling).
    }

-- | No-op on every hook: the golden path runs the bundle unchanged.
identityMutations :: Mutations
identityMutations =
    Mutations
        { mBundle = id
        , mLiveTxid = id
        , mLiveIx = id
        , mSignedData = id
        }

{- | Coalition state needed by the spend scenario: the reference UTxO
and the reificator's signing key (for 'requireSignature').
-}
data CoalitionEnv = CoalitionEnv
    { ceCoalitionTxIn :: TxIn
    , ceCoalitionTxOut :: TxOut ConwayEra
    , ceReificatorKey :: SignKeyDSIGN Ed25519DSIGN
    }

-- | Empty 'ctx' query type: the spend prog uses no queries.
data NoQ a
    deriving ()

-- | Build and submit the spend tx; return the node's verdict verbatim.
submitSpend ::
    DevnetEnv ->
    SpendBundle ->
    DeployedSpend ->
    CoalitionEnv ->
    Mutations ->
    IO SubmitResult
submitSpend env bundle0 deployed coalEnv muts = do
    let bundle = mBundle muts bundle0

        script = Script.loadScript (decodeHex (sbAppliedScriptHex bundle0))
        scriptAddress = dsScriptAddr deployed

        -- Live TxOutRef we bind into signed_data. Using the fee UTxO
        -- (a regular input) so that 'signed_data.TxOutRef ∈ tx.inputs'
        -- is satisfied on the golden path. Negative tests override
        -- via 'mLiveTxid' / 'mLiveIx' to exercise the membership check.
        TxIn (TxId txIdHash) (TxIx liveIx) = dsReificatorFeeTxIn deployed
        liveTxid = mLiveTxid muts (hashToBytes (extractHash txIdHash))
        liveIx16 :: Word16
        liveIx16 = mLiveIx muts (fromIntegral liveIx)

    (reSignedData0, reSignature) <-
        case SpendHarness.resignedData
            (sbSkC bundle)
            (sbSignedData bundle)
            liveTxid
            liveIx16 of
            Just (sd, sig) -> pure (sd, sig)
            Nothing ->
                error
                    "submitSpend: SpendHarness.resignedData \
                    \returned Nothing (sk_c wrong length?)"

    let
        -- Post-sign tamper: breaks the Ed25519 coupling for T030-class
        -- scenarios. For the golden path and mutations that run
        -- through mBundle / mLiveTxid this is a no-op.
        reSignedData = mSignedData muts reSignedData0

    let
        -- After the mutation the bundle fields go into the redeemer;
        -- the re-sign step binds the LIVE TxOutRef onto the (possibly
        -- mutated) bundle, so a d-mismatch mutation propagates into
        -- the redeemer while the signed_data d stays tied to bundle.d.
        redeemerD = sbD bundle
        pkcHi = sbPkCHi bundle
        pkcLo = sbPkCLo bundle
        customerPubkey = sbCustomerPubkey bundle

        -- Public inputs 1..5 are fixture-derived and don't change
        -- across scenarios.
        commitNew = sbPublicInputs bundle !! 2
        userId = sbPublicInputs bundle !! 3
        issuerAx = sbPublicInputs bundle !! 4
        issuerAy = sbPublicInputs bundle !! 5

        proof = compressedToGroth16 (sbProof bundle)

        lockedValue :: MaryValue
        lockedValue = inject (dsScriptPay deployed)

        reificatorKeyHash :: KeyHash Guard
        reificatorKeyHash =
            hashKey (VKey (deriveVerKeyDSIGN (ceReificatorKey coalEnv)))

        prog :: TxBuild NoQ () ()
        prog = do
            _ <-
                spendVoucher
                    (dsScriptTxIn deployed)
                    (dsReificatorCollateralTxIn deployed)
                    (ceCoalitionTxIn coalEnv)
                    reificatorKeyHash
                    script
                    scriptAddress
                    lockedValue
                    userId
                    redeemerD
                    commitNew
                    issuerAx
                    issuerAy
                    pkcHi
                    pkcLo
                    customerPubkey
                    reSignature
                    reSignedData
                    proof
                    (dsShopPk deployed)
                    (dsReificatorPk deployed)
            pure ()

        interpret :: InterpretIO NoQ
        interpret = InterpretIO (\case {})

        eval tx =
            fmap
                (Map.map (either (Left . show) Right))
                (evaluateTx (deProvider env) tx)

        -- 'build' auto-adds all inputUtxos to the regular inputs of
        -- the tx. Pass both the script UTxO (already spent via
        -- spendScript inside spendVoucher; adding here is a no-op
        -- because inputs is a Set) and the reificator fee UTxO
        -- (needed so 'build' can subtract fees + leave change).
        inputUtxos =
            [ (dsScriptTxIn deployed, dsScriptTxOut deployed)
            , (dsReificatorFeeTxIn deployed, dsReificatorFeeTxOut deployed)
            , (ceCoalitionTxIn coalEnv, ceCoalitionTxOut coalEnv)
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
        -- Script-evaluation failure during 'build' is the phase-2
        -- validator rejecting the tx before we even submit. Negative
        -- tests care only that the validator said no — they don't
        -- distinguish phase-2 rejection from node-layer rejection.
        Left (EvalFailure _purpose msg) -> pure (Rejected (BS8.pack msg))
        Left err -> error ("submitSpend: build failed: " <> show err)
        Right tx -> do
            let signed = addKeyWitness (deReificatorKey env) tx
            submitTx (deSubmitter env) signed

compressedToGroth16 :: CompressedProof -> Groth16Proof
compressedToGroth16 cp =
    Groth16Proof
        { gpA = cpA cp
        , gpB = cpB cp
        , gpC = cpC cp
        }

decodeHex :: BS.ByteString -> SBS.ShortByteString
decodeHex bs =
    case Base16.decode (BS8.filter isHexDigit bs) of
        Right decoded -> SBS.toShort decoded
        Left e -> error ("decodeHex: " <> e)

-- Keep the Coin constructor reachable even though 'build' computes
-- fees itself — it's load-bearing context for the comment above.
_coin :: Coin -> Coin
_coin = id
