{
  description = "nix2container: build container image with Nix";

  inputs.flake-utils.url = "github:numtide/flake-utils";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs";

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        nix2container = import ./. {
          inherit pkgs system;
        };
        examples = import ./examples {
          inherit pkgs;
          inherit (nix2container) nix2container;
        };
        tests = import ./tests {
          inherit pkgs examples;
          inherit (nix2container) nix2container;
        };
      in
        rec {
          packages = {
            inherit (nix2container) nix2container-bin skopeo-nix2container nix2container;
            inherit examples tests;
          };
          defaultPackage = packages.nix2container-bin;
          devShells.default = let
            pkgs = nixpkgs.legacyPackages.x86_64-linux;
          in pkgs.mkShell {
            buildInputs = [
              pkgs.go pkgs.godef pkgs.gopls
            ];
          };
        });
}
