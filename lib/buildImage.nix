{ lib, runCommand, writeText, go, buildLayer, closureGraph, makeNixDatabase, checkedParams, nix2container-bin, selfBuildHost }:

{ name
, # Image tag, when null then the nix output hash will be used.
  tag ? null
, # An attribute set describing an image configuration as defined in
  # https://github.com/opencontainers/image-spec/blob/8b9d41f48198a7d6d0a5c1a12dc2d1f7f47fc97f/specs-go/v1/config.go#L23
  config ? { }
, # A list of layers built with the buildLayer function: if a store
  # path in deps or copyToRoot belongs to one of these layers, this
  # store path is skipped. This is pretty useful to
  # isolate store paths that are often updated from more stable
  # store paths, to speed up build and push time.
  layers ? [ ]
, # A derivation (or list of derivation) to include in the layer
  # root. The store path prefix /nix/store/hash-path is removed. The
  # store path content is then located at the image /.
  copyToRoot ? null
, # An image that is used as base image of this image.
  fromImage ? ""
, # A list of file permisssions which are set when the tar layer is
  # created: these permissions are not written to the Nix store.
  #
  # Each element of this permission list is a dict such as
  # { path = "a store path";
  #   regex = ".*";
  #   mode = "0664";
  # }
  # The mode is applied on a specific path. In this path subtree,
  # the mode is then applied on all files matching the regex.
  perms ? [ ]
, # The maximun number of layer to create. This is based on the
  # store path "popularity" as described in
  # https://grahamc.com/blog/nix-and-layered-docker-images
  # Note this is applied on the image layers and not on layers added
  # with the buildImage.layers attribute
  maxLayers ? 1
, # If set to true, the Nix database is initialized with all store
  # paths added into the image. Note this is only useful to run nix
  # commands from the image, for instance to build an image used by
  # a CI to run Nix builds.
  initializeNixDatabase ? false
, # If initializeNixDatabase is set to true, the uid/gid of /nix can be
  # controlled using nixUid/nixGid.
  nixUid ? 0
, nixGid ? 0
, # Deprecated: will be removed
  contents ? null
, meta ? { }
,
}:
let
  configFile = writeText "config.json" (builtins.toJSON config);
  copyToRootList =
    let derivations = if !isNull contents then contents else copyToRoot;
    in if isNull derivations
    then [ ]
    else if !builtins.isList derivations
    then [ derivations ]
    else derivations;

  # Expand the given list of layers to include all their transitive layer dependencies.
  layersWithNested = layers:
    let layerWithNested = layer: [ layer ] ++ (builtins.concatMap layerWithNested (layer.layers or [ ]));
    in builtins.concatMap layerWithNested layers;
  explodedLayers = layersWithNested layers;
  ignore = [ configFile ] ++ explodedLayers;

  closureGraphForAllLayers = closureGraph ([ configFile ] ++ copyToRootList ++ layers) ignore;
  nixDatabase = makeNixDatabase closureGraphForAllLayers;
  # This layer contains all config dependencies. We ignore the
  # configFile because it is already part of the image, as a
  # specific blob.

  perms' = perms ++ lib.optionals initializeNixDatabase
    [
      {
        path = nixDatabase;
        regex = ".*";
        mode = "0755";
        uid = nixUid;
        gid = nixGid;
      }
    ];

  customizationLayer = buildLayer {
    inherit maxLayers;
    perms = perms';
    copyToRoot =
      if initializeNixDatabase
      then copyToRootList ++ [ nixDatabase ]
      else copyToRootList;
    deps = [ configFile ];
    ignore = configFile;
    layers = layers;
  };
  fromImageFlag = lib.optionalString (fromImage != "") "--from-image ${fromImage}";
  layerPaths = lib.concatMapStringsSep " " (l: l + "/layers.json") (layers ++ [ customizationLayer ]);
  image =
    let
      imageName = lib.toLower name;
      imageTag =
        if tag != null
        then tag
        else
          lib.head (lib.strings.splitString "-" (baseNameOf image.outPath));
    in
    runCommand "image-${baseNameOf name}.json"
      {
        inherit imageName meta;
        nativeBuildInputs = [ nix2container-bin ];
        passthru = {
          inherit fromImage imageTag;
          # provide a cheap to evaluate image reference for use with external tools like docker
          # DO NOT use as an input to other derivations, as there is no guarantee that the image
          # reference will exist in the store.
          imageRefUnsafe = builtins.unsafeDiscardStringContext "${imageName}:${imageTag}";
          copyToDockerDaemon = selfBuildHost.copyToDockerDaemon image;
          copyToRegistry = selfBuildHost.copyToRegistry image;
          copyToPodman = selfBuildHost.copyToPodman image;
          copyTo = selfBuildHost.copyTo image;
        };
      }
      ''
        nix2container image \
        --arch ${go.GOARCH} \
        $out \
        ${fromImageFlag} \
        ${configFile} \
        ${layerPaths}
      '';
in
checkedParams { inherit copyToRoot contents; } image
