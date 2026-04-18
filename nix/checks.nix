{ pkgs, components, groth16-ffi, cardanoNode, devnetGenesis }:
{
  library = components.library;

  # The unit-tests derivation needs:
  #   - cardano-node on PATH, so DevnetSpendSpec can spawn a devnet via
  #     withDevnet from cardano-node-clients:devnet;
  #   - the groth16-ffi shared library on LD_LIBRARY_PATH for the Groth16
  #     point-compression tests;
  #   - HARVEST_FIXTURES_DIR pointing at the authoritative fixture tree,
  #     because the test binary runs from the nix store and can't see the
  #     repo layout;
  #   - E2E_GENESIS_DIR pointing at upstream's devnet genesis (alonzo /
  #     shelley / byron JSON), which cardano-node-clients:devnet's
  #     'withDevnet' copies into a temp workdir before spawning
  #     cardano-node.
  unit-tests = pkgs.writeShellApplication {
    name = "unit-tests";
    runtimeInputs = [ cardanoNode ];
    text = ''
      export LD_LIBRARY_PATH="${groth16-ffi}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
      export HARVEST_FIXTURES_DIR="${../offchain/test/fixtures}"
      export E2E_GENESIS_DIR="${devnetGenesis}"
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
