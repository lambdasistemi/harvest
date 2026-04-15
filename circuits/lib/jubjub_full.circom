pragma circom 2.1.0;

/// Full Jubjub curve operations (drop-in replacement for circomlib's babyjub.circom).
///
/// Jubjub: a*x^2 + y^2 = 1 + d*x^2*y^2, a = -1
/// Field: BLS12-381 scalar field

template JubjubFullAdd() {
    signal input x1;
    signal input y1;
    signal input x2;
    signal input y2;
    signal output xout;
    signal output yout;

    signal beta;
    signal gamma;
    signal delta;
    signal tau;

    var a = 52435875175126190479447740508185965837690552500527637822603658699938581184512; // -1 mod q
    var d = 19257038036680949359750312669786877991949435402254120286184196891950884077233;

    beta <== x1*y2;
    gamma <== y1*x2;
    delta <== (-a*x1+y1)*(x2 + y2);
    tau <== beta * gamma;

    xout <-- (beta + gamma) / (1+ d*tau);
    (1+ d*tau) * xout === (beta + gamma);

    yout <-- (delta + a*beta - gamma) / (1-d*tau);
    (1-d*tau)*yout === (delta + a*beta - gamma);
}

template JubjubFullDbl() {
    signal input x;
    signal input y;
    signal output xout;
    signal output yout;
    component add = JubjubFullAdd();
    add.x1 <== x;
    add.y1 <== y;
    add.x2 <== x;
    add.y2 <== y;
    xout <== add.xout;
    yout <== add.yout;
}

template JubjubFullCheck() {
    signal input x;
    signal input y;

    var a = 52435875175126190479447740508185965837690552500527637822603658699938581184512;
    var d = 19257038036680949359750312669786877991949435402254120286184196891950884077233;

    signal x2;
    signal y2;
    x2 <== x * x;
    y2 <== y * y;

    a*x2 + y2 === 1 + d*x2*y2;
}
