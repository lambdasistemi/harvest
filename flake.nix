{
  description = "ZK voucher system for Cardano using Groth16 proofs";

  nixConfig = {
    extra-substituters = [ "https://cache.iog.io" ];
    extra-trusted-public-keys =
      [ "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ=" ];
  };

  inputs = {
    haskellNix.url = "github:input-output-hk/haskell.nix";
    nixpkgs.follows = "haskellNix/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    aiken.url = "github:aiken-lang/aiken";
  };

  outputs = { self, nixpkgs, flake-utils, haskellNix, aiken }:
    flake-utils.lib.eachSystem [ "x86_64-linux" ] (system:
      let
        pkgs = import nixpkgs {
          overlays = [ haskellNix.overlay ];
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
        project = import ./nix/project.nix { inherit pkgs groth16-ffi; };
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
          inherit groth16-ffi circuit aiken-check;
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
