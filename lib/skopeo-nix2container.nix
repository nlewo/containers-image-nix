{ lib, stdenv, skopeo, patchutils, fetchurl, nix2container-bin }:

let
  patch = fetchurl {
    url = "https://github.com/nlewo/image/commit/c2254c998433cf02af60bf0292042bd80b96a77e.patch";
    sha256 = "sha256-dKEObfZY2fdsza/kObCLhv4l2snuzAbpDi4fGmtTPUQ=";
  };
in
skopeo.overrideAttrs (old: {
  EXTRA_LDFLAGS = lib.optionalString stdenv.isDarwin "-X github.com/nlewo/nix2container/nix.useNixCaseHack=true";
  nativeBuildInputs = old.nativeBuildInputs ++ [ patchutils ];
  preBuild = ''
    mkdir -p vendor/github.com/nlewo/nix2container/
    cp -r ${nix2container-bin.src}/* vendor/github.com/nlewo/nix2container/
    cd vendor/github.com/containers/image/v5
    mkdir nix/
    touch nix/transport.go
    # The patch for alltransports.go does not apply cleanly to skopeo > 1.14,
    # filter the patch and insert the import manually here instead.
    filterdiff -x '*/alltransports.go' ${patch} | patch -p1
    sed -i '\#_ "github.com/containers/image/v5/tarball"#a _ "github.com/containers/image/v5/nix"' transports/alltransports/alltransports.go
    cd -
  '';
})
