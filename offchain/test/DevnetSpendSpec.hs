{- |
Module      : DevnetSpendSpec
Description : End-to-end documentation of a voucher spend (FR-001, FR-002).

== Reading this module as documentation

This test file is the executable narrative of how a harvest voucher
spend works end-to-end, against a real Cardano devnet. If the reader
wants to understand how the three components of the protocol
(the Groth16 circuit, the customer Ed25519 signature, the Aiken
validator) compose into a submitted Cardano transaction, reading this
module top-to-bottom is the recommended path.

Each 'it' block names an actor or a defended invariant in the spec's
vocabulary rather than an implementation detail, and the narrative
comments link each step back to the protocol constitution principle it
enforces.

== The flow

1. The coalition runs a devnet with a single genesis key that holds all
   the ADA. The harvest test suite spawns this devnet on demand via
   'withDevnet' from "Cardano.Node.Client.E2E.Setup" — the same bracket
   every cardano-node-clients e2e test uses, so the exact network
   semantics under test match the semantics a real reificator will
   encounter.

2. The reificator is just an Ed25519 key derived from a fixed seed.
   It needs ADA to pay tx fees and posts to the chain on the customer's
   behalf. The setup transaction funds the reificator from genesis and
   simultaneously deploys the voucher script UTxO carrying the initial
   'VoucherDatum' — this is phase "0 + shop onboarding" from the
   constitution, collapsed into one tx because neither party matters
   for a single-spend test.

3. The customer has already produced the Groth16 proof and the
   Ed25519 signature off-line on their phone; both are committed as
   fixtures under @offchain/test/fixtures@. The 'SpendBundle' loader
   in "Fixtures" just reads them; this test does not re-derive any
   cryptographic material.

4. The reificator builds the settlement tx using the shared
   'Harvest.Transaction.spendVoucher' builder — the exact same code
   path a production reificator will use, with a 'TxBuild' DSL step
   that attaches the validator script and the redeemer carrying the
   proof plus the customer signature plus the cross-check values.

5. The tx is balanced via 'evaluateAndBalance', signed with the
   reificator's Ed25519 key (required because the reificator is both
   the script-tx submitter and the fee payer), and submitted to the
   devnet.

6. The node accepts or rejects. Rejection with any reason is a failure
   of the happy path (US1) and a success of whichever mutation caused
   the rejection (US2). The test does not match on the error text
   because the ledger may reword it across versions — only the
   'SubmitResult' constructor matters.
-}
module DevnetSpendSpec (spec) where

import DevnetEnv (DevnetEnv (..), withEnv)
import Fixtures (SpendBundle (..), loadBundle)
import SpendSetup (DeployedSpend (..), deploySpendState)
import Test.Hspec (Spec, around, describe, it, pendingWith, runIO, shouldSatisfy)

spec :: Spec
spec = describe "Devnet spend end-to-end (FR-001, FR-002)" $ do
    bundle <- runIO loadBundle

    -- The bundle-load step is a hard runtime check: if the fixture
    -- tree is missing or malformed, every scenario below is moot.
    it "loads the fixture bundle cleanly" $
        sbD bundle `seq`
            (pure () :: IO ())

    around withEnv $ do
        -- == Environment sanity ==
        --
        -- First gate on the devnet bracket itself: after 'withDevnet'
        -- has come up, the genesis address must be funded (this is the
        -- starting condition for every scenario that follows). If this
        -- fails, the devnet environment is broken and nothing
        -- downstream is meaningful.
        it "devnet comes up with a funded genesis address" $ \env ->
            deGenesisUtxos env `shouldSatisfy` (not . null)

        -- == Golden path (T021, FR-001) ==
        --
        -- Narrative: a legitimate customer spends d tokens at an acceptor.
        -- The customer's phone has already produced the proof and
        -- signature; the reificator submits. The validator accepts.
        --
        -- What this test proves when it passes:
        --   * The applied validator bytecode (the one that ships on-chain)
        --     accepts a real submitted tx carrying the fixture bundle.
        --   * The Haskell tx builder in 'Harvest.Transaction' produces
        --     bytes the ledger can validate.
        --   * The three bindings from constitution §V hold together:
        --     d is bound by the Groth16 public input, acceptor_pk and
        --     TxOutRef are bound by the Ed25519 signature, and pk_c is
        --     bound both as a proof public input and via the
        --     byte-split cross-check.
        -- The deploy step lands a script UTxO at the voucher address
        -- carrying the initial VoucherDatum AND funds the reificator
        -- so it can pay for the spend tx. Both outputs come from one
        -- transaction, so success means both materialise.
        it "deploys the voucher script UTxO and funds the reificator" $ \env -> do
            deployed <- deploySpendState env bundle
            -- Both outputs must be distinct and present.
            dsScriptTxIn deployed `shouldSatisfy` (/= dsReificatorTxIn deployed)

        it "a customer spends at an acceptor — validator accepts" $ \_env ->
            pendingWith "T021: spend tx submit once harness + re-sign land"

        -- == Tampered signed_data (T030, FR-002.1) ==
        --
        -- The reificator captures the customer's bundle and flips a byte
        -- inside 'signed_data' before submitting — e.g. in an attempt to
        -- reroute the payment to a different TxOutRef. Plutus's
        -- VerifyEd25519Signature builtin rejects because the signature no
        -- longer matches. The transaction is refused by the node.
        it "defends against signed_data byte tampering" $ \_env ->
            pendingWith "T030"

        -- == d cross-check (T031, FR-002.2) ==
        --
        -- The customer signed "d = 10". The reificator submits a redeemer
        -- with "d = 80" (claiming the customer authorised 80 at the
        -- casher's POS). The validator's defence-in-depth equality check
        -- 'signed_data.d == redeemer.d' fails. Without this check, the
        -- reificator could inflate the redeemed amount past what the ZK
        -- proof actually authorised.
        it "defends against redeemer.d mismatch with signed_data.d" $ \_env ->
            pendingWith "T031"

        -- == pk_c split mismatch (T032, FR-002.3) ==
        --
        -- Someone captures the customer's proof and tries to pair it with
        -- a different customer's Ed25519 signature. The validator's
        -- byte-split check (customer_pubkey[0..16] must match pk_c_hi and
        -- [16..32] must match pk_c_lo — the proof's public inputs) fails.
        -- This keeps proofs and signatures from being mixed and matched
        -- across customers.
        it "defends against customer-key substitution" $ \_env ->
            pendingWith "T032"

        -- == TxOutRef absent (T033, FR-002.4) ==
        --
        -- The reificator submits a valid proof + signature but consumes a
        -- different UTxO than the one named in 'signed_data'. The
        -- validator's 'signed_data.txOutRef ∈ tx.inputs' check fails,
        -- preventing replay of a valid bundle into an unrelated tx.
        it "defends against TxOutRef replay" $ \_env ->
            pendingWith "T033"
