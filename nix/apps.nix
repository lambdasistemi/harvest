{ pkgs, checks }:
let
  runnable = {
    inherit (checks) unit-tests lint;
  };
in
builtins.mapAttrs
  (_: check: {
    type = "app";
    program = pkgs.lib.getExe check;
  })
  runnable
