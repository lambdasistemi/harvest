-- | Build voucher spend and redeem transactions using the TxBuild DSL.
module Harvest.Transaction (
    spendVoucher,
    redeemVoucher,
) where

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Conway.Scripts (AlonzoScript)
import Cardano.Ledger.Keys (KeyHash, KeyRole (Guard))
import Cardano.Ledger.Mary.Value (MaryValue)
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Node.Client.TxBuild (
    TxBuild,
    attachScript,
    collateral,
    payTo',
    reference,
    requireSignature,
    spendScript,
 )
import Data.ByteString (ByteString)
import Data.Word (Word32)
import Harvest.Types (
    Groth16Proof,
    RedeemRedeemer (..),
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
    -- | Coalition-metadata UTxO (reference input)
    TxIn ->
    -- | Reificator key hash (for requireSignature)
    KeyHash Guard ->
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
    -- | pk_c_hi (customer Ed25519 pk, first 16 bytes as BE int)
    Integer ->
    -- | pk_c_lo (customer Ed25519 pk, last 16 bytes as BE int)
    Integer ->
    -- | customer_pubkey (32-byte Ed25519 compressed pk)
    ByteString ->
    -- | customer_signature (64-byte Ed25519 signature over signed_data)
    ByteString ->
    -- | signed_data (106-byte canonical payload)
    ByteString ->
    -- | The ZK proof
    Groth16Proof ->
    -- | shop_pk (32-byte Ed25519 pk, frozen in datum)
    ByteString ->
    -- | reificator_pk (32-byte Ed25519 pk, frozen in datum)
    ByteString ->
    -- | (input index, output index)
    TxBuild q e (Word32, Word32)
spendVoucher
    userUtxo
    collateralUtxo
    coalitionRefUtxo
    reificatorKeyHash
    script
    scriptAddr
    lockedValue
    userId
    d
    commitNew
    issuerAx
    issuerAy
    pkcHi
    pkcLo
    customerPubkey
    customerSignature
    signedData
    proof
    shopPk
    reificatorPk = do
        -- Attach the validator script
        attachScript script
        -- Add collateral
        collateral collateralUtxo
        -- Coalition-metadata reference input
        reference coalitionRefUtxo
        -- Reificator must sign
        requireSignature reificatorKeyHash
        -- Spend the user's UTXO with the redeemer
        spendIdx <-
            spendScript
                userUtxo
                SpendRedeemer
                    { srD = d
                    , srCommitSpentNew = commitNew
                    , srIssuerAx = issuerAx
                    , srIssuerAy = issuerAy
                    , srPkcHi = pkcHi
                    , srPkcLo = pkcLo
                    , srCustomerPubkey = customerPubkey
                    , srCustomerSignature = customerSignature
                    , srSignedData = signedData
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
                    , vdShopPk = shopPk
                    , vdReificatorPk = reificatorPk
                    }
        pure (spendIdx, outIdx)

{- | Build a voucher redemption transaction.

The reificator removes a voucher entry. No output is produced at the
script address — the entry is destroyed. The reificator signs
@own_ref.transaction_id || "REDEEM"@ (38 bytes) to prove authorisation.

The TxBuild program does not include fee balancing — call @build@
from "Cardano.Node.Client.TxBuild" to balance and finalize.
-}
redeemVoucher ::
    -- | Voucher UTxO to redeem (script-locked with VoucherDatum)
    TxIn ->
    -- | Collateral UTXO (from the reificator's wallet)
    TxIn ->
    -- | Coalition-metadata UTxO (reference input)
    TxIn ->
    -- | Reificator key hash (for requireSignature)
    KeyHash Guard ->
    -- | The voucher_redeem validator script
    AlonzoScript ConwayEra ->
    -- | Reificator's Ed25519 signature over (txid || "REDEEM")
    ByteString ->
    -- | (input index)
    TxBuild q e Word32
redeemVoucher
    voucherUtxo
    collateralUtxo
    coalitionRefUtxo
    reificatorKeyHash
    script
    reificatorSig = do
        attachScript script
        collateral collateralUtxo
        reference coalitionRefUtxo
        requireSignature reificatorKeyHash
        spendScript
            voucherUtxo
            RedeemRedeemer
                { rrReificatorSig = reificatorSig
                }
