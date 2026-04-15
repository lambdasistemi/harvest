// Jubjub EdDSA signing for BLS12-381 scalar field.
// Used to generate test signatures that the circuit can verify.

const crypto = require("crypto");

// BLS12-381 scalar field
const q = 52435875175126190479447740508185965837690552500527637822603658699938581184513n;
// Jubjub parameters
const JUBJUB_A = q - 1n; // -1 mod q
const JUBJUB_D = 19257038036680949359750312669786877991949435402254120286184196891950884077233n;
const JUBJUB_ORDER = 6554484396890773809930967563523245729705921265872317281365359162392183254199n;
// Base8 point
const BASE8_X = 52363696936650001301287582521711853146588465673974699354184720335305084401224n;
const BASE8_Y = 12024993157431732930272824407495979791132374572895036891122288541794509830761n;

function modpow(base, exp, mod) {
  let result = 1n;
  base = ((base % mod) + mod) % mod;
  while (exp > 0n) {
    if (exp & 1n) result = (result * base) % mod;
    exp >>= 1n;
    base = (base * base) % mod;
  }
  return result;
}

function modinv(a, m) {
  return modpow(a, m - 2n, m);
}

function edwardsAdd(x1, y1, x2, y2) {
  const x1x2 = (x1 * x2) % q;
  const y1y2 = (y1 * y2) % q;
  const dx1x2y1y2 = (JUBJUB_D * x1x2 % q * y1y2) % q;
  const x3num = (x1 * y2 + y1 * x2) % q;
  const x3den = (1n + dx1x2y1y2) % q;
  const y3num = (y1y2 + x1x2) % q; // a=-1: y1y2 - a*x1x2 = y1y2 + x1x2
  const y3den = (q + 1n - dx1x2y1y2) % q;
  return [
    (x3num * modinv(x3den, q)) % q,
    (y3num * modinv(y3den, q)) % q,
  ];
}

function edwardsMul(x, y, n) {
  let rx = 0n, ry = 1n; // identity
  let px = x, py = y;
  n = ((n % JUBJUB_ORDER) + JUBJUB_ORDER) % JUBJUB_ORDER;
  while (n > 0n) {
    if (n & 1n) [rx, ry] = edwardsAdd(rx, ry, px, py);
    [px, py] = edwardsAdd(px, py, px, py);
    n >>= 1n;
  }
  return [rx, ry];
}

// Poseidon hash (uses the helper circuit for BLS12-381)
let poseidonHashFn = null;

async function initPoseidon(circuitsDir) {
  const fs = require("fs");
  const helpers = {};
  for (const n of [1, 2, 3, 5]) {
    const name = `hash${n}_helper`;
    const wasmPath = `${circuitsDir}/build/${name}_js/${name}.wasm`;
    if (fs.existsSync(wasmPath)) {
      helpers[n] = { wasmPath, name };
    }
  }
  poseidonHashFn = async function(inputs) {
    const n = inputs.length;
    const h = helpers[n];
    if (!h) throw new Error(`No helper for ${n} inputs`);
    const fs = require("fs");
    const wasmBuf = fs.readFileSync(h.wasmPath);
    const wcPath = require.resolve(`${circuitsDir}/build/${h.name}_js/witness_calculator.js`);
    delete require.cache[wcPath];
    const wc = require(wcPath);
    const calc = await wc(wasmBuf);
    const vals = {};
    for (let i = 0; i < n; i++) vals[`v${i}`] = inputs[i].toString();
    const witness = await calc.calculateWitness(vals, 0);
    return BigInt(witness[1].toString());
  };
}

async function poseidonHash(inputs) {
  if (!poseidonHashFn) throw new Error("Call initPoseidon first");
  return poseidonHashFn(inputs);
}

// Generate a keypair: sk is a random scalar, pk = sk * Base8
function keygen() {
  const skBytes = crypto.randomBytes(32);
  let sk = 0n;
  for (let i = 0; i < 32; i++) sk = (sk << 8n) + BigInt(skBytes[i]);
  sk = sk % JUBJUB_ORDER;
  const [pkx, pky] = edwardsMul(BASE8_X, BASE8_Y, sk);
  return { sk, pkx, pky };
}

// Sign a message: EdDSA-Poseidon on Jubjub
// Returns { R8x, R8y, S }
async function sign(sk, pkx, pky, msg) {
  // r = Poseidon(sk, msg) mod subgroup_order
  const r_hash = await poseidonHash([sk, msg]);
  const r = r_hash % JUBJUB_ORDER;
  // R8 = r * Base8
  const [R8x, R8y] = edwardsMul(BASE8_X, BASE8_Y, r);
  // h = Poseidon(R8x, R8y, Ax, Ay, M) mod subgroup_order
  const h = (await poseidonHash([R8x, R8y, pkx, pky, msg])) % JUBJUB_ORDER;
  // S = (r + h * sk) mod subgroup_order
  const S = (r + h * sk) % JUBJUB_ORDER;
  return { R8x, R8y, S };
}

module.exports = { keygen, sign, initPoseidon, edwardsMul, BASE8_X, BASE8_Y, JUBJUB_ORDER, q };
