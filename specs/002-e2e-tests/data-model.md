# Phase 1 Data Model: Test Fixtures & Test Harness

## Inputs (authoritative fixtures)

Already produced by the previous feature PR; this feature only consumes them.

| Path | Producer | Contents |
|------|----------|----------|
| `offchain/test/fixtures/proof.json` | snarkjs (via `node circuits/generate_fixtures.js`) | Groth16 proof in affine-coordinate integer form |
| `offchain/test/fixtures/verification_key.json` | snarkjs | Verification key for the current circuit, 9 IC points |
| `offchain/test/fixtures/public.json` | snarkjs | Public-input vector (8 integers matching the 8 circuit public inputs) |
| `offchain/test/fixtures/customer.json` | Node `crypto` (generate_fixtures.js) | Customer Ed25519 keypair + `signed_data` + signature, hex-encoded |
| `offchain/test/fixtures/applied-script.hex` | `aiken blueprint apply` | Fully-applied validator bytecode (VK baked in) |

## Derived Haskell types in the test harness

### `DevnetSpendSpec` (devnet bracket)

Uses types from `cardano-node-clients:devnet` and the main `cardano-node-clients` library:

- `DevnetHandle` — returned by `withDevnet`, carries `Submitter`, `Provider`, network magic, genesis signing key, and the working directory.
- `SignKeyDSIGN Ed25519DSIGN` — for genesis key (funding) and an ephemeral user/reificator key pair.
- `Addr` — script address of the applied `voucher_spend` validator, computed via `Harvest.Script.scriptAddr`.
- `TxIn`, `TxOut`, `MaryValue` — existing ledger types used by `spendVoucher`.
- `Redeemers`, `TxBody` — under the hood of `Evaluate.evaluateAndBalance`.

### `SpendBundle` (harness record)

A local record in `DevnetSpendSpec.hs` that collapses everything a scenario needs:

```haskell
data SpendBundle = SpendBundle
  { sbProof            :: CompressedProof
  , sbVK               :: CompressedVK
  , sbPublicInputs     :: [Integer]        -- from public.json
  , sbCustomerPubkey   :: ByteString       -- 32 bytes
  , sbCustomerSig      :: ByteString       -- 64 bytes
  , sbSignedData       :: ByteString       -- 106 bytes
  , sbTxid             :: ByteString       -- 32 bytes (from customer.json.txid_hex)
  , sbIx               :: Word16
  , sbD                :: Integer
  , sbPkCHi            :: Integer
  , sbPkCLo            :: Integer
  , sbAcceptorAx       :: Integer
  , sbAcceptorAy       :: Integer
  , sbUserId           :: Integer
  , sbIssuerAx         :: Integer
  , sbIssuerAy         :: Integer
  , sbCommitSOld       :: Integer
  , sbCommitSNew       :: Integer
  }
```

Loaded once from fixtures by a helper `loadBundle :: IO SpendBundle`. Golden test submits a tx built from `sbProof`, `sbVK` (as the applied script parameter), and all redeemer fields from the record. Negative tests call `mutateX :: SpendBundle -> SpendBundle` variants and submit the mutated bundle.

### `Ed25519Spec`

Uses `Cardano.Crypto.DSIGN.Ed25519.{Ed25519DSIGN, verifyDSIGN}` imported via cardano-node-clients' re-exports (with an upstream patch if the current public surface doesn't cover it). Loads `customer.json`, reconstructs `VerKeyDSIGN Ed25519DSIGN` from `pk_c_hex`, `SigDSIGN Ed25519DSIGN` from `customer_signature_hex`, calls `verifyDSIGN () vk signed_data sig`. Asserts it returns `Right ()`. Negative: flip one byte of `signed_data`, assert `Left ...`.

### `SignedDataLayoutSpec`

Pure-Haskell test. No external primitives. Reads `customer.json`:

```haskell
data Fixture = Fixture
  { fxTxidHex            :: Text
  , fxIx                 :: Word16
  , fxSignedDataHex      :: Text
  , fxAcceptorAx         :: Integer      -- via public.json (index 4 or 5 depending on circuit layout)
  , fxAcceptorAy         :: Integer
  , fxD                  :: Integer
  }
```

Extracts the five fields from `fxSignedDataHex` using the offsets from `contracts/signed-data-layout.md`. Asserts each equals the corresponding `fx*` reference value. No validator involvement; this is a byte-layout sanity check catching regressions in either the Node signer or the Aiken parser (or this test's own parser).

## Invariants

- `DevnetSpendSpec` golden test never mutates the fixture; it only reads. Each negative test receives a deep-copy of the bundle so mutations don't leak across scenarios.
- The applied validator script used by the devnet is the exact bytecode from `offchain/test/fixtures/applied-script.hex` — the one that would be deployed.
- Devnet handle is tied to the hspec `beforeAll`/`afterAll` lifecycle so leaked devnets don't outlive the test run.
- Tests do not shell out to external tools; `withDevnet` handles subprocess lifecycle internally.
