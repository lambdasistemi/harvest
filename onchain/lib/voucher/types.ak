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

/// Redeemer for a redemption transaction.
///
/// The reificator signs `own_ref.transaction_id || "REDEEM"` (38 bytes)
/// under the datum's `reificator_pk`, proving they authorise the
/// removal of this voucher entry.
pub type RedeemRedeemer {
  /// Ed25519 signature (64 bytes) over (txid || "REDEEM").
  reificator_sig: ByteArray,
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
