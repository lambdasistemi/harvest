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
      in
      {
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
