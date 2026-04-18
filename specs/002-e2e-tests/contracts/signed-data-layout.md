# Contract: `signed_data` canonical byte layout

**Status**: Authoritative. Any disagreement between this document, the Node signer (`circuits/lib/customer_sig.js`), the Aiken validator (`onchain/validators/voucher_spend.ak`), and the Haskell parsing check (`offchain/test/SignedDataLayoutSpec.hs`) is a bug in one of the implementations — this document wins.

## Total size: 106 bytes

All multi-byte integer fields are **big-endian**, unsigned, fixed-width, with no padding between fields.

| Offset | Length (bytes) | Field | Encoding |
|--------|----------------|-------|----------|
| 0      | 32             | `txid`        | Raw 32-byte Cardano transaction id |
| 32     | 2              | `ix`          | u16 big-endian: output index |
| 34     | 32             | `acceptor_ax` | 256-bit big-endian unsigned integer, zero-padded to 32 bytes |
| 66     | 32             | `acceptor_ay` | 256-bit big-endian unsigned integer, zero-padded to 32 bytes |
| 98     | 8              | `d`           | u64 big-endian: spend amount |

## Validator parse (Aiken slice indices, `slice(start, end)` — end inclusive)

```
txid        = slice(signed_data, 0,  31)
ix_bytes    = slice(signed_data, 32, 33)
acceptor_ax = slice(signed_data, 34, 65)
acceptor_ay = slice(signed_data, 66, 97)
d_bytes     = slice(signed_data, 98, 105)
```

All integer fields are decoded with `bytearray.to_int_big_endian`.

## Signer emit (Node offsets, `Buffer.concat`)

```
signed_data = txid               // 32 bytes
            || u16be(ix)         // 2 bytes
            || int256be(acc_ax)  // 32 bytes
            || int256be(acc_ay)  // 32 bytes
            || u64be(d)          // 8 bytes
```

## Parsing check (Haskell)

The E2E parsing test in `SignedDataLayoutSpec.hs` takes the authoritative `offchain/test/fixtures/customer.json`, decodes the `signed_data_hex`, and extracts each field by the offsets above. It then asserts each extracted value equals the `txid_hex`, `ix`, and (from `proof.json`/`public.json`) the acceptor coordinates and `d` that Node claims it set. Disagreement fails the test.

## Change procedure

If the layout must change:

1. Update this document first.
2. Update `circuits/lib/customer_sig.js` to emit the new layout.
3. Update `onchain/validators/voucher_spend.ak` to parse the new layout.
4. Regenerate fixtures (`node circuits/generate_fixtures.js`).
5. Regenerate Aiken fixture module (`just gen-aiken-fixtures`).
6. Run `just ci` and confirm all tests pass.
7. Any step skipped causes the Haskell parsing-consistency test to fail on the next CI run.
