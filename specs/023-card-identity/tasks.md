# Tasks: Card-Based Identity Model + Certificate Anchoring

**Plan**: [plan.md](plan.md) | **Spec**: [spec 004](../004-hydra-certificate-anchoring/spec.md)

## Phase 1: Circuit — Add certificate_id (index 8)

- [ ] **1.1** Add `certificate_id` output signal to `voucher_spend.circom`
  - Compute `certificate_id = Poseidon(user_id, cap)` (already computed internally for EdDSA verification)
  - Expose as public output mapped to index 8
  - Total public inputs becomes 9
- [ ] **1.2** Update fixture generator to include `certificate_id` in public inputs
- [ ] **1.3** Update all existing test fixtures for 9 public inputs
- [ ] **1.4** Run circuit tests — verify existing proofs still validate with the additional output

## Phase 2: On-chain — Settlement validator update

- [ ] **2.1** Add `certificate_id` and `cert_mpf_proof` fields to settlement redeemer
  - Per spec: `certificateId :: Integer, certMpfProof :: MpfProof`
- [ ] **2.2** Add certificate root reference input reading
  - Read certificate root UTxO by script address or NFT marker
- [ ] **2.3** Add MPF membership verification
  - `MPF.member(certificate_id, certMpfProof, certRoot)` using SHA-256
- [ ] **2.4** Cross-check `certificate_id` against circuit public input index 8
- [ ] **2.5** Update settlement validator tests
  - Valid settlement with certificate proof
  - Reject: certificate_id not in MPF (unanchored certificate)
  - Reject: certificate_id mismatch with circuit public input
  - Reject: wrong certificate root (stale reference input)

## Phase 3: On-chain — Certificate root update validator

- [ ] **3.1** Create `certificate_root.ak` validator
  - Input: current certificate root UTxO
  - Output: updated certificate root UTxO (new MPF root)
  - Check: signed by coalition
- [ ] **3.2** Write unit tests
  - Valid update (coalition signature)
  - Reject: unauthorized signer
  - Reject: output not at same address

## Phase 4: Off-chain — MPFS certificate batching

- [ ] **4.1** Define topup intent type and validation logic
  - `TopupIntent { issuerJubjubPk, userId, certificateId, cardEd25519Pk, cardEd25519Sig }`
  - Validate: card registered, Jubjub key matches shop, Ed25519 sig valid, no duplicate
- [ ] **4.2** Implement certificate MPF operations
  - `insertCertificate :: MpfRoot -> IssuerJubjubPk -> UserId -> CertificateId -> (MpfRoot, MpfProof)`
  - `memberCertificate :: MpfRoot -> CertificateId -> Maybe MpfProof`
  - SHA-256 MPF using existing MPF library
- [ ] **4.3** Implement batch accumulation and signing
  - Collect validated intents into batch
  - Chain MPF inserts: root₀ → insert₁ → root₁ → ... → rootₙ
  - Coalition signs `(batchNumber, previousRoot, newRoot, entries)`
  - Return `BatchReceipt` to each reificator
- [ ] **4.4** Implement MPFS topup intent endpoint
  - Synchronous: accept intent, wait for batch commit, return receipt
  - Handle: MPFS validates intent immediately, queues for next batch
- [ ] **4.5** Write tests
  - Valid intent → batch → receipt
  - Reject: unregistered card
  - Reject: Jubjub key mismatch
  - Reject: invalid Ed25519 signature
  - Reject: duplicate certificate_id
  - Multiple intents → single batch → correct root transition

## Phase 5: Off-chain — Certificate root update + IPFS changeset

- [ ] **5.1** Implement certificate root update tx builder
  - Build L1 tx: consume current cert root UTxO, produce updated one
  - Coalition signs
- [ ] **5.2** Implement IPFS changeset publisher
  - Collect entries from batch(es) since last publication
  - Format as JSON per spec (batchNumber, previousRoot, newRoot, entries)
  - Publish to IPFS, return CID
- [ ] **5.3** Implement changeset verification tool
  - Fetch changeset by CID
  - Verify all keys registered on L1
  - Replay inserts: previousRoot → newRoot
  - Per-shop entry cross-check
- [ ] **5.4** Integration test
  - Batch intents → publish changeset → verify → update L1 root

## Phase 6: Off-chain — Reificator topup integration

- [ ] **6.1** Update reificator topup flow
  - After card signs cap certificate (Jubjub): build topup intent, card signs (Ed25519), submit to MPFS
  - Wait for batch receipt
  - Pass receipt to user's phone alongside cap certificate
- [ ] **6.2** Implement intent queue for MPFS disconnections
  - Queue locally if MPFS unreachable
  - Retry on reconnect
  - Cap certificate still given to user immediately (spendable after anchoring)
- [ ] **6.3** Integration test: full topup cycle
  - Casher sets reward → card signs certificate → MPFS batching → user gets certificate + receipt
