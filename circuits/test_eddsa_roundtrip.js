// Test: sign a message with Jubjub EdDSA, verify inside the circuit.
const fs = require("fs");
const snarkjs = require("snarkjs");
const { keygen, sign, initPoseidon } = require("./lib/jubjub_eddsa.js");

async function main() {
  await initPoseidon(__dirname);

  // Generate keypair
  const { sk, pkx, pky } = keygen();
  console.log("sk:", sk.toString().substring(0, 20) + "...");
  console.log("pkx:", pkx.toString().substring(0, 20) + "...");
  console.log("pky:", pky.toString().substring(0, 20) + "...");

  // Sign a message
  const msg = 42n;
  const { R8x, R8y, S } = await sign(sk, pkx, pky, msg);
  console.log("R8x:", R8x.toString().substring(0, 20) + "...");
  console.log("R8y:", R8y.toString().substring(0, 20) + "...");
  console.log("S:", S.toString().substring(0, 20) + "...");

  // Generate witness for the EdDSA verification circuit
  const wasmBuf = fs.readFileSync("build/test_eddsa_jubjub_js/test_eddsa_jubjub.wasm");
  const wc = require("./build/test_eddsa_jubjub_js/witness_calculator.js");
  const calc = await wc(wasmBuf);

  const input = {
    enabled: "1",
    Ax: pkx.toString(),
    Ay: pky.toString(),
    S: S.toString(),
    R8x: R8x.toString(),
    R8y: R8y.toString(),
    M: msg.toString(),
  };

  try {
    const witness = await calc.calculateWitness(input, 0);
    console.log("Witness generated — EdDSA Jubjub verification PASSED inside circuit!");
  } catch (e) {
    console.error("Witness generation FAILED:", e.message);
    process.exit(1);
  }
}

main().catch(e => { console.error(e); process.exit(1); });
