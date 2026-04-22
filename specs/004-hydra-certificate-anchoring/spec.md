# Spec: MPFS Certificate Anchoring

**Issue**: #23 (card-based identity model + certificate anchoring)
**Status**: Design — replaces earlier Hydra-based design
**Constitution**: v7.0.0 §III-A

## Problem

Off-chain cap certificates are incompatible with coalition revocation.
A leaked Jubjub key produces unlimited forged certificates
indistinguishable from legitimate ones. All forged certificates are
spendable across the entire coalition — a money printer for the
attacker.

Certificate anchoring solves this by requiring every topup to be
recorded in a SHA-256 MPF. A revoked key cannot anchor new certificates.
Existing certificates before revocation remain valid (they were
legitimately signed); the damage window is bounded.

One topup per L1 transaction is economically prohibitive.
MPFS batching provides near-zero marginal cost per topup by collecting
intents off-chain and updating the certificate root on L1 periodically.

## Architecture

### Layers

| Layer | Transactions | State |
|-------|-------------|-------|
| **L1** | settlement, redemption, revert, shop/card registration, certificate root update | Spend trie, card trie, pending trie, certificate root (reference input) |
| **Off-chain (MPFS)** | topup intent batching | Certificate MPF (SHA-256) |

### MPFS Certificate Batching

MPFS collects topup intents from reificators, validates them, and
batches them into the certificate MPF. The same MPFS infrastructure
that handles L1 settlement contention also handles certificate batching.

**Intent format**:
```
TopupIntent
  { issuerJubjubPk :: ByteString   -- 32 bytes
  , userId         :: Integer
  , certificateId  :: ByteString   -- Poseidon(user_id, cap), 32 bytes
  , cardEd25519Pk  :: ByteString   -- 32 bytes
  , cardEd25519Sig :: ByteString   -- Ed25519 signature over the above fields
  }
```

**MPFS validation** (off-chain, before batching):
1. `cardEd25519Pk` is a registered card in the coalition datum (read from L1)
2. `issuerJubjubPk` matches the Jubjub key registered for that card's shop
3. `cardEd25519Sig` is a valid Ed25519 signature over the intent payload
4. The intent is not a duplicate (same certificate_id not already in the MPF)

**Batch processing**:
1. MPFS accumulates validated intents
2. At batch commit (configurable interval — e.g. every few seconds or N intents):
   - Chain MPF inserts: `root₀ → insert₁ → root₁ → ... → rootₙ`
   - Coalition signs: `(batchNumber, previousRoot, newRoot, entries)`
   - Return batch receipt to each reificator
3. Periodically, MPFS submits a certificate root update tx to L1

### Certificate Root on L1

The certificate root is a reference-input UTxO:

```
CertificateRootDatum
  { mpfRoot :: ByteString    -- SHA-256 MPF root (32 bytes)
  }
```

Updated by the coalition via a simple L1 transaction:
- Input: current certificate root UTxO
- Output: new certificate root UTxO with updated `mpfRoot`
- Signed by coalition

The update frequency trades L1 fees against confirmation latency.
Settlements reference whichever root is current. No gap in service.

### Coalition Batch Receipt

When a batch is committed, the coalition returns a signed receipt:

```
BatchReceipt
  { batchNumber  :: Integer
  , previousRoot :: ByteString   -- 32 bytes
  , newRoot      :: ByteString   -- 32 bytes
  , certificateId :: ByteString  -- this user's entry
  , coalitionSig :: ByteString   -- Ed25519 signature over the above
  }
```

This is the user's evidence that the coalition committed to including
their topup. If the L1 root doesn't reflect a signed batch, the user
has cryptographic proof of fraud. Enforcement is off-chain.

### Topup Flow

A topup is a reificator intent submitted to MPFS:

**Steps:**
1. Casher sets reward amount on the reificator
2. Card signs cap certificate (Jubjub EdDSA) — given to user's phone
3. Card signs topup intent (Ed25519) — submitted to MPFS
4. MPFS validates intent, includes in current batch
5. MPFS returns coalition batch receipt to reificator
6. Reificator passes receipt to user's phone

**What MPFS validates:**
- Card Ed25519 key is registered in coalition datum
- Issuer Jubjub key matches the card's shop
- Ed25519 signature on the intent is valid

**What MPFS does NOT validate:**
- It does not verify that `certificateId == Poseidon(userId, cap)`.
  Poseidon is not available off-chain in the MPFS stack. The binding
  is enforced at spend time: the ZK circuit computes `certificate_id`
  from its private inputs and exposes it as a public input. The L1
  validator checks this value against the certificate root.
- It does not verify the Jubjub signature on the cap certificate.
  That is the ZK circuit's job at spend time.

This is sufficient: a registered card signed the intent, and the
card's Jubjub key matches. If someone anchors a garbage
`certificateId`, it will never pass the ZK proof at spend time.

### Changeset Publication

After each batch (or group of batches), the coalition publishes to IPFS:

```json
{
  "batchNumber": 42,
  "previousRoot": "<hex 32 bytes>",
  "newRoot": "<hex 32 bytes>",
  "entries": [
    {
      "issuerJubjubPk": "<hex 32 bytes>",
      "userId": "<integer>",
      "certificateId": "<hex 32 bytes>",
      "cardEd25519Pk": "<hex 32 bytes>"
    }
  ]
}
```

Each entry is independently verifiable:
- `issuerJubjubPk` is a registered Jubjub key (check L1 coalition datum)
- `cardEd25519Pk` is a registered card for that shop (check L1)
- The full set of entries, applied in order to `previousRoot`, must
  produce `newRoot`

### Shop Audit

Each shop:
1. Fetches the IPFS changeset (CID is broadcast by coalition)
2. Verifies all entries match registered keys on L1
3. Verifies the MPF root transition is correct
4. Checks that entries attributed to their shop match their records
   (reificator logs)
5. If anything is wrong: raises a dispute

A single honest shop catches any forgery. The coalition cannot
fabricate entries because it lacks any shop's Jubjub private key.

### L1 Settlement Changes

The settlement validator gains one additional check:

**New check**: the redeemer includes a SHA-256 MPF membership proof
for `certificate_id` against the certificate root (reference input).
The validator verifies this proof on-chain.

```
SettlementRedeemer (extends existing)
  { ...existing fields...
  , certificateId      :: Integer     -- from circuit public inputs
  , certMpfProof       :: MpfProof   -- SHA-256 membership proof
  }
```

The validator:
1. Reads the certificate root from the reference input
2. Verifies `MPF.member(certificateId, certMpfProof, certRoot)`
3. Cross-checks that `certificateId` matches the circuit's
   `certificate_id` public input (index 8)

### Circuit Changes

Add one public input: `certificate_id` at index 8.

```
public input [8]: certificate_id = Poseidon(user_id, cap)
```

The circuit already computes `Poseidon(user_id, cap)` internally
(it verifies the issuer's Jubjub signature over this value). The
change is: expose it as a public input instead of keeping it
internal.

Total public inputs: 9 (was 8).

### Revocation Under Anchoring

When a card's Jubjub key is compromised:

1. Shop revokes the card on L1 (removes from coalition datum)
2. MPFS reads updated coalition datum — rejects intents from
   the revoked card's Ed25519 key
3. No service interruption for other cards
4. Certificates anchored before revocation remain valid and
   spendable — they were legitimately signed
5. The damage window = time between compromise and revocation

This is the fundamental improvement over unanchored certificates:
revocation actually works. Without anchoring, a leaked key produces
unlimited forged certificates forever.

## Open Design Decisions

1. **Batch receipt format**: exact signed payload, encoding, and
   verification method for the user's phone app.

2. **Certificate root update frequency**: trades L1 fees against
   confirmation latency. Options: hourly, daily, or on-demand
   after N batches.

3. **MPFS topup intent API**: REST or WebSocket? Same endpoint as
   L1 settlement intents or separate? Synchronous (wait for batch
   receipt) or async (poll/callback)?

4. **Data provider certificate tree serving**: same infrastructure
   as spend trie proofs, but the certificate MPF data must be
   published by the coalition for providers to serve.

## Non-Goals

- Multi-certificate spend circuit (separate issue)
- Native Rust prover (issue #2)
- MPFS integration for L1 contention (issue #8) — already exists
- On-chain shop counter-signing of certificate root (future hardening)
- Hydra-based topup (evaluated and rejected — adds operational
  complexity without solving the trust problem better than signed
  batch receipts)
