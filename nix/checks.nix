{ pkgs, components, groth16-ffi }:
{
  library = components.library;
  unit-tests = components.tests.unit-tests;

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
