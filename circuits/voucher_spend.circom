pragma circom 2.1.0;

include "circomlib/circuits/comparators.circom";
include "circomlib/circuits/poseidon.circom";
include "lib/eddsa_jubjub.circom";

/// Voucher spend circuit.
///
/// Proves that a user can spend amount `d` from a voucher with hidden cap `C`,
/// updating their committed counter from S_old to S_new, without revealing
/// the cap or the running total.
///
/// Certificate authentication: the issuer signs (user_id, cap) with EdDSA
/// on the Jubjub curve. The circuit verifies the signature, binding the
/// spend to a legitimate certificate. No on-chain write needed for issuance.
///
/// User identity: user_id = Poseidon(user_secret). The user proves
/// knowledge of user_secret, binding the spend to a specific user.
///
/// Public inputs (visible on-chain):
///   - d             : spend amount
///   - commit_S_old  : Poseidon commitment to old counter
///   - commit_S_new  : Poseidon commitment to new counter
///   - user_id       : Poseidon(user_secret), matches on-chain entry
///   - issuer_Ax     : issuer's EdDSA public key (x coordinate)
///   - issuer_Ay     : issuer's EdDSA public key (y coordinate)
///   - pk_c_hi       : customer's Ed25519 public key, high half (first 16 bytes as BE int)
///   - pk_c_lo       : customer's Ed25519 public key, low half (last 16 bytes as BE int)
///
/// The customer's Ed25519 public key is pass-through inside the circuit: no
/// constraint references it. It is bound into the Groth16 proof as public
/// inputs so the on-chain validator can cross-check the redeemer-supplied
/// customer_pubkey against pk_c_hi||pk_c_lo, preventing an attacker from
/// pairing a stolen proof with a different customer's signature.
///
/// The acceptor's public key is NOT a circuit input. Binding is achieved by
/// the customer's off-chain Ed25519 signature over signed_data in the
/// redeemer, verified on-chain by the validator via Plutus's
/// VerifyEd25519Signature builtin.
///
/// Private inputs (only the user knows):
///   - S_old         : old running total of spent tokens
///   - S_new         : new running total after this spend
///   - C             : the voucher cap from the certificate
///   - r_old         : randomness for old commitment
///   - r_new         : randomness for new commitment
///   - user_secret   : user's secret (proves identity)
///   - sig_R8x       : EdDSA signature R8 point (x coordinate)
///   - sig_R8y       : EdDSA signature R8 point (y coordinate)
///   - sig_S         : EdDSA signature scalar

template VoucherSpend(nBits) {
    // --- public inputs ---
    signal input d;
    signal input commit_S_old;
    signal input commit_S_new;
    signal input user_id;
    signal input issuer_Ax;
    signal input issuer_Ay;
    signal input pk_c_hi;
    signal input pk_c_lo;

    // --- private inputs ---
    signal input S_old;
    signal input S_new;
    signal input C;
    signal input r_old;
    signal input r_new;
    signal input user_secret;
    signal input sig_R8x;
    signal input sig_R8y;
    signal input sig_S;

    // 1. User identity: user_id == Poseidon(user_secret)
    component hashUser = Poseidon(1);
    hashUser.inputs[0] <== user_secret;
    user_id === hashUser.out;

    // 2. Certificate message: M = Poseidon(user_id, C)
    component hashMsg = Poseidon(2);
    hashMsg.inputs[0] <== user_id;
    hashMsg.inputs[1] <== C;

    // 3. EdDSA signature verification (issuer signed the certificate)
    component eddsa = EdDSAJubjubVerifier();
    eddsa.enabled <== 1;
    eddsa.Ax <== issuer_Ax;
    eddsa.Ay <== issuer_Ay;
    eddsa.S <== sig_S;
    eddsa.R8x <== sig_R8x;
    eddsa.R8y <== sig_R8y;
    eddsa.M <== hashMsg.out;

    // 4. Counter increment: S_new = S_old + d
    S_new === S_old + d;

    // 5. No overspend: S_new <= C
    component rangeCheck = LessEqThan(nBits);
    rangeCheck.in[0] <== S_new;
    rangeCheck.in[1] <== C;
    rangeCheck.out === 1;

    // 6. Old commitment matches: Poseidon(S_old, r_old)
    component hashOld = Poseidon(2);
    hashOld.inputs[0] <== S_old;
    hashOld.inputs[1] <== r_old;
    commit_S_old === hashOld.out;

    // 7. New commitment matches: Poseidon(S_new, r_new)
    component hashNew = Poseidon(2);
    hashNew.inputs[0] <== S_new;
    hashNew.inputs[1] <== r_new;
    commit_S_new === hashNew.out;
}

// 32-bit range: caps up to ~4 billion tokens
component main {public [d, commit_S_old, commit_S_new, user_id, issuer_Ax, issuer_Ay, pk_c_hi, pk_c_lo]} = VoucherSpend(32);
