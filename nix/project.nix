{ pkgs, groth16-ffi }:
let
  project = pkgs.haskell-nix.cabalProject' {
    src = ../offchain;
    compiler-nix-name = "ghc910";
    modules = [
      {
        packages.cardano-vouchers.components.library = {
          libs = pkgs.lib.mkForce [ groth16-ffi ];
          configureFlags = [ "--extra-lib-dirs=${groth16-ffi}/lib" ];
          preBuild = ''
            export LD_LIBRARY_PATH="${groth16-ffi}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
          '';
        };
        packages.cardano-vouchers.components.tests.unit-tests = {
          libs = pkgs.lib.mkForce [ groth16-ffi ];
          configureFlags = [ "--extra-lib-dirs=${groth16-ffi}/lib" ];
          preCheck = ''
            export LD_LIBRARY_PATH="${groth16-ffi}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
          '';
        };
      }
    ];
    shell = {
      tools = {
        cabal = "latest";
        fourmolu = "latest";
        hlint = "latest";
        haskell-language-server = "latest";
      };
      buildInputs = with pkgs; [
        just
        cargo
        rustc
        rustfmt
        circom
        nodejs
        groth16-ffi
      ];
      withHoogle = false;
    };
  };
in
project
