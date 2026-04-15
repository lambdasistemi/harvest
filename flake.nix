{
  description = "ZK voucher system for Cardano using Groth16 proofs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    aiken.url = "github:aiken-lang/aiken";
  };

  outputs = { self, nixpkgs, flake-utils, aiken }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        aikenPkg = aiken.packages.${system}.aiken or null;

        # Rust FFI: BLS12-381 point compression via blst
        groth16-ffi = pkgs.rustPlatform.buildRustPackage {
          pname = "groth16-ffi";
          version = "0.1.0";
          src = ./offchain/cbits/groth16-ffi;
          cargoLock.lockFile = ./offchain/cbits/groth16-ffi/Cargo.lock;
        };

        # Haskell: off-chain library + tests
        haskellPkgs = pkgs.haskellPackages.override {
          overrides = hself: hsuper: {
            cardano-vouchers = hself.callCabal2nix "cardano-vouchers" ./offchain {
              groth16_ffi = null;
            };
          };
        };

        cardano-vouchers-lib = haskellPkgs.cardano-vouchers.overrideAttrs (old: {
          buildInputs = (old.buildInputs or []) ++ [ groth16-ffi ];
          configureFlags = (old.configureFlags or []) ++ [
            "--extra-lib-dirs=${groth16-ffi}/lib"
          ];
        });

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

        # Lint check
        lint = pkgs.writeShellApplication {
          name = "lint";
          runtimeInputs = with pkgs; [ fourmolu hlint ];
          excludeShellChecks = [ "SC2046" "SC2086" ];
          text = ''
            cd "${./offchain}"
            fourmolu -m check $(find src test -name '*.hs')
            hlint src test
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

      in
      {
        packages = {
          default = groth16-ffi;
          inherit groth16-ffi circuit;
        };

        checks = {
          inherit groth16-ffi circuit lint aiken-check;
        };

        apps = {
          lint = {
            type = "app";
            program = pkgs.lib.getExe lint;
          };
          aiken-check = {
            type = "app";
            program = pkgs.lib.getExe aiken-check;
          };
        };

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            # Haskell
            ghc
            cabal-install
            haskell-language-server
            fourmolu
            hlint

            # Rust (for blst FFI)
            cargo
            rustc
            rustfmt
            just

            # ZK circuits (Groth16)
            circom
            nodejs

            # Aiken
          ] ++ pkgs.lib.optionals (aikenPkg != null) [ aikenPkg ]
            ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
              pkgs.darwin.apple_sdk.frameworks.Security
              pkgs.darwin.apple_sdk.frameworks.SystemConfiguration
            ];

          shellHook = ''
            echo "cardano-vouchers dev shell"
            echo "  ghc:    $(ghc --version)"
            echo "  cabal:  $(cabal --version | head -1)"
            echo "  cargo:  $(cargo --version)"
          '';
        };
      });
}
