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
  /// One per public input + 1 (6 for our circuit: ic[0..5])
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
pub type SpendRedeemer {
  /// The public spend amount
  d: Int,
  /// New Poseidon commitment to updated counter
  commit_spent_new: Int,
  /// Certificate hash (published by issuer, Poseidon(user_id, cap, nonce))
  cert_hash: Int,
  /// Groth16 proof that the spend is valid
  proof: Groth16Proof,
}
