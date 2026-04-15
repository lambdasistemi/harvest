# Contract: Spend Proof Format

## Overview

Defines the interface between the user's phone (proof generator) and the supermarket's submission system (transaction builder).

## Proof Payload

The user's phone produces a proof payload that the supermarket uses to construct and submit a transaction.

### Fields

| Field | Format | Size | Description |
|-------|--------|------|-------------|
| proof_a | compressed G1 point | 48 bytes | First proof element |
| proof_b | compressed G2 point | 96 bytes | Second proof element |
| proof_c | compressed G1 point | 48 bytes | Third proof element |
| spend_amount | integer | variable | Public spend amount |
| commit_spent_old | field element | 32 bytes | Old commitment (must match on-chain state) |
| commit_spent_new | field element | 32 bytes | New commitment (will be written on-chain) |
| user_id | field element | 32 bytes | User identifier (to locate on-chain entry) |
| issuer_id | identifier | variable | Which issuer's voucher is being spent |

### Encoding

The proof payload is serialized as CBOR for transport between phone and supermarket system. The supermarket re-encodes it as Plutus Data for the transaction redeemer.

## Validator Redeemer

The on-chain redeemer consumed by the spend validator:

| Field | Plutus Data | Description |
|-------|------------|-------------|
| d | Integer | Spend amount |
| commit_spent_new | Integer | New Poseidon commitment |
| proof | Constructor 0 [Bytes, Bytes, Bytes] | Groth16 proof (a, b, c) |

## Validator Datum

The on-chain datum per user entry:

| Field | Plutus Data | Description |
|-------|------------|-------------|
| user_id | Integer | Poseidon(user_secret) |
| commit_spent | Integer | Current Poseidon commitment |

## Transaction Shape

A spend transaction:
- **Consumes**: one user UTXO (with current datum)
- **Produces**: one user UTXO (with updated datum)
- **Redeemer**: spend proof + amount + new commitment
- **Signed by**: supermarket (not the user)
- **Reference input**: coalition accepted list (issuer verification keys)
