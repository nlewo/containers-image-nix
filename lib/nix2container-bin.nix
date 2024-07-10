{ lib, stdenv, buildGoModule }:

buildGoModule {
  pname = "nix2container";
  version = "1.0.0";
  src = lib.cleanSourceWith {
    src = ../.;
    filter = path: type:
      let
        p = baseNameOf path;
      in
        !(
          p == "flake.nix" ||
          p == "flake.lock" ||
          p == "examples" ||
          p == "tests" ||
          p == "README.md" ||
          p == "default.nix"
        );
  };
  vendorHash = "sha256-/j4ZHOwU5Xi8CE/fHha+2iZhsLd/y2ovzVhvg8HDV78=";
  ldflags = lib.optionals stdenv.isDarwin [
    "-X github.com/nlewo/nix2container/nix.useNixCaseHack=true"
  ];
}
