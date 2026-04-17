-- | Build a voucher spend transaction using the TxBuild DSL.
module Harvest.Transaction (
    spendVoucher,
) where

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Conway.Scripts (AlonzoScript)
import Cardano.Ledger.Mary.Value (MaryValue)
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Node.Client.TxBuild (
    TxBuild,
    attachScript,
    collateral,
    payTo',
    spendScript,
 )
import Data.Word (Word32)
import Harvest.Types (
    Groth16Proof,
    SpendRedeemer (..),
    VoucherDatum (..),
 )

{- | Build a voucher spend transaction.

The supermarket submits the transaction. The user has no wallet.

Inputs:
  - User's UTXO (locked at the validator script address)
  - Collateral UTXO (from the supermarket's wallet)
  - The validator script (attached to the transaction)

Outputs:
  - Updated UTXO at the same script address with new commitment

The TxBuild program does not include fee balancing — call @build@
from "Cardano.Node.Client.TxBuild" to balance and finalize.
-}
spendVoucher ::
    -- | User's UTXO (script-locked with VoucherDatum)
    TxIn ->
    -- | Supermarket's collateral UTXO
    TxIn ->
    -- | The voucher_spend validator script
    AlonzoScript ConwayEra ->
    -- | Script address (where the output goes back)
    Addr ->
    -- | Value locked in the UTXO (passed through)
    MaryValue ->
    -- | user_id (Poseidon hash of user_secret)
    Integer ->
    -- | d (spend amount)
    Integer ->
    -- | commit_spent_new (new Poseidon commitment)
    Integer ->
    -- | issuer_ax (issuer's EdDSA public key, x coordinate)
    Integer ->
    -- | issuer_ay (issuer's EdDSA public key, y coordinate)
    Integer ->
    -- | The ZK proof
    Groth16Proof ->
    -- | (input index, output index)
    TxBuild q e (Word32, Word32)
spendVoucher
    userUtxo
    collateralUtxo
    script
    scriptAddr
    lockedValue
    userId
    d
    commitNew
    issuerAx
    issuerAy
    proof = do
        -- Attach the validator script
        attachScript script
        -- Add collateral
        collateral collateralUtxo
        -- Spend the user's UTXO with the redeemer
        spendIdx <-
            spendScript
                userUtxo
                SpendRedeemer
                    { srD = d
                    , srCommitSpentNew = commitNew
                    , srIssuerAx = issuerAx
                    , srIssuerAy = issuerAy
                    , srProof = proof
                    }
        -- Output back to the script address with updated datum
        outIdx <-
            payTo'
                scriptAddr
                lockedValue
                VoucherDatum
                    { vdUserId = userId
                    , vdCommitSpent = commitNew
                    }
        pure (spendIdx, outIdx)
