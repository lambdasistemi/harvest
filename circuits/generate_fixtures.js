// Generate E2E test fixtures: proof, verification key, and CBOR-encoded VK parameter.
// Usage: node generate_fixtures.js <output-dir>
// Requires: snarkjs, circom (in PATH), proof generation artifacts in build/

const snarkjs = require("snarkjs");
const fs = require("fs");
const { keygen, sign, initPoseidon } = require("./lib/jubjub_eddsa.js");

async function main() {
  const outDir = process.argv[2] || "build/fixtures";
  fs.mkdirSync(outDir, { recursive: true });

  // Deterministic test case
  const S_old = 25n;
  const d = 10n;
  const S_new = S_old + d;
  const C = 100n;
  const r_old = 12345678n;
  const r_new = 87654321n;
  const user_secret = 42n;

  const { execSync } = require("child_process");

  // Compile Poseidon helpers if needed
  for (const [name, n] of [["hash1_helper", 1], ["hash2_helper", 2], ["hash5_helper", 5]]) {
    if (!fs.existsSync(`build/${name}_js/${name}.wasm`)) {
      const signals = Array.from({length: n}, (_, i) => `    signal input v${i};`).join("\n");
      const assigns = Array.from({length: n}, (_, i) => `    h.inputs[${i}] <== v${i};`).join("\n");
      const src = `pragma circom 2.1.0;\ninclude "circomlib/circuits/poseidon.circom";\ntemplate HashN() {\n${signals}\n    signal output out;\n    component h = Poseidon(${n});\n${assigns}\n    out <== h.out;\n}\ncomponent main = HashN();\n`;
      fs.writeFileSync(`build/${name}.circom`, src);
      execSync(`circom build/${name}.circom --prime bls12381 --wasm -l node_modules -o build/`, { stdio: "pipe" });
    }
  }

  await initPoseidon(__dirname);

  async function poseidonHash(inputs, helperName) {
    const wasmBuf = fs.readFileSync(`build/${helperName}_js/${helperName}.wasm`);
    const wcPath = `./build/${helperName}_js/witness_calculator.js`;
    delete require.cache[require.resolve(wcPath)];
    const wc = require(wcPath);
    const calc = await wc(wasmBuf);
    const vals = {};
    for (let i = 0; i < inputs.length; i++) vals[`v${i}`] = inputs[i].toString();
    const witness = await calc.calculateWitness(vals, 0);
    return witness[1].toString();
  }

  // Compute derived values
  const user_id = await poseidonHash([user_secret], "hash1_helper");
  const issuer = keygen();
  const acceptor = keygen();
  const certMsg = BigInt(await poseidonHash([BigInt(user_id), C], "hash2_helper"));
  const sig = await sign(issuer.sk, issuer.pkx, issuer.pky, certMsg);
  const commit_old = await poseidonHash([S_old, r_old], "hash2_helper");
  const commit_new = await poseidonHash([S_new, r_new], "hash2_helper");

  const input = {
    d: d.toString(),
    commit_S_old: commit_old,
    commit_S_new: commit_new,
    user_id: user_id,
    issuer_Ax: issuer.pkx.toString(),
    issuer_Ay: issuer.pky.toString(),
    acceptor_Ax: acceptor.pkx.toString(),
    acceptor_Ay: acceptor.pky.toString(),
    S_old: S_old.toString(),
    S_new: S_new.toString(),
    C: C.toString(),
    r_old: r_old.toString(),
    r_new: r_new.toString(),
    user_secret: user_secret.toString(),
    sig_R8x: sig.R8x.toString(),
    sig_R8y: sig.R8y.toString(),
    sig_S: sig.S.toString(),
  };

  // Generate witness
  const wasmMain = fs.readFileSync("build/voucher_spend_js/voucher_spend.wasm");
  const wcMain = require("./build/voucher_spend_js/witness_calculator.js");
  const calcMain = await wcMain(wasmMain);
  const witness = await calcMain.calculateWTNSBin(input, 0);
  fs.writeFileSync("build/witness.wtns", witness);

  // Generate proof
  const zkey = "build/voucher_spend.zkey";
  const { proof, publicSignals } = await snarkjs.groth16.prove(zkey, "build/witness.wtns");

  // Save fixtures
  fs.writeFileSync(`${outDir}/proof.json`, JSON.stringify(proof, null, 2));
  fs.writeFileSync(`${outDir}/public.json`, JSON.stringify(publicSignals, null, 2));
  fs.writeFileSync(`${outDir}/input.json`, JSON.stringify(input, null, 2));

  // Save verification key
  const vk = JSON.parse(fs.readFileSync("build/verification_key.json"));
  fs.writeFileSync(`${outDir}/verification_key.json`, JSON.stringify(vk, null, 2));

  // Save issuer keypair (for test reuse)
  fs.writeFileSync(`${outDir}/issuer.json`, JSON.stringify({
    sk: issuer.sk.toString(),
    pkx: issuer.pkx.toString(),
    pky: issuer.pky.toString(),
  }, null, 2));

  // Save acceptor keypair (for test reuse)
  fs.writeFileSync(`${outDir}/acceptor.json`, JSON.stringify({
    sk: acceptor.sk.toString(),
    pkx: acceptor.pkx.toString(),
    pky: acceptor.pky.toString(),
  }, null, 2));

  console.log("Fixtures generated in", outDir);
  console.log("Public signals:", publicSignals);
  console.log("user_id:", user_id);
  console.log("issuer_Ax:", issuer.pkx.toString().substring(0, 20) + "...");
  console.log("acceptor_Ax:", acceptor.pkx.toString().substring(0, 20) + "...");

  // Verify off-chain
  const valid = await snarkjs.groth16.verify(vk, publicSignals, proof);
  console.log("Verification:", valid ? "VALID" : "INVALID");
  if (!valid) process.exit(1);
}

main().catch(e => { console.error(e); process.exit(1); });
