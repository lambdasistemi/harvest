# Contract: Per-customer voucher script UTxO datum

**Status**: Authoritative for issue #9. Supersedes the #15 voucher
datum shape. Any disagreement between this document, the Aiken
validators under `onchain/validators/`, the Haskell `ToData` in
`Harvest.Types`, and the test fixtures is a bug in one of those —
this document wins.

## Datum

```text
Constr 0
  [ Int      -- user_id         (Poseidon hash of user_secret)
  , Int      -- commit_spent    (current Poseidon commitment S_curr)
  , Bytes    -- shop_pk         (32 bytes, the shop authorising this entry)
  , Bytes    -- reificator_pk   (32 bytes, the reificator that submitted the first settlement)
  ]
```

- `user_id`, `commit_spent` inherit from the #15 `VoucherDatum`.
- `shop_pk` and `reificator_pk` are **frozen at first settlement** and
  never change over the lifetime of this UTxO. Subsequent settlements
  (same customer, same shop, same reificator) re-produce a UTxO
  with the same role-binding fields and an updated `commit_spent`.
  If the customer spends at a *different* shop, that shop creates a
  **separate** per-customer UTxO with its own binding — the two UTxOs
  coexist at the voucher address for the same `user_id`.

## Spend redeemer (`Constr 0`, settlement)

Unchanged from #15:

```text
Constr 0
  [ Int      -- d
  , Int      -- commit_spent_new
  , Int      -- issuer_ax
  , Int      -- issuer_ay
  , Int      -- pk_c_hi
  , Int      -- pk_c_lo
  , Bytes    -- customer_pubkey       (32)
  , Bytes    -- customer_signature    (64)
  , Bytes    -- signed_data           (106)
  , Groth16Proof
  ]
```

## Redeem redeemer (`Constr 1`, redemption) — NEW

```text
Constr 1
  [ Bytes    -- reificator_sig        (64 bytes)
              --   Ed25519 sig under datum.reificator_pk
              --   over (txid || "REDEEM")
  ]
```

Tag `"REDEEM"` is the literal ASCII bytes `0x52454445454D` — 6 bytes.
It is a domain separator that stops a redemption signature from being
replayed as a revert or settlement witness.

## Revert redeemer (`Constr 2`, revert) — NEW

```text
Constr 2
  [ Int      -- prior_commit_spent    (the commit value to restore)
  , Bytes    -- shop_sig              (64 bytes)
              --   Ed25519 sig under datum.shop_pk (the shop master key)
              --   over (txid || "REVERT" || prior_commit_spent_bytes)
  ]
```

`prior_commit_spent_bytes` is `prior_commit_spent` encoded as a
fixed-width 32-byte big-endian unsigned integer, zero-padded. `REVERT`
is the 6-byte ASCII tag `0x524556455254`.

## Validator checks — settlement (extends #15)

In addition to the three bindings from #15 (`d`, `acceptor_pk`,
`TxOutRef`) and the `pk_c` cross-check:

1. Exactly one reference input at the coalition-metadata address, with
   a parseable `CoalitionDatum`.
2. `datum.shop_pk ∈ CoalitionDatum.shop_pks`.
3. The reificator whose key signs the tx (found via
   `tx.extra_signatories`) is in `CoalitionDatum.reificator_pks`,
   **and** matches `datum.reificator_pk`.
4. Output at this address carries the same `user_id`, `shop_pk`,
   `reificator_pk` as the input; only `commit_spent` is updated to
   `commit_spent_new`.

## Validator checks — redemption

1. Coalition reference input present; parseable.
2. `datum.reificator_pk ∈ CoalitionDatum.reificator_pks` — a revoked
   reificator cannot redeem.
3. Exactly one `extra_signatory` equals `datum.reificator_pk`.
4. `VerifyEd25519Signature(datum.reificator_pk,
   txid || "REDEEM", redeemer.reificator_sig)` returns `True`.
5. **No output** at this script address with this `user_id` (the
   entry is being removed). This is enforced by scanning
   `tx.outputs` and rejecting if any output sits at this address
   with a `VoucherDatum` whose `user_id` equals the input's.

## Validator checks — revert

1. Coalition reference input present; parseable.
2. `datum.shop_pk ∈ CoalitionDatum.shop_pks`.
3. Exactly one `extra_signatory` equals `datum.shop_pk`.
4. `VerifyEd25519Signature(datum.shop_pk,
   txid || "REVERT" || prior_bytes, redeemer.shop_sig)`.
5. Either:
   - (full removal) no output at this address with this `user_id`, or
   - (rollback) one output at this address with same `user_id`,
     same `shop_pk`, same `reificator_pk`, and
     `commit_spent = redeemer.prior_commit_spent`.
   The validator accepts whichever branch the tx presents; it does
   not discriminate them beyond structural validity. Economic
   correctness of which branch is chosen (full removal vs rollback)
   is the shop's responsibility — they signed it.

## Negative scenarios covered by Story 4 / edge cases

- Redemption after the reificator is revoked → rejected by check 2
  of redemption.
- Revert signed by a non-shop key → rejected by check 3 of revert.
- Settlement after reificator revocation → rejected by check 3 of
  settlement.
- Redemption that also produces a replacement UTxO at the same
  address → rejected by check 5 of redemption.

## Change procedure

Same as `coalition-metadata-datum.md`: update this doc → Aiken →
Haskell → fixtures → `just ci`.
