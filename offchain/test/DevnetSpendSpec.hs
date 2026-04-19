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

import Cardano.Ledger.Api.Scripts.Data (Datum (NoDatum))
import Cardano.Ledger.Api.Tx.Out (addrTxOutL, coinTxOutL, datumTxOutL)
import Cardano.Node.Client.Submitter (SubmitResult (..))
import Data.Bits (xor)
import qualified Data.ByteString as BS
import Data.Word (Word8)
import DevnetEnv (DevnetEnv (..), withEnv)
import Fixtures (SpendBundle (..), loadBundle)
import Lens.Micro ((^.))
import SignedDataLayout (offsetAcceptorAy)
import SpendScenario (Mutations (..), identityMutations, submitSpend)
import SpendSetup (DeployedSpend (..), deploySpendState)
import Test.Hspec (
    Spec,
    around,
    describe,
    expectationFailure,
    it,
    runIO,
    shouldBe,
    shouldNotBe,
    shouldSatisfy,
 )

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
        -- so it can pay for the spend tx. The assertions below are
        -- load-bearing: each one fails if the setup tx produced the
        -- wrong address, wrong amount, or a missing inline datum.
        it "deploys the voucher script UTxO and funds the reificator" $ \env -> do
            d <- deploySpendState env bundle

            -- The script output must sit at the applied validator's
            -- address. If it doesn't, future spend scripts will never
            -- be invoked and the whole E2E path is vacuous.
            (dsScriptTxOut d ^. addrTxOutL) `shouldBe` dsScriptAddr d

            -- And carry the value we paid it.
            (dsScriptTxOut d ^. coinTxOutL) `shouldBe` dsScriptPay d

            -- And carry an inline datum (not NoDatum) — otherwise the
            -- validator has nothing to read user_id / commit_spent from.
            (dsScriptTxOut d ^. datumTxOutL) `shouldNotBe` NoDatum

            -- Both reificator outputs are at the reificator address
            -- with their declared amounts. Fee and collateral are
            -- deliberately separate UTxOs (see SpendSetup comment).
            (dsReificatorFeeTxOut d ^. addrTxOutL) `shouldBe` deReificatorAddr env
            (dsReificatorFeeTxOut d ^. coinTxOutL) `shouldBe` dsReificatorFeePay d
            (dsReificatorCollateralTxOut d ^. addrTxOutL) `shouldBe` deReificatorAddr env
            (dsReificatorCollateralTxOut d ^. coinTxOutL)
                `shouldBe` dsReificatorCollateralPay d
            dsReificatorFeeTxIn d `shouldSatisfy` (/= dsReificatorCollateralTxIn d)

        -- The golden-path scenario. Deploy the voucher script UTxO
        -- and the reificator's fee + collateral UTxOs, then build
        -- and submit the settlement tx. Any rejection fails the
        -- test — we don't match on the error text because the
        -- ledger may reword it across versions, only the constructor
        -- matters.
        it "a customer spends at an acceptor — validator accepts" $ \env -> do
            deployed <- deploySpendState env bundle
            result <- submitSpend env bundle deployed identityMutations
            case result of
                Submitted _txId -> pure ()
                Rejected reason ->
                    expectationFailure
                        ("validator rejected spend tx: " <> show reason)

        -- == Tampered signed_data (T030, FR-002.1) ==
        --
        -- The reificator captures the customer's bundle and flips a byte
        -- inside 'signed_data' AFTER the customer has signed it — the
        -- mutation runs through 'mSignedData', which the scenario applies
        -- post-re-sign. Plutus's VerifyEd25519Signature builtin then
        -- rejects because the signature no longer covers the byte that
        -- was flipped.
        it "defends against signed_data byte tampering" $ \env -> do
            deployed <- deploySpendState env bundle
            let muts =
                    identityMutations
                        { mSignedData = flipByteAt offsetAcceptorAy
                        }
            result <- submitSpend env bundle deployed muts
            result `shouldSatisfy` isRejected

        -- == d cross-check (T031, FR-002.2) ==
        --
        -- The customer signed "d = 10". The reificator submits a redeemer
        -- with "d = 80" — the mutation rewrites only the bundle's 'sbD'
        -- field (which feeds the redeemer) without touching 'sbSignedData',
        -- so the re-signed @signed_data.d@ still reads 10. The validator's
        -- defence-in-depth equality check 'signed_data.d == redeemer.d'
        -- fails. Without this check, the reificator could inflate the
        -- redeemed amount past what the ZK proof actually authorised.
        it "defends against redeemer.d mismatch with signed_data.d" $ \env -> do
            deployed <- deploySpendState env bundle
            let muts =
                    identityMutations
                        { mBundle = \b -> b{sbD = sbD b + 1}
                        }
            result <- submitSpend env bundle deployed muts
            result `shouldSatisfy` isRejected

        -- == pk_c split mismatch (T032, FR-002.3) ==
        --
        -- Someone captures the customer's proof and tries to pair it with
        -- a different customer's public key. The mutation flips a byte in
        -- 'sbCustomerPubkey' (the redeemer's customer_pubkey); the proof's
        -- pk_c_hi / pk_c_lo public inputs are untouched. The validator's
        -- byte-split check (customer_pubkey[0..16] must equal pk_c_hi and
        -- [16..32] must equal pk_c_lo) fails. This keeps proofs and
        -- signatures from being mixed and matched across customers.
        it "defends against customer-key substitution" $ \env -> do
            deployed <- deploySpendState env bundle
            let muts =
                    identityMutations
                        { mBundle = \b ->
                            b{sbCustomerPubkey = flipByteAt 0 (sbCustomerPubkey b)}
                        }
            result <- submitSpend env bundle deployed muts
            result `shouldSatisfy` isRejected

        -- == TxOutRef absent (T033, FR-002.4) ==
        --
        -- The reificator submits a valid proof + signature but 'signed_data'
        -- names a UTxO that the tx does not actually consume. The mutation
        -- overrides the 'txid' bound into 'signed_data' with a fabricated
        -- 32-byte value; the re-sign covers that bogus binding, so the
        -- Ed25519 check passes. The validator's
        -- 'signed_data.txOutRef ∈ tx.inputs' check then fails, preventing
        -- replay of a valid bundle into an unrelated tx.
        it "defends against TxOutRef replay" $ \env -> do
            deployed <- deploySpendState env bundle
            let muts =
                    identityMutations
                        { mLiveTxid = const (BS.replicate 32 0xAA)
                        }
            result <- submitSpend env bundle deployed muts
            result `shouldSatisfy` isRejected

{- | Flip a single byte of a 'BS.ByteString' at the given offset. Used
by the negative scenarios to corrupt exactly one byte without
changing the length.
-}
flipByteAt :: Int -> BS.ByteString -> BS.ByteString
flipByteAt i bs
    | i < 0 || i >= BS.length bs =
        error ("flipByteAt: out-of-range offset " <> show i)
    | otherwise =
        let (before, rest) = BS.splitAt i bs
            b :: Word8
            b = BS.head rest
         in before <> BS.cons (b `xor` 0xFF) (BS.drop 1 rest)

{- | True iff the node rejected the tx. Any rejection constructor counts;
negative tests don't pin the error text because ledger versions
reword it.
-}
isRejected :: SubmitResult -> Bool
isRejected (Rejected _) = True
isRejected _ = False
