/// Voucher types for the unified voucher validator.

/// Groth16 proof: three curve points.
pub type Groth16Proof {
  /// G1 element (compressed, 48 bytes)
  a: ByteArray,
  /// G2 element (compressed, 96 bytes)
  b: ByteArray,
  /// G1 element (compressed, 48 bytes)
  c: ByteArray,
}

/// Groth16 verification key (published by supermarket).
pub type VerificationKey {
  alpha_g1: ByteArray,
  beta_g2: ByteArray,
  gamma_g2: ByteArray,
  delta_g2: ByteArray,
  /// One per public input + 1 (9 for our circuit: ic[0..8])
  ic: List<ByteArray>,
}

/// On-chain state per (user, shop, reificator).
///
/// The first two fields (`user_id`, `commit_spent`) are wire-compatible
/// with the #15 `VoucherDatum`. `shop_pk` and `reificator_pk` are
/// frozen at first settlement and preserved by every subsequent
/// settlement on this UTxO (see
/// `specs/003-devnet-full-flow/contracts/voucher-datum.md`).
pub type VoucherDatum {
  /// User identity: Poseidon(user_secret)
  user_id: Int,
  /// Poseidon commitment to the running spend total.
  commit_spent: Int,
  /// 32-byte Ed25519 pk of the shop that authorised this entry.
  shop_pk: ByteArray,
  /// 32-byte Ed25519 pk of the reificator that submitted the first
  /// settlement.
  reificator_pk: ByteArray,
}

/// Unified redeemer for the voucher validator. One validator, one
/// address — the variant tag selects the operation.
///
/// Plutus Data encoding (inline fields, no nesting):
///   Spend  → Constr 0 [d, commit_spent_new, …, proof]
///   Redeem → Constr 1 [reificator_sig]
///   Revert → Constr 2 [prior_commit_spent, shop_sig]
pub type VoucherAction {
  /// Settlement: Groth16 + Ed25519 two-layer authorisation.
  ///
  /// `signed_data` canonical byte layout (106 bytes, big-endian):
  ///   txid        [32 bytes]   raw Cardano TxId of one consumed input
  ///   ix          [ 2 bytes]   u16 output index
  ///   acceptor_ax [32 bytes]   acceptor's EdDSA-Jubjub pk x coord
  ///   acceptor_ay [32 bytes]   acceptor's EdDSA-Jubjub pk y coord
  ///   d           [ 8 bytes]   spend amount
  Spend {
    /// The public spend amount
    d: Int,
    /// New Poseidon commitment to updated counter
    commit_spent_new: Int,
    /// Issuer's EdDSA public key (x coordinate, Jubjub curve)
    issuer_ax: Int,
    /// Issuer's EdDSA public key (y coordinate, Jubjub curve)
    issuer_ay: Int,
    /// Customer's Ed25519 public key, high half (first 16 bytes as BE int).
    pk_c_hi: Int,
    /// Customer's Ed25519 public key, low half (last 16 bytes as BE int).
    pk_c_lo: Int,
    /// Customer's Ed25519 public key, 32 bytes.
    customer_pubkey: ByteArray,
    /// Customer's Ed25519 signature over `signed_data`, 64 bytes.
    customer_signature: ByteArray,
    /// Canonical 106-byte payload the customer signed (see layout above).
    signed_data: ByteArray,
    /// Groth16 proof that the spend is valid
    proof: Groth16Proof,
  }
  /// Redemption: reificator destroys the voucher entry.
  ///
  /// The reificator signs `own_ref.transaction_id || "REDEEM"` (38 bytes)
  /// under the datum's `reificator_pk`.
  Redeem {
    /// Ed25519 signature (64 bytes) over (txid || "REDEEM").
    reificator_sig: ByteArray,
  }
  /// Revert: shop master rolls back or removes an entry.
  ///
  /// The shop master signs `own_ref.transaction_id || "REVERT" ||
  /// prior_commit_spent_bytes` (70 bytes) under the datum's `shop_pk`.
  /// `prior_commit_spent_bytes` is 32 bytes big-endian zero-padded.
  Revert {
    /// Poseidon commitment to roll back to.
    prior_commit_spent: Int,
    /// Ed25519 signature (64 bytes) over (txid || "REVERT" || prior_bytes).
    shop_sig: ByteArray,
  }
}
