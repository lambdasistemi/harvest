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
  [ Map (Bytes -> List (Constr 0 [Bytes, Bytes]))
                        -- cards: shop_pk -> [(jubjub_pk, ed25519_pk)]
  , Bytes               -- issuer_pk (32-byte Ed25519 pk, coalition authority)
  ]
```

Each entry in the `cards` map associates a shop's public key with a list of registered card pairs. Each card pair contains:
- `jubjub_pk` (32 bytes) — the card's Jubjub EdDSA public key (signs cap certificates, verified in ZK circuit)
- `ed25519_pk` (32 bytes) — the card's Ed25519 public key (signs transactions and reification certificates, verified by Plutus validator)

**Canonical ordering**: the outer map keys (shop_pks) are sorted lexicographically. Within each shop, card pairs are sorted by `ed25519_pk`. Governance transitions preserve ordering; the validator rejects violations.

**Uniqueness**: no duplicate `ed25519_pk` or `jubjub_pk` across the entire datum. The validator rejects any output datum with duplicates. This prevents mix-and-match attacks — each key belongs to exactly one card identity.

**Immutability**: `issuer_pk` is frozen at coalition-create time. Any governance redeemer that tries to modify it is rejected.

## Governance redeemer

Submitted against the coalition-metadata validator:

```text
Constr 0    -- AddShop
  [ Bytes   -- target shop_pk (32)
  , Bytes   -- issuer_sig (64) over (serialise(own_ref) || 0x00 || target_pk)
  ]

Constr 1    -- AddCard
  [ Bytes   -- shop_pk (32) — the shop this card belongs to
  , Bytes   -- card_jubjub_pk (32)
  , Bytes   -- card_ed25519_pk (32)
  , Bytes   -- issuer_sig (64) over (serialise(own_ref) || 0x01 || shop_pk || jubjub_pk || ed25519_pk)
  ]

Constr 2    -- RevokeCard
  [ Bytes   -- card_ed25519_pk (32) — identifies the card to revoke
  , Bytes   -- issuer_sig (64) over (serialise(own_ref) || 0x02 || card_ed25519_pk)
  ]
```

`own_ref` is the `OutputReference` of the coalition UTxO being
consumed, serialised via the Plutus V3 `serialise_data` builtin.
Signing over `own_ref` (known at tx-build time) rather than `txid`
avoids a circular dependency: `txid` depends on `script_data_hash`,
which hashes the redeemers — so a signature placed in the redeemer
cannot cover `txid`. `own_ref` is unique per UTxO and gives replay
protection for free.

## Validator checks

1. Exactly one input is at this script's address (no batching).
2. Exactly one output is at this script's address.
3. The output carries an inline datum with the updated list (sorted,
   unique, `issuer_pk` preserved).
4. `VerifyEd25519Signature(issuer_pk, serialise(own_ref) || op_tag ||
   target_pk, issuer_sig)` returns `True`, where `own_ref` is the
   `OutputReference` of the coalition input being spent.
5. For `AddShop`: the shop_pk is not already a key in the cards map.
6. For `AddCard`: the shop_pk exists in the cards map; neither
   `jubjub_pk` nor `ed25519_pk` appears anywhere in the datum.
7. For `RevokeCard`: the `card_ed25519_pk` exists under some shop.
   (Revocation of an absent card is rejected — keeps the tx narrative
   honest.)

## Settlement-side consumption (reference input)

Settlement / redemption / revert transactions reference the coalition
UTxO without consuming it (CIP-31). Each of those validators:

1. Locates the coalition UTxO in `tx.reference_inputs` by address.
2. Parses its datum under this contract.
3. Enforces the membership check specific to that transaction
   (settlement: acceptor_pk ∈ cards (any shop) ∧ tx signed by
   acceptor_pk; redemption: card_ed25519_pk ∈ cards; revert:
   shop_pk ∈ cards map keys).

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
