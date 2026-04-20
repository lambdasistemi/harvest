# Contract: Coalition-metadata UTxO datum

**Status**: Authoritative for issue #9. Any disagreement between this
document, the Aiken validator `onchain/validators/coalition_metadata.ak`,
the Haskell `ToData` instance in `offchain/src/Harvest/Types.hs`, and
the test harness in `offchain/test/HarvestFlow.hs` is a bug in one of
the implementations — this document wins.

Scope: prototype only (FR-013). Under issues #5 / #8 this shape will be
replaced by an MPF root; at that point this contract is superseded by a
new one and the refinement relation is stated there.

## Datum

```text
Constr 0
  [ List (Bytes)    -- shop_pks         (unique 32-byte Ed25519 pks)
  , List (Bytes)    -- reificator_pks   (unique 32-byte Ed25519 pks)
  , Bytes           -- issuer_pk        (32-byte Ed25519 pk)
  ]
```

**Canonical ordering**: both lists are sorted lexicographically (byte
order). Governance transitions preserve the ordering; the validator
checks `sorted(shop_pks) && sorted(reificator_pks)` and rejects
otherwise. This removes redeemer ambiguity and makes equality checks
cheap.

**Uniqueness**: both lists are sets. The validator rejects any output
datum where consecutive entries are equal.

**Immutability**: `issuer_pk` is frozen at coalition-create time. Any
governance redeemer that tries to modify it is rejected.

## Governance redeemer

Submitted against the coalition-metadata validator:

```text
Constr 0    -- AddShop
  [ Bytes   -- target shop_pk (32)
  , Bytes   -- issuer_sig (64) over (txid || 0x00 || target_pk)
  ]

Constr 1    -- AddReificator
  [ Bytes   -- target reificator_pk (32)
  , Bytes   -- issuer_sig (64) over (txid || 0x01 || target_pk)
  ]

Constr 2    -- RevokeReificator
  [ Bytes   -- target reificator_pk (32)
  , Bytes   -- issuer_sig (64) over (txid || 0x02 || target_pk)
  ]
```

`txid` is the 32-byte hash of the consuming transaction body (as
`ScriptContext` exposes it, which the validator computes via the
Plutus V3 builtins).

## Validator checks

1. Exactly one input is at this script's address (no batching).
2. Exactly one output is at this script's address.
3. The output carries an inline datum with the updated list (sorted,
   unique, `issuer_pk` preserved).
4. `VerifyEd25519Signature(issuer_pk, txid || op_tag || target_pk,
   issuer_sig)` returns `True`.
5. For `AddShop` / `AddReificator`: the target is not already in the
   list.
6. For `RevokeReificator`: the target is in the list. (Revocation of
   an absent key is a no-op and is rejected — keeps the tx narrative
   honest.)

## Settlement-side consumption (reference input)

Settlement / redemption / revert transactions reference the coalition
UTxO without consuming it (CIP-31). Each of those validators:

1. Locates the coalition UTxO in `tx.reference_inputs` by address.
2. Parses its datum under this contract.
3. Enforces the membership check specific to that transaction
   (settlement: reificator_pk ∈ reificator_pks ∧ shop_pk ∈ shop_pks;
   redemption: reificator_pk ∈ reificator_pks; revert: shop_pk ∈
   shop_pks).

If the coalition reference input is absent or malformed, every
downstream validator rejects. This is the prototype's analogue of
"MPF membership proof failed verification" — failure semantics are
identical from the submitter's perspective.

## Change procedure

Changing the datum shape requires:

1. Update this document.
2. Update the Aiken module `onchain/lib/harvest/coalition_types.ak`.
3. Update the Haskell `ToData` instance in `Harvest.Types`.
4. Update the harness constructor in `HarvestFlow.hs`.
5. Regenerate the applied scripts (`aiken blueprint apply`) and
   refresh `offchain/test/fixtures/applied-script.hex` variants.
6. Run `just ci` and confirm every spec file is green.
