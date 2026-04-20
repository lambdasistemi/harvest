// Generate E2E test fixtures: proof, verification key, and CBOR-encoded VK parameter.
// Usage: node generate_fixtures.js <output-dir>
// Requires: snarkjs, circom (in PATH), proof generation artifacts in build/
//
// Emits three bundles for the #9 Devnet full-flow suite:
//   * c1 / cert-1 — legacy single-settlement bundle consumed by #15
//                   (files: customer.json, input.json, proof.json, public.json).
//   * c2 / cert-c2 — a second customer with its own user_secret and Ed25519
//                    keypair, used by Story 4 to exhibit a settlement under
//                    a revoked reificator.
//                    (files: customer-c2.json, input-c2.json, proof-c2.json,
//                    public-c2.json).
//   * c1 / cert-2 — the same customer as c1 but with a fresh, higher-cap
//                   certificate (C bumped), used by Story 2 to re-settle after
//                   redemption.
//                   (files: customer-c1-cert2.json, input-c1-cert2.json,
//                   proof-c1-cert2.json, public-c1-cert2.json).
//
// Shared issuer, acceptor, and verification key apply to every bundle — they
// live once in issuer.json / acceptor.json / verification_key.json.

const snarkjs = require("snarkjs");
const fs = require("fs");
const crypto = require("crypto");
const { keygen, sign, initPoseidon } = require("./lib/jubjub_eddsa.js");
const { buildSignedData, splitPkHiLo } = require("./lib/customer_sig.js");

async function main() {
  const outDir = process.argv[2] || "build/fixtures";
  fs.mkdirSync(outDir, { recursive: true });

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

  // Shared issuer + acceptor — one coalition, one shop for the MVP.
  const issuer = keygen();
  const acceptor = keygen();

  // Generate fixtures for a single customer/cert binding. Returns the file
  // basenames written so the verifier step can check each proof.
  async function generateBundle(label, params) {
    const { user_secret, customer, C, d, S_old, S_new, r_old, r_new, basename } = params;

    const user_id = await poseidonHash([user_secret], "hash1_helper");
    const certMsg = BigInt(await poseidonHash([BigInt(user_id), C], "hash2_helper"));
    const sig = await sign(issuer.sk, issuer.pkx, issuer.pky, certMsg);
    const commit_old = await poseidonHash([S_old, r_old], "hash2_helper");
    const commit_new = await poseidonHash([S_new, r_new], "hash2_helper");

    // Deterministic dummy tx binding per bundle. Each bundle reuses the
    // canonical zero-txid to keep the fixture offline-reproducible; the
    // devnet test re-signs with the live TxOutRef at runtime.
    const txid = Buffer.from(
      "0000000000000000000000000000000000000000000000000000000000000000",
      "hex",
    );
    const ix = 0;
    const signed_data = buildSignedData({
      txid,
      ix,
      acceptor_ax: acceptor.pkx,
      acceptor_ay: acceptor.pky,
      d,
    });
    const customer_signature = crypto.sign(null, signed_data, customer.skObj);

    const input = {
      d: d.toString(),
      commit_S_old: commit_old,
      commit_S_new: commit_new,
      user_id: user_id,
      issuer_Ax: issuer.pkx.toString(),
      issuer_Ay: issuer.pky.toString(),
      pk_c_hi: customer.pk_c_hi.toString(),
      pk_c_lo: customer.pk_c_lo.toString(),
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

    const wasmMain = fs.readFileSync("build/voucher_spend_js/voucher_spend.wasm");
    const wcPath = "./build/voucher_spend_js/witness_calculator.js";
    delete require.cache[require.resolve(wcPath)];
    const wcMain = require(wcPath);
    const calcMain = await wcMain(wasmMain);
    const witnessBuf = await calcMain.calculateWTNSBin(input, 0);
    const witnessFile = `build/witness-${basename}.wtns`;
    fs.writeFileSync(witnessFile, witnessBuf);

    const zkey = "build/voucher_spend.zkey";
    const { proof, publicSignals } = await snarkjs.groth16.prove(zkey, witnessFile);

    fs.writeFileSync(`${outDir}/proof${basename}.json`, JSON.stringify(proof, null, 2));
    fs.writeFileSync(`${outDir}/public${basename}.json`, JSON.stringify(publicSignals, null, 2));
    fs.writeFileSync(`${outDir}/input${basename}.json`, JSON.stringify(input, null, 2));
    fs.writeFileSync(`${outDir}/customer${basename}.json`, JSON.stringify({
      pk_c_hex: customer.pk_c_bytes.toString("hex"),
      sk_c_hex: customer.sk_c_bytes.toString("hex"),
      pk_c_hi: customer.pk_c_hi.toString(),
      pk_c_lo: customer.pk_c_lo.toString(),
      signed_data_hex: signed_data.toString("hex"),
      customer_signature_hex: customer_signature.toString("hex"),
      txid_hex: txid.toString("hex"),
      ix,
    }, null, 2));

    console.log(`[${label}] user_id=${user_id.substring(0, 16)}… d=${d} C=${C}`);
    console.log(`[${label}] wrote ${outDir}/{proof,public,input,customer}${basename}.json`);

    return { proof, publicSignals };
  }

  // Shared helper: fresh Ed25519 customer keypair in the shape generateBundle expects.
  function freshCustomer() {
    const { publicKey: pkcObj, privateKey: skcObj } =
      crypto.generateKeyPairSync("ed25519");
    const pk_c_bytes = pkcObj.export({ type: "spki", format: "der" }).slice(-32);
    const sk_c_bytes = skcObj
      .export({ type: "pkcs8", format: "der" })
      .slice(-32);
    const { hi: pk_c_hi, lo: pk_c_lo } = splitPkHiLo(pk_c_bytes);
    return { pkObj: pkcObj, skObj: skcObj, pk_c_bytes, sk_c_bytes, pk_c_hi, pk_c_lo };
  }

  const c1 = freshCustomer();
  const c2 = freshCustomer();

  // === c1 / cert-1 — legacy single-settlement bundle (back-compat with #15) ===
  const bundle_c1_cert1 = await generateBundle("c1/cert-1", {
    user_secret: 42n,
    customer: c1,
    C: 100n,
    d: 10n,
    S_old: 25n,
    S_new: 35n,
    r_old: 12345678n,
    r_new: 87654321n,
    basename: "",
  });

  // === c2 / cert-c2 — second customer, own cert, used by Story 4 ===
  const bundle_c2 = await generateBundle("c2/cert-c2", {
    user_secret: 43n,
    customer: c2,
    C: 100n,
    d: 10n,
    S_old: 0n,
    S_new: 10n,
    r_old: 11111111n,
    r_new: 22222222n,
    basename: "-c2",
  });

  // === c1 / cert-2 — c1 re-settling after redemption with a fresh, higher cap ===
  //
  // Post-redemption state for c1: no voucher UTxO exists yet, so S_old = 0.
  // The issuer signs a new cert binding user_id_c1 to a higher cap (C=200).
  const bundle_c1_cert2 = await generateBundle("c1/cert-2", {
    user_secret: 42n,
    customer: c1,
    C: 200n,
    d: 15n,
    S_old: 0n,
    S_new: 15n,
    r_old: 33333333n,
    r_new: 44444444n,
    basename: "-c1-cert2",
  });

  // Save shared verification key
  const vk = JSON.parse(fs.readFileSync("build/verification_key.json"));
  fs.writeFileSync(`${outDir}/verification_key.json`, JSON.stringify(vk, null, 2));

  // Save issuer / acceptor keypairs (shared across all bundles)
  fs.writeFileSync(`${outDir}/issuer.json`, JSON.stringify({
    sk: issuer.sk.toString(),
    pkx: issuer.pkx.toString(),
    pky: issuer.pky.toString(),
  }, null, 2));

  fs.writeFileSync(`${outDir}/acceptor.json`, JSON.stringify({
    sk: acceptor.sk.toString(),
    pkx: acceptor.pkx.toString(),
    pky: acceptor.pky.toString(),
  }, null, 2));

  // Verify every proof off-chain as a sanity gate for fixture regeneration.
  for (const [label, bundle] of [
    ["c1/cert-1", bundle_c1_cert1],
    ["c2/cert-c2", bundle_c2],
    ["c1/cert-2", bundle_c1_cert2],
  ]) {
    const valid = await snarkjs.groth16.verify(vk, bundle.publicSignals, bundle.proof);
    console.log(`[${label}] verification: ${valid ? "VALID" : "INVALID"}`);
    if (!valid) process.exit(1);
  }

  console.log("Fixtures generated in", outDir);
}

main().catch(e => { console.error(e); process.exit(1); });
