/// Voucher spend types for Groth16-verified private balance.

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

/// On-chain state per user.
pub type VoucherDatum {
  /// User identity: Poseidon(user_secret)
  user_id: Int,
  /// Poseidon commitment to the running spend total.
  commit_spent: Int,
}

/// Redeemer for a spend transaction.
///
/// Per-transaction binding for acceptor_pk, TxOutRef, and d is provided by
/// the customer's Ed25519 signature over `signed_data`, verified on-chain
/// with the Plutus builtin VerifyEd25519Signature.
///
/// `signed_data` canonical byte layout (106 bytes, big-endian):
///   txid        [32 bytes]   raw Cardano TxId of one consumed input
///   ix          [ 2 bytes]   u16 output index
///   acceptor_ax [32 bytes]   acceptor's EdDSA-Jubjub pk x coord
///   acceptor_ay [32 bytes]   acceptor's EdDSA-Jubjub pk y coord
///   d           [ 8 bytes]   spend amount
pub type SpendRedeemer {
  /// The public spend amount
  d: Int,
  /// New Poseidon commitment to updated counter
  commit_spent_new: Int,
  /// Issuer's EdDSA public key (x coordinate, Jubjub curve)
  issuer_ax: Int,
  /// Issuer's EdDSA public key (y coordinate, Jubjub curve)
  issuer_ay: Int,
  /// Customer's Ed25519 public key, high half (first 16 bytes as BE int).
  /// Matches the corresponding Groth16 public input so the validator can
  /// cross-check it against `customer_pubkey` below.
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
