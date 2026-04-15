# Build everything
build: build-offchain build-onchain

# Build Rust FFI
build-ffi:
    cd offchain/cbits/groth16-ffi && cargo build --release

# Build off-chain Haskell library
build-offchain: build-ffi
    cd offchain && cabal build all --extra-lib-dirs="$PWD/cbits/groth16-ffi/target/release"

# Build on-chain Aiken validators
build-onchain:
    cd onchain && aiken build

# Run all tests
test: test-offchain test-onchain

# Run off-chain tests
test-offchain: build-ffi
    cd offchain && LD_LIBRARY_PATH="$PWD/cbits/groth16-ffi/target/release${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" cabal test all --extra-lib-dirs="$PWD/cbits/groth16-ffi/target/release"

# Run on-chain tests
test-onchain:
    cd onchain && aiken check

# Format check
format-check:
    cd offchain && fourmolu -m check $(find src test -name '*.hs')
    cd onchain && aiken fmt --check

# Format fix
format:
    cd offchain && fourmolu -i $(find src test -name '*.hs')
    cd onchain && aiken fmt

# Lint
hlint:
    cd offchain && hlint src test

# Compile ZK circuit
circuit:
    cd circuits && npm install
    cd circuits && mkdir -p build
    cd circuits && circom voucher_spend.circom --prime bls12381 --r1cs --wasm --sym -l node_modules -o build/

# Run trusted setup
setup: circuit
    cd circuits && npx snarkjs powersoftau new bls12381 14 build/pot_0000.ptau
    cd circuits && npx snarkjs powersoftau contribute build/pot_0000.ptau build/pot_0001.ptau --name="dev" -e="entropy"
    cd circuits && npx snarkjs powersoftau prepare phase2 build/pot_0001.ptau build/pot_final.ptau
    cd circuits && npx snarkjs groth16 setup build/voucher_spend.r1cs build/pot_final.ptau build/voucher_spend_0000.zkey
    cd circuits && npx snarkjs zkey contribute build/voucher_spend_0000.zkey build/voucher_spend.zkey --name="dev" -e="entropy"
    cd circuits && npx snarkjs zkey export verificationkey build/voucher_spend.zkey build/verification_key.json

# Generate and verify a test proof
prove:
    cd circuits && node generate_proof.js

# CI: full check
ci: build test format-check hlint
