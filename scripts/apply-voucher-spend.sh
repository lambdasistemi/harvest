#!/usr/bin/env bash
# Apply both parameters (vk + coalition_hash) to the voucher_spend blueprint
# and write the applied script hex to the test fixtures directory.
#
# Prerequisites:
#   - `aiken` in PATH
#   - `encode-vk` built (nix build .#encode-vk)
#   - Fresh `aiken build` output in onchain/plutus.json
#
# Usage:
#   ./scripts/apply-voucher-spend.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
ONCHAIN="$ROOT/onchain"
FIXTURES="$ROOT/offchain/test/fixtures"

# Step 1: Build validators to refresh plutus.json
echo "Building Aiken validators..."
(cd "$ONCHAIN" && aiken build)

# Step 2: Get the coalition-metadata script hash from plutus.json
# The hash is stored directly in the blueprint.
COALITION_HASH=$(jq -r '.validators[] | select(.title == "coalition_metadata.coalition_metadata.spend") | .hash' "$ONCHAIN/plutus.json")
echo "Coalition-metadata script hash: $COALITION_HASH"

# Step 3: Encode the VK parameter
echo "Encoding VK parameter..."
VK_HEX=$(nix run .#encode-vk -- "$FIXTURES/../../../circuits/build/verification_key.json" 2>/dev/null || \
          cabal run encode-vk -- "$FIXTURES/../../../circuits/build/verification_key.json" 2>/dev/null)
echo "VK hex length: ${#VK_HEX}"

# Step 4: Encode the coalition_hash parameter as PlutusData CBOR hex.
# coalition_hash is a ByteArray, so PlutusData encoding is just CBOR bytes:
# Major type 2 (byte string), 28 bytes = 0x581c prefix.
COALITION_HASH_CBOR="581c${COALITION_HASH}"
echo "Coalition hash CBOR: $COALITION_HASH_CBOR"

# Step 5: Apply first parameter (vk) to the blueprint
# NOTE: must use -m/-v/-o format (not -v dotted.title) for in-place
# modification — aiken v1.1.21 silently fails with the dotted title
# form when the VK is large.
echo "Applying VK parameter..."
(cd "$ONCHAIN" && aiken blueprint apply -m voucher_spend -v voucher_spend "$VK_HEX" -o plutus.json)

# Step 6: Apply second parameter (coalition_hash) to the partially-applied blueprint
echo "Applying coalition_hash parameter..."
(cd "$ONCHAIN" && aiken blueprint apply -m voucher_spend -v voucher_spend "$COALITION_HASH_CBOR" -o plutus.json)

# Step 7: Extract the applied compiled code and write to fixture
APPLIED=$(jq -r '.validators[] | select(.title == "voucher_spend.voucher_spend.spend") | .compiledCode' "$ONCHAIN/plutus.json")
echo "$APPLIED" > "$FIXTURES/applied-voucher-spend.hex"
echo "Written to: $FIXTURES/applied-voucher-spend.hex"
echo "Size: $(wc -c < "$FIXTURES/applied-voucher-spend.hex") bytes"
