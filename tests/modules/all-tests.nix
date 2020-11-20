# Copied from https://github.com/NixOS/nixpkgs/blob/master/nixos/tests/all-tests.nix

{ system, pkgs, callTest, nixosPath }:
# The return value of this function will be an attrset with arbitrary depth and
# the `anything` returned by callTest at its test leafs.
# The tests not supported by `system` will be replaced with `{}`, so that
# `passthru.tests` can contain links to those without breaking on architectures
# where said tests are unsupported.
# Example callTest that just extracts the derivation from the test:
#   callTest = t: t.test;

with pkgs.lib;

let
  discoverTests = val:
    if !isAttrs val then val
    else if hasAttr "test" val then callTest val
    else mapAttrs (n: s: discoverTests s) val;
  handleTest = path: args:
    discoverTests (import path ({ inherit system pkgs nixosPath; } // args));
  handleTestOn = systems: path: args:
    if elem system systems then handleTest path args
    else {};
in {
  vault-secrets = handleTest ./vault-secrets.nix {};
}
