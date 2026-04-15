pragma circom 2.1.0;

include "../node_modules/circomlib/circuits/poseidon.circom";
include "../node_modules/circomlib/circuits/bitify.circom";
include "../node_modules/circomlib/circuits/comparators.circom";
include "escalarmulany_jubjub.circom";
include "escalarmulfix_jubjub.circom";
include "jubjub_full.circom";

/// EdDSA-Poseidon signature verification on the Jubjub curve
/// (BLS12-381 scalar field).
///
/// Port of circomlib's EdDSAPoseidonVerifier with Jubjub constants.
template EdDSAJubjubVerifier() {
    signal input enabled;
    signal input Ax;
    signal input Ay;
    signal input S;
    signal input R8x;
    signal input R8y;
    signal input M;

    var i;

    // Ensure S < Subgroup Order
    var SUBGROUP_ORDER_MINUS_1 = 6554484396890773809930967563523245729705921265872317281365359162392183254198;

    component snum2bits = Num2Bits(253);
    snum2bits.in <== S;

    component compConstant = CompConstant(SUBGROUP_ORDER_MINUS_1);
    for (i = 0; i < 253; i++) {
        snum2bits.out[i] ==> compConstant.in[i];
    }
    compConstant.in[253] <== 0;
    compConstant.out * enabled === 0;

    // h = Poseidon(R8x, R8y, Ax, Ay, M)
    component hash = Poseidon(5);
    hash.inputs[0] <== R8x;
    hash.inputs[1] <== R8y;
    hash.inputs[2] <== Ax;
    hash.inputs[3] <== Ay;
    hash.inputs[4] <== M;

    // Note: circomlib's Num2Bits_strict uses 254 bits (BN128).
    // BLS12-381 scalar field needs 255 bits. Poseidon output is a valid
    // field element, so we use Num2Bits(255) without alias check.
    component h2bits = Num2Bits(255);
    h2bits.in <== hash.out;

    // Multiply A by 8 (cofactor clearing)
    component dbl1 = JubjubFullDbl();
    dbl1.x <== Ax;
    dbl1.y <== Ay;
    component dbl2 = JubjubFullDbl();
    dbl2.x <== dbl1.xout;
    dbl2.y <== dbl1.yout;
    component dbl3 = JubjubFullDbl();
    dbl3.x <== dbl2.xout;
    dbl3.y <== dbl2.yout;

    // Check A is not zero
    component isZero = IsZero();
    isZero.in <== dbl3.x;
    isZero.out * enabled === 0;

    // h * (8*A)
    component mulAny = EscalarMulAny(255);
    for (i = 0; i < 255; i++) {
        mulAny.e[i] <== h2bits.out[i];
    }
    mulAny.p[0] <== dbl3.xout;
    mulAny.p[1] <== dbl3.yout;

    // right = R8 + h*8*A
    component addRight = JubjubFullAdd();
    addRight.x1 <== R8x;
    addRight.y1 <== R8y;
    addRight.x2 <== mulAny.out[0];
    addRight.y2 <== mulAny.out[1];

    // left = S * Base8
    var BASE8[2] = [
        52363696936650001301287582521711853146588465673974699354184720335305084401224,
        12024993157431732930272824407495979791132374572895036891122288541794509830761
    ];
    component mulFix = EscalarMulFix(253, BASE8);
    for (i = 0; i < 253; i++) {
        mulFix.e[i] <== snum2bits.out[i];
    }

    // Verify: S * Base8 == R8 + h*8*A
    component eqCheckX = ForceEqualIfEnabled();
    eqCheckX.enabled <== enabled;
    eqCheckX.in[0] <== mulFix.out[0];
    eqCheckX.in[1] <== addRight.xout;

    component eqCheckY = ForceEqualIfEnabled();
    eqCheckY.enabled <== enabled;
    eqCheckY.in[0] <== mulFix.out[1];
    eqCheckY.in[1] <== addRight.yout;
}
