# Data Model: Voucher Spend

## Entities

### Voucher Certificate (off-chain, on user's phone)

| Field | Type | Description |
|-------|------|-------------|
| user_id | hash | Poseidon(user_secret) — public identifier |
| cap | integer | Maximum spendable amount |
| issuer_pk | public key | Issuer's EdDSA public key |
| signature | signature | Issuer's EdDSA signature over (user_id, cap) |

**Lifecycle**: Created by issuer at reward time. Superseded by new certificate with higher cap. Never published on-chain.

### Committed Spend Counter (on-chain)

| Field | Type | Description |
|-------|------|-------------|
| user_id | hash | Poseidon(user_secret) — matches certificate |
| commit_spent | hash | Poseidon(spent, randomness) — hides actual spent amount |

**Lifecycle**: Created when user first enters the system (spent=0). Updated with each spend. Monotonically increasing spent value.

### Coalition Accepted List (on-chain)

| Field | Type | Description |
|-------|------|-------------|
| issuer_vk | verification key | Groth16 verification key for this issuer |
| issuer_pk | public key | EdDSA public key used to sign certificates |

**Lifecycle**: Managed by coalition governance. Entries added when members join, removed when members leave.

### Spend Proof (transient, generated per transaction)

| Field | Type | Description |
|-------|------|-------------|
| proof | Groth16 proof | Three curve points (A, B, C) |
| public_inputs | list | [spend_amount, commit_spent_old, commit_spent_new] |

**Lifecycle**: Generated on user's phone, consumed by validator in one transaction.

## State Transitions

```
                  ┌─────────────┐
                  │  No Account  │
                  └──────┬──────┘
                         │ First certificate issued (off-chain)
                         │ + initial UTXO created (spent=0)
                         ▼
                  ┌─────────────┐
              ┌──►│   Active     │◄──┐
              │   │ commit(spent)│   │
              │   └──────┬──────┘   │
              │          │          │
              │          │ Spend    │
              │          │ (proof)  │
              │          ▼          │
              │   ┌─────────────┐   │
              │   │   Active     │   │
              └───│ commit(spent │───┘
                  │   + amount)  │
                  └─────────────┘
```

State is always Active. Each spend atomically updates the commitment. No intermediate states.

## Circuit Inputs

### Public (visible on-chain)

| Input | Type | Description |
|-------|------|-------------|
| d | integer | Spend amount |
| commit_spent_old | field element | Poseidon commitment to old spent total |
| commit_spent_new | field element | Poseidon commitment to new spent total |

### Private (known only to user's phone)

| Input | Type | Description |
|-------|------|-------------|
| spent_old | integer | Previous spent total |
| spent_new | integer | New spent total (= spent_old + d) |
| cap | integer | Voucher cap from certificate |
| r_old | field element | Randomness for old commitment |
| r_new | field element | Randomness for new commitment |
| user_secret | field element | User's secret (proves identity) |
| issuer_pk | public key | Issuer's EdDSA public key |
| signature | signature | Issuer's signature over (user_id, cap) |

### Circuit Constraints

1. `spent_new == spent_old + d` — counter arithmetic
2. `spent_new <= cap` — range check
3. `commit_spent_old == Poseidon(spent_old, r_old)` — old commitment binding
4. `commit_spent_new == Poseidon(spent_new, r_new)` — new commitment binding
5. `EdDSA.verify(issuer_pk, signature, (Poseidon(user_secret), cap))` — certificate authenticity
6. `user_id == Poseidon(user_secret)` — identity binding (user_id derived from on-chain state)
