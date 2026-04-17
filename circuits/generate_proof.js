const snarkjs = require("snarkjs");
const fs = require("fs");
const { keygen, sign, initPoseidon } = require("./lib/jubjub_eddsa.js");

async function main() {
  const zkey = "build/voucher_spend.zkey";

  // Load parameters from file or use defaults
  let S_old, d, S_new, C, r_old, r_new, user_secret;
  const paramFile = process.argv[2];
  if (paramFile) {
    const params = JSON.parse(fs.readFileSync(paramFile, "utf8"));
    d = BigInt(params.d);
    S_old = BigInt(params.S_old);
    S_new = BigInt(params.S_new);
    C = BigInt(params.C);
    r_old = BigInt(params.r_old);
    r_new = BigInt(params.r_new);
    user_secret = BigInt(params.user_secret);
  } else {
    // Default test case
    S_old = 25n;
    d = 10n;
    S_new = S_old + d;
    C = 100n;
    r_old = 12345678n;
    r_new = 87654321n;
    user_secret = 42n;
  }

  const { execSync } = require("child_process");

  // Compile Poseidon helper circuits for BLS12-381 field (individual signal names)
  for (const [name, n] of [["hash1_helper", 1], ["hash2_helper", 2], ["hash5_helper", 5]]) {
    if (!fs.existsSync(`build/${name}_js/${name}.wasm`)) {
      const signals = Array.from({length: n}, (_, i) => `    signal input v${i};`).join("\n");
      const assigns = Array.from({length: n}, (_, i) => `    h.inputs[${i}] <== v${i};`).join("\n");
      const src = `pragma circom 2.1.0;\ninclude "circomlib/circuits/poseidon.circom";\ntemplate HashN() {\n${signals}\n    signal output out;\n    component h = Poseidon(${n});\n${assigns}\n    out <== h.out;\n}\ncomponent main = HashN();\n`;
      fs.writeFileSync(`build/${name}.circom`, src);
      execSync(`circom build/${name}.circom --prime bls12381 --wasm -l node_modules -o build/`, { stdio: "pipe" });
    }
  }

  // Initialize Poseidon for EdDSA signing
  await initPoseidon(__dirname);

  // Compute Poseidon hash using the helper circuit's witness calculator
  async function poseidonHash(inputs, helperName) {
    const wasmBuf = fs.readFileSync(`build/${helperName}_js/${helperName}.wasm`);
    const wcPath = `./build/${helperName}_js/witness_calculator.js`;
    delete require.cache[require.resolve(wcPath)];
    const wc = require(wcPath);
    const calc = await wc(wasmBuf);
    const vals = {};
    for (let i = 0; i < inputs.length; i++) {
      vals[`v${i}`] = inputs[i].toString();
    }
    const witness = await calc.calculateWitness(vals, 0);
    return witness[1].toString();
  }

  // Compute user_id
  const user_id = await poseidonHash([user_secret], "hash1_helper");
  console.log("user_id:", user_id);

  // Generate issuer keypair and sign certificate
  const issuer = keygen();
  console.log("issuer_Ax:", issuer.pkx.toString().substring(0, 20) + "...");
  console.log("issuer_Ay:", issuer.pky.toString().substring(0, 20) + "...");

  // Generate acceptor keypair (pass-through public input — bound by proof, checked by validator)
  const acceptor = keygen();
  console.log("acceptor_Ax:", acceptor.pkx.toString().substring(0, 20) + "...");
  console.log("acceptor_Ay:", acceptor.pky.toString().substring(0, 20) + "...");

  // Certificate message: Poseidon(user_id, cap)
  const certMsg = BigInt(await poseidonHash([BigInt(user_id), C], "hash2_helper"));
  const sig = await sign(issuer.sk, issuer.pkx, issuer.pky, certMsg);
  console.log("sig_S:", sig.S.toString().substring(0, 20) + "...");

  // Compute commitments
  const commit_old = await poseidonHash([S_old, r_old], "hash2_helper");
  const commit_new = await poseidonHash([S_new, r_new], "hash2_helper");
  console.log("commit_S_old:", commit_old);
  console.log("commit_S_new:", commit_new);

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

  fs.writeFileSync("build/input.json", JSON.stringify(input));

  // Generate witness
  const wasmMain = fs.readFileSync("build/voucher_spend_js/voucher_spend.wasm");
  const wcMain = require("./build/voucher_spend_js/witness_calculator.js");
  const calcMain = await wcMain(wasmMain);
  const witness = await calcMain.calculateWTNSBin(input, 0);
  fs.writeFileSync("build/witness.wtns", witness);
  console.log("Witness generated");

  // Generate proof
  const { proof, publicSignals } = await snarkjs.groth16.prove(zkey, "build/witness.wtns");
  console.log("Proof generated");
  console.log("Public signals:", publicSignals);

  fs.writeFileSync("build/proof.json", JSON.stringify(proof, null, 2));
  fs.writeFileSync("build/public.json", JSON.stringify(publicSignals, null, 2));

  // Verify off-chain
  const vk = JSON.parse(fs.readFileSync("build/verification_key.json"));
  const valid = await snarkjs.groth16.verify(vk, publicSignals, proof);
  console.log("Verification:", valid ? "VALID" : "INVALID");

  process.exit(valid ? 0 : 1);
}

main().catch(e => { console.error(e); process.exit(1); });
