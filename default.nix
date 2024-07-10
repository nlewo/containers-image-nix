{ pkgs ? import <nixpkgs> { }, system ? pkgs.system }:
let
  lib = pkgs.lib;

  scopeFn = self: {
    nix2container-bin = self.callPackage ./lib/nix2container-bin.nix { };
    skopeo-nix2container = self.callPackage ./lib/skopeo-nix2container.nix { };

    buildImage = self.callPackage ./lib/buildImage.nix { };
    buildLayer = self.callPackage ./lib/buildLayer.nix { };
    checkedParams = self.callPackage ./lib/checkedParams.nix { };
    closureGraph = self.callPackage ./lib/closureGraph.nix { };
    copyTo = self.callPackage ./lib/copyTo.nix { };
    copyToDockerDaemon = self.callPackage ./lib/copyToDockerDaemon.nix { };
    copyToPodman = self.callPackage ./lib/copyToPodman.nix { };
    copyToRegistry = self.callPackage ./lib/copyToRegistry.nix { };
    makeNixDatabase = self.callPackage ./lib/makeNixDatabase.nix { };
    pullImage = self.callPackage ./lib/pullImage.nix { };
    pullImageFromManifest = self.callPackage ./lib/pullImageFromManifest.nix { };
    writeSkopeoApplication = self.callPackage ./lib/writeSkopeoApplication.nix { };

    inherit (otherSplices) selfBuildBuild selfBuildHost selfBuildTarget selfHostHost selfHostTarget selfTargetTarget;
  };

  otherSplices = {
    selfBuildBuild = lib.makeScope pkgs.pkgsBuildBuild.newScope scopeFn;
    selfBuildHost = lib.makeScope pkgs.pkgsBuildHost.newScope scopeFn;
    selfBuildTarget = lib.makeScope pkgs.pkgsBuildTarget.newScope scopeFn;
    selfHostHost = lib.makeScope pkgs.pkgsHostHost.newScope scopeFn;
    selfHostTarget = lib.makeScope pkgs.pkgsHostTarget.newScope scopeFn;
    selfTargetTarget = lib.optionalAttrs (pkgs.pkgsTargetTarget?newScope) (lib.makeScope pkgs.pkgsTargetTarget.newScope scopeFn);
  };

  scope = pkgs.makeScopeWithSplicing' {
    f = scopeFn;
    inherit otherSplices;
  };
in
{
  inherit (scope) nix2container-bin skopeo-nix2container;
  nix2container = { inherit (scope) buildImage buildLayer pullImage pullImageFromManifest; };
}
