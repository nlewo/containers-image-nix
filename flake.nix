{
  description = "nix2container";

  inputs.flake-utils.url = "github:numtide/flake-utils";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs";

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        nix2container = import ./. {
          inherit pkgs;
        };
        examples = import ./examples { inherit pkgs; };
      in
        rec {
          packages = {
            inherit (nix2container) nix2containerUtil skopeo-nix2container;
            inherit examples;
          };
          defaultPackage = packages.nix2containerUtil;
        });
}
