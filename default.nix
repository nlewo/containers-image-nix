{ pkgs ? import <nixpkgs> { } }:
let
  l = pkgs.lib // builtins;

  nix2containerUtil = pkgs.buildGoModule rec {
    pname = "nix2container";
    version = "0.0.1";
    doCheck = true;
    src = l.cleanSourceWith {
      src = ./.;
      filter = path: type:
      let
        p = baseNameOf path;
      in !(
        p == "flake.nix" ||
        p == "flake.lock" ||
        p == "examples" ||
        p == "tests" ||
        p == "README.md" ||
        p == "default.nix"
      );
    };
    vendorSha256 = "sha256-fKvCnnSjiIuDNdNaTK/L3K5IvkEKWklT1b4wse366F4=";
  };

  skopeo-nix2container = pkgs.skopeo.overrideAttrs (old: {
    preBuild = let
      patch = pkgs.fetchurl {
        url = "https://github.com/Mic92/image/commit/b3cb51066518ed2c6f6c8cf0cb4ae1e84f68b5ce.patch";
        sha256 = "sha256-GkBVoXUVQbZb8/dYJAbCsUJLDAZ/ORiMg8svACAyrwk=";

      };
    in ''
      mkdir -p vendor/github.com/nlewo/nix2container/
      cp -r ${nix2containerUtil.src}/* vendor/github.com/nlewo/nix2container/
      cd vendor/github.com/containers/image/v5
      mkdir nix/
      touch nix/transport.go
      patch -p1 < ${patch}
      cd -
    '';
  });

  copyToDockerDaemon = image: pkgs.writeShellScriptBin "copy-to-docker-daemon" ''
    echo "Copy to Docker daemon image ${image.imageName}:${image.imageTag}"
    ${skopeo-nix2container}/bin/skopeo --insecure-policy copy nix:${image} docker-daemon:${image.imageName}:${image.imageTag}
    ${skopeo-nix2container}/bin/skopeo --insecure-policy inspect docker-daemon:${image.imageName}:${image.imageTag}
  '';

  copyToRegistry = image: pkgs.writeShellScriptBin "copy-to-registry" ''
    echo "Copy to Docker registry image ${image.imageName}:${image.imageTag}"
    ${skopeo-nix2container}/bin/skopeo --insecure-policy copy nix:${image} docker://${image.imageName}:${image.imageTag} $@
  '';

  copyTo = image: pkgs.writeShellScriptBin "copy-to" ''
    echo Running skopeo --insecure-policy copy nix:${image} $@
    ${skopeo-nix2container}/bin/skopeo --insecure-policy copy nix:${image} $@
  '';

  copyToPodman = image: pkgs.writeShellScriptBin "copy-to-podman" ''
    echo "Copy to podman image ${image.imageName}:${image.imageTag}"
    ${skopeo-nix2container}/bin/skopeo --insecure-policy copy nix:${image} containers-storage:${image.imageName}:${image.imageTag}
    ${skopeo-nix2container}/bin/skopeo --insecure-policy inspect containers-storage:${image.imageName}:${image.imageTag}
  '';

  # Pull an image from a registry with Skopeo and translate it to a
  # nix2container image.json file.
  # This mainly comes from nixpkgs/build-support/docker/default.nix.
  #
  # Credentials:
  # If you use the nix daemon for building, here is how you set up creds:
  # docker login URL to whatever it is
  # copy ~/.docker/config.json to /etc/nix/skopeo/auth.json
  # Make the directory and all the files readable to the nixbld group
  # sudo chmod -R g+rx /etc/nix/skopeo
  # sudo chgrp -R nixbld /etc/nix/skopeo
  # Now, bind mount the file into the nix build sandbox
  # extra-sandbox-paths = /etc/skopeo/auth.json=/etc/nix/skopeo/auth.json
  # update /etc/nix/skopeo/auth.json every time you add a new registry auth
  pullImage =
    let
      fixName = name: l.replaceStrings [ "/" ":" ] [ "-" "-" ] name;
    in
    { imageName
      # To find the digest of an image, you can use skopeo:
      # see doc/functions.xml
    , imageDigest
    , sha256
    , os ? "linux"
    , arch ? pkgs.go.GOARCH
    , tlsVerify ? true
    , name ? fixName "docker-image-${imageName}"
    }: let
      authFile = "/etc/skopeo/auth.json";
      dir = pkgs.runCommand name
      {
        inherit imageDigest;
        impureEnvVars = l.fetchers.proxyImpureEnvVars;
        outputHashMode = "recursive";
        outputHashAlgo = "sha256";
        outputHash = sha256;

        nativeBuildInputs = l.singleton pkgs.skopeo;
        SSL_CERT_FILE = "${pkgs.cacert.out}/etc/ssl/certs/ca-bundle.crt";

        sourceURL = "docker://${imageName}@${imageDigest}";
      } ''
      skopeo \
        --insecure-policy \
        --tmpdir=$TMPDIR \
        --override-os ${os} \
        --override-arch ${arch} \
        copy \
        --src-tls-verify=${l.boolToString tlsVerify} \
        $(
          if test -f "${authFile}"
          then
            echo "--authfile=${authFile} $sourceURL"
          else
            echo "$sourceURL"
          fi
        ) \
        "dir://$out" \
        | cat  # pipe through cat to force-disable progress bar
      '';
    in pkgs.runCommand "nix2container-${imageName}.json" { } ''
      ${nix2containerUtil}/bin/nix2container image-from-dir $out ${dir}
    '';

  buildLayer = {
    # A list of store paths to include in the layer.
    deps ? [],
    # A list of store paths to include in the layer root. The store
    # path prefix /nix/store/hash-path is removed. The store path
    # content is then located at the image /.
    contents ? [],
    # A store path to ignore. This is mainly useful to ignore the
    # configuration file from the container layer.
    ignore ? null,
    # A list of layers built with the buildLayer function: if a store
    # path in deps or contents belongs to one of these layers, this
    # store path is skipped. This is pretty useful to
    # isolate store paths that are often updated from more stable
    # store paths, to speed up build and push time.
    layers ? [],
    # Store the layer tar in the derivation. This is useful when the
    # layer dependencies are not bit reproducible.
    reproducible ? true,
    # A list of file permisssions which are set when the tar layer is
    # created: these permissions are not written to the Nix store.
    #
    # Each element of this permission list is a dict such as
    # { path = "a store path";
    #   regex = ".*";
    #   mode = "0664";
    # }
    # The mode is applied on a specific path. In this path subtree,
    # the mode is then applied on all files matching the regex.
    perms ? [],
    # The maximun number of layer to create. This is based on the
    # store path "popularity" as described in
    # https://grahamc.com/blog/nix-and-layered-docker-images
    maxLayers ? 1,
  }: let
    subcommand = if reproducible
              then "layers-from-reproducible-storepaths"
              else "layers-from-non-reproducible-storepaths";
    # This is to move all storepaths in the contents attribute to the
    # image root.
    rewrites = l.map (p: {
	    path = p;
	    regex = "^${p}";
	    repl = "";
    }) contents;
    rewritesFile = pkgs.writeText "rewrites.json" (l.toJSON rewrites);
    rewritesFlag = "--rewrites ${rewritesFile}";
    permsFile = pkgs.writeText "perms.json" (l.toJSON perms);
    permsFlag = l.optionalString (perms != []) "--perms ${permsFile}";
    allDeps = deps ++ contents;
    tarDirectory = l.optionalString (! reproducible) "--tar-directory $out";
  in
  pkgs.runCommand "layers.json" {} ''
    mkdir $out
    ${nix2containerUtil}/bin/nix2container ${subcommand} \
      $out/layers.json \
      ${closureGraph allDeps} \
      --max-layers ${toString maxLayers} \
      ${rewritesFlag} \
      ${permsFlag} \
      ${tarDirectory} \
      ${l.concatMapStringsSep " "  (l: l + "/layers.json") layers} \
      ${l.optionalString (ignore != null) "--ignore ${ignore}"}
    '';

  makeNixDatabase = paths: pkgs.runCommand "nix-database" {} ''
    mkdir $out
    echo "Generating the nix database..."
    export NIX_REMOTE=local?root=$out
    # A user is required by nix
    # https://github.com/NixOS/nix/blob/9348f9291e5d9e4ba3c4347ea1b235640f54fd79/src/libutil/util.cc#L478
    export USER=nobody
    ${pkgs.nix}/bin/nix-store --load-db < ${pkgs.closureInfo {rootPaths = paths;}}/registration

    mkdir -p $out/nix/var/nix/gcroots/docker/
    for i in ${l.concatStringsSep " " paths}; do
      ln -s $i $out/nix/var/nix/gcroots/docker/$(basename $i)
    done;
  '';

  # Write the references of `path' to a file.
  closureGraph = paths: pkgs.runCommand "closure-graph.json"
  {
    exportReferencesGraph.graph = paths;
    __structuredAttrs = true;
    PATH = "${pkgs.jq}/bin";
    builder = l.toFile "builder"
    ''
      . .attrs.sh
      jq .graph .attrs.json > ''${outputs[out]}
    '';
  }
  "";

  buildImage = {
    name,
    # Image tag, when null then the nix output hash will be used.
    tag ? null,
    # An attribute set describing an image configuration as defined in
    # https://github.com/opencontainers/image-spec/blob/8b9d41f48198a7d6d0a5c1a12dc2d1f7f47fc97f/specs-go/v1/config.go#L23
    config ? {},
    # A list of layers built with the buildLayer function: if a store
    # path in deps or contents belongs to one of these layers, this
    # store path is skipped. This is pretty useful to
    # isolate store paths that are often updated from more stable
    # store paths, to speed up build and push time.
    layers ? [],
    # A list of store paths to include in the layer root. The store
    # path prefix /nix/store/hash-path is removed. The store path
    # content is then located at the image /.
    contents ? [],
    # An image that is used as base image of this image.
    fromImage ? "",
    # A list of file permisssions which are set when the tar layer is
    # created: these permissions are not written to the Nix store.
    #
    # Each element of this permission list is a dict such as
    # { path = "a store path";
    #   regex = ".*";
    #   mode = "0664";
    # }
    # The mode is applied on a specific path. In this path subtree,
    # the mode is then applied on all files matching the regex.
    perms ? [],
    # The maximun number of layer to create. This is based on the
    # store path "popularity" as described in
    # https://grahamc.com/blog/nix-and-layered-docker-images
    # Note this is applied on the image layers and not on layers added
    # with the buildImage.layers attribute
    maxLayers ? 1,
    # If set to true, the Nix database is initialized with all store
    # paths added into the image. Note this is only useful to run nix
    # commands from the image, for instance to build an image used by
    # a CI to run Nix builds.
    initializeNixDatabase ? false,
  }:
    let
      configFile = pkgs.writeText "config.json" (l.toJSON config);
      nixDatabase = makeNixDatabase ([configFile] ++ contents ++ layers);
      # This layer contains all config dependencies. We ignore the
      # configFile because it is already part of the image, as a
      # specific blob.
      customizationLayer = buildLayer {
        inherit perms maxLayers;
        contents = if initializeNixDatabase
                   then contents ++ [nixDatabase]
                   else contents;
        deps = [configFile];
        ignore = configFile;
        layers = layers;
      };
      fromImageFlag = l.optionalString (fromImage != "") "--from-image ${fromImage}";
      layerPaths = l.concatMapStringsSep " " (l: l + "/layers.json") ([customizationLayer] ++ layers);
      image = pkgs.runCommand "image-${baseNameOf name}.json"
      {
        imageName = l.toLower name;
        passthru = {
          imageTag =
            if tag != null
            then tag
            else
            l.head (l.strings.splitString "-" (baseNameOf image.outPath));
          copyToDockerDaemon = copyToDockerDaemon image;
          copyToRegistry = copyToRegistry image;
          copyToPodman = copyToPodman image;
          copyTo = copyTo image;
        };
      }
      ''
        ${nix2containerUtil}/bin/nix2container image \
        $out \
        ${fromImageFlag} \
        ${configFile} \
        ${layerPaths}
      '';
    in image;
in
{
  inherit nix2containerUtil skopeo-nix2container;
  nix2container = { inherit buildImage buildLayer pullImage; };
}
