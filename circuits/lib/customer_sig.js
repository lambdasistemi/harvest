// Helpers for building the canonical signed_data byte layout that the
// Aiken validator parses and Ed25519-verifies, plus the pk_c hi/lo split.

const SIGNED_DATA_LEN = 32 + 2 + 32 + 32 + 8; // 106 bytes

function int256BE(n) {
  const buf = Buffer.alloc(32);
  let x = BigInt(n);
  for (let i = 31; i >= 0; i--) {
    buf[i] = Number(x & 0xffn);
    x >>= 8n;
  }
  return buf;
}

function u64BE(n) {
  const buf = Buffer.alloc(8);
  let x = BigInt(n);
  for (let i = 7; i >= 0; i--) {
    buf[i] = Number(x & 0xffn);
    x >>= 8n;
  }
  return buf;
}

function u16BE(n) {
  const buf = Buffer.alloc(2);
  buf[0] = (n >> 8) & 0xff;
  buf[1] = n & 0xff;
  return buf;
}

function buildSignedData({ txid, ix, acceptor_ax, acceptor_ay, d }) {
  if (!(txid instanceof Buffer) || txid.length !== 32) {
    throw new Error("txid must be a 32-byte Buffer");
  }
  return Buffer.concat([
    txid,
    u16BE(ix),
    int256BE(acceptor_ax),
    int256BE(acceptor_ay),
    u64BE(d),
  ]);
}

function splitPkHiLo(pkBytes) {
  if (!(pkBytes instanceof Buffer) || pkBytes.length !== 32) {
    throw new Error("pkBytes must be a 32-byte Buffer");
  }
  let hi = 0n;
  let lo = 0n;
  for (let i = 0; i < 16; i++) hi = (hi << 8n) | BigInt(pkBytes[i]);
  for (let i = 16; i < 32; i++) lo = (lo << 8n) | BigInt(pkBytes[i]);
  return { hi, lo };
}

module.exports = { buildSignedData, splitPkHiLo, SIGNED_DATA_LEN };
