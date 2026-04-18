{ pkgs, components, groth16-ffi, cardanoNode }:
{
  library = components.library;

  # The unit-tests derivation requires `cardano-node` on PATH because
  # DevnetSpendSpec spawns a real devnet via `withDevnet` from
  # cardano-node-clients:devnet. We wrap the checked component in a
  # shell script that prepends cardano-node to PATH before running the
  # test binary.
  unit-tests = pkgs.writeShellApplication {
    name = "unit-tests";
    runtimeInputs = [ cardanoNode ];
    text = ''
      export LD_LIBRARY_PATH="${groth16-ffi}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
      exec ${components.tests.unit-tests}/bin/unit-tests "$@"
    '';
  };

  lint = pkgs.writeShellApplication {
    name = "lint";
    runtimeInputs = with pkgs; [ fourmolu hlint ];
    excludeShellChecks = [ "SC2046" "SC2086" ];
    text = ''
      cd "${../offchain}"
      fourmolu -m check $(find src test -name '*.hs')
      hlint src test
    '';
  };
}
