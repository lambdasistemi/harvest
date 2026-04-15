pragma circom 2.1.0;

/// Jubjub twisted Edwards curve operations over BLS12-381 scalar field.
///
/// Curve: a*x^2 + y^2 = 1 + d*x^2*y^2  where a = -1
/// Field: q = 52435875175126190479447740508185965837690552500527637822603658699938581184513
/// d = 19257038036680949359750312669786877991949435402254120286184196891950884077233
/// Cofactor: 8
/// Subgroup order: 6554484396890773809930967563523245729705921265872317281365359162392183254199
///
/// Base8 (generator * 8, generates the prime-order subgroup):
///   x = 52363696936650001301287582521711853146588465673974699354184720335305084401224
///   y = 12024993157431732930272824407495979791132374572895036891122288541794509830761

/// Point addition on Jubjub (twisted Edwards, a = -1).
/// (x1,y1) + (x2,y2) = (x3,y3) where:
///   x3 = (x1*y2 + y1*x2) / (1 + d*x1*x2*y1*y2)
///   y3 = (y1*y2 + x1*x2) / (1 - d*x1*x2*y1*y2)
/// Note: with a = -1, y3 numerator is y1*y2 - a*x1*x2 = y1*y2 + x1*x2.
template JubjubAdd() {
    signal input x1;
    signal input y1;
    signal input x2;
    signal input y2;
    signal output xout;
    signal output yout;

    var d = 19257038036680949359750312669786877991949435402254120286184196891950884077233;

    signal x1x2;
    signal y1y2;
    signal x1y2;
    signal y1x2;

    x1x2 <== x1 * x2;
    y1y2 <== y1 * y2;
    x1y2 <== x1 * y2;
    y1x2 <== y1 * x2;

    signal dx1x2y1y2;
    dx1x2y1y2 <== d * x1x2 * y1y2;

    // x3 = (x1*y2 + y1*x2) / (1 + d*x1*x2*y1*y2)
    // Constraint: xout * (1 + dx1x2y1y2) === x1y2 + y1x2
    xout * (1 + dx1x2y1y2) === x1y2 + y1x2;

    // y3 = (y1*y2 + x1*x2) / (1 - d*x1*x2*y1*y2)
    // (a = -1, so y1*y2 - a*x1*x2 = y1*y2 + x1*x2)
    yout * (1 - dx1x2y1y2) === y1y2 + x1x2;
}

/// Point doubling on Jubjub. Same as addition with (x1,y1) = (x2,y2).
template JubjubDbl() {
    signal input x;
    signal input y;
    signal output xout;
    signal output yout;

    component add = JubjubAdd();
    add.x1 <== x;
    add.y1 <== y;
    add.x2 <== x;
    add.y2 <== y;
    xout <== add.xout;
    yout <== add.yout;
}
