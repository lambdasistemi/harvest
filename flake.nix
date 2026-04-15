{
  description = "ZK voucher system for Cardano using Groth16 proofs";

  nixConfig = {
    extra-substituters = [ "https://cache.iog.io" ];
    extra-trusted-public-keys =
      [ "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ=" ];
  };

  inputs = {
    haskellNix.url = "github:input-output-hk/haskell.nix/baa6a549ce876e9c44c494a12116f178f1becbe6";
    nixpkgs.follows = "haskellNix/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    aiken.url = "github:aiken-lang/aiken";
    iohkNix = {
      url = "github:input-output-hk/iohk-nix/0ce7cc21b9a4cfde41871ef486d01a8fafbf9627";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    CHaP = {
      url = "github:intersectmbo/cardano-haskell-packages/a46182e9c039737bf43cdb5286df49bbe0edf6fb";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, flake-utils, haskellNix, aiken, iohkNix, CHaP }:
    flake-utils.lib.eachSystem [ "x86_64-linux" ] (system:
      let
        pkgs = import nixpkgs {
          overlays = [
            iohkNix.overlays.crypto
            haskellNix.overlay
            iohkNix.overlays.haskell-nix-crypto
            iohkNix.overlays.cardano-lib
          ];
          inherit system;
        };
        aikenPkg = aiken.packages.${system}.aiken or null;

        # Rust FFI: BLS12-381 point compression via blst
        groth16-ffi = pkgs.rustPlatform.buildRustPackage {
          pname = "groth16-ffi";
          version = "0.1.0";
          src = ./offchain/cbits/groth16-ffi;
          cargoLock.lockFile = ./offchain/cbits/groth16-ffi/Cargo.lock;
        };

        # Haskell project via haskell.nix
        project = import ./nix/project.nix { inherit pkgs groth16-ffi CHaP; };
        components = project.hsPkgs.cardano-vouchers.components;

        # Circuit compilation (Circom → R1CS + WASM)
        circuit = pkgs.buildNpmPackage {
          pname = "voucher-spend-circuit";
          version = "0.1.0";
          src = ./circuits;
          npmDepsHash = "sha256-v8I21zLu1cRK3U0j6Ge3MpjxvX473BCishCX+meHPTI=";
          nativeBuildInputs = [ pkgs.circom ];
          dontNpmBuild = true;
          buildPhase = ''
            mkdir -p build
            circom voucher_spend.circom --prime bls12381 --r1cs --wasm --sym -l node_modules -o build/
          '';
          installPhase = ''
            mkdir -p $out
            cp -r build/* $out/
          '';
        };

        # Circuit tests (EdDSA roundtrip + Jubjub validation)
        circuit-tests = pkgs.buildNpmPackage {
          pname = "voucher-circuit-tests";
          version = "0.1.0";
          src = ./circuits;
          npmDepsHash = "sha256-v8I21zLu1cRK3U0j6Ge3MpjxvX473BCishCX+meHPTI=";
          nativeBuildInputs = [ pkgs.circom ];
          dontNpmBuild = true;
          buildPhase = ''
            mkdir -p build

            # Compile main circuit
            circom voucher_spend.circom --prime bls12381 --r1cs --wasm --sym -l node_modules -o build/

            # Compile EdDSA test circuit
            cat > build/test_eddsa_jubjub.circom << 'CIRCOM'
            pragma circom 2.1.0;
            include "../lib/eddsa_jubjub.circom";
            template TestEdDSA() {
                signal input enabled;
                signal input Ax;
                signal input Ay;
                signal input S;
                signal input R8x;
                signal input R8y;
                signal input M;
                component v = EdDSAJubjubVerifier();
                v.enabled <== enabled;
                v.Ax <== Ax;
                v.Ay <== Ay;
                v.S <== S;
                v.R8x <== R8x;
                v.R8y <== R8y;
                v.M <== M;
            }
            component main = TestEdDSA();
            CIRCOM
            circom build/test_eddsa_jubjub.circom --prime bls12381 --r1cs --wasm -l node_modules -o build/

            # Compile Poseidon helper circuits
            for n in 1 2 3 5; do
              name="hash''${n}_helper"
              signals=""
              assigns=""
              for i in $(seq 0 $((n-1))); do
                signals="$signals    signal input v$i;"$'\n'
                assigns="$assigns    h.inputs[$i] <== v$i;"$'\n'
              done
              cat > "build/$name.circom" << EOF
            pragma circom 2.1.0;
            include "circomlib/circuits/poseidon.circom";
            template HashN() {
            $signals    signal output out;
                component h = Poseidon($n);
            $assigns    out <== h.out;
            }
            component main = HashN();
            EOF
              circom "build/$name.circom" --prime bls12381 --wasm -l node_modules -o build/
            done

            # Run tests
            node test_eddsa_roundtrip.js
            node test_jubjub_validation.js
          '';
          installPhase = ''
            mkdir -p $out
            echo "All circuit tests passed" > $out/result.txt
          '';
        };

        # Aiken check
        aiken-check = pkgs.writeShellApplication {
          name = "aiken-check";
          runtimeInputs = pkgs.lib.optionals (aikenPkg != null) [ aikenPkg ];
          text = ''
            cd "${./onchain}"
            aiken build
            aiken check --skip-tests
          '';
        };

        # Haskell checks
        hsChecks = import ./nix/checks.nix {
          inherit pkgs components groth16-ffi;
        };

      in
      {
        packages = {
          default = groth16-ffi;
          inherit groth16-ffi circuit;
        };

        checks = hsChecks // {
          inherit groth16-ffi circuit circuit-tests aiken-check;
        };

        apps = import ./nix/apps.nix {
          inherit pkgs;
          checks = hsChecks;
        };

        devShells.default = project.shell // {
          buildInputs = (project.shell.buildInputs or [])
            ++ pkgs.lib.optionals (aikenPkg != null) [ aikenPkg ];
        };
      });
}
