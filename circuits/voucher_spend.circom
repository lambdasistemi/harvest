pragma circom 2.1.0;

include "circomlib/circuits/comparators.circom";
include "circomlib/circuits/poseidon.circom";

/// Voucher spend circuit.
///
/// Proves that a user can spend amount `d` from a voucher with hidden cap `C`,
/// updating their committed counter from S_old to S_new, without revealing
/// the cap or the running total.
///
/// Certificate authentication: the issuer creates a certificate hash
///   cert_hash = Poseidon(user_id, cap, nonce)
/// and publishes cert_hash on-chain. The user proves knowledge of the
/// preimage, binding the spend to a legitimate certificate.
///
/// User identity: user_id = Poseidon(user_secret). The user proves
/// knowledge of user_secret, binding the spend to a specific user.
///
/// Public inputs (visible on-chain):
///   - d             : spend amount
///   - commit_S_old  : Poseidon commitment to old counter
///   - commit_S_new  : Poseidon commitment to new counter
///   - cert_hash     : certificate hash (published by issuer)
///   - user_id       : Poseidon(user_secret), matches on-chain entry
///
/// Private inputs (only the user knows):
///   - S_old         : old running total of spent tokens
///   - S_new         : new running total after this spend
///   - C             : the voucher cap from the certificate
///   - r_old         : randomness for old commitment
///   - r_new         : randomness for new commitment
///   - user_secret   : user's secret (proves identity)
///   - cert_nonce    : issuer's nonce for this certificate

template VoucherSpend(nBits) {
    // --- public inputs ---
    signal input d;
    signal input commit_S_old;
    signal input commit_S_new;
    signal input cert_hash;
    signal input user_id;

    // --- private inputs ---
    signal input S_old;
    signal input S_new;
    signal input C;
    signal input r_old;
    signal input r_new;
    signal input user_secret;
    signal input cert_nonce;

    // 1. User identity: user_id == Poseidon(user_secret)
    component hashUser = Poseidon(1);
    hashUser.inputs[0] <== user_secret;
    user_id === hashUser.out;

    // 2. Certificate authenticity: cert_hash == Poseidon(user_id, C, cert_nonce)
    component hashCert = Poseidon(3);
    hashCert.inputs[0] <== user_id;
    hashCert.inputs[1] <== C;
    hashCert.inputs[2] <== cert_nonce;
    cert_hash === hashCert.out;

    // 3. Counter increment: S_new = S_old + d
    S_new === S_old + d;

    // 4. No overspend: S_new <= C
    component rangeCheck = LessEqThan(nBits);
    rangeCheck.in[0] <== S_new;
    rangeCheck.in[1] <== C;
    rangeCheck.out === 1;

    // 5. Old commitment matches: Poseidon(S_old, r_old)
    component hashOld = Poseidon(2);
    hashOld.inputs[0] <== S_old;
    hashOld.inputs[1] <== r_old;
    commit_S_old === hashOld.out;

    // 6. New commitment matches: Poseidon(S_new, r_new)
    component hashNew = Poseidon(2);
    hashNew.inputs[0] <== S_new;
    hashNew.inputs[1] <== r_new;
    commit_S_new === hashNew.out;
}

// 32-bit range: caps up to ~4 billion tokens
component main {public [d, commit_S_old, commit_S_new, cert_hash, user_id]} = VoucherSpend(32);
