{ lib, runCommand, writeText, checkedParams, closureGraph, nix2container-bin }:

{
  # A list of store paths to include in the layer.
  deps ? [ ]
, # A derivation (or list of derivations) to include in the layer
  # root directory. The store path prefix /nix/store/hash-path is
  # removed. The store path content is then located at the layer /.
  copyToRoot ? null
, # A store path to ignore. This is mainly useful to ignore the
  # configuration file from the container layer.
  ignore ? null
, # A list of layers built with the buildLayer function: if a store
  # path in deps or copyToRoot belongs to one of these layers, this
  # store path is skipped. This is pretty useful to
  # isolate store paths that are often updated from more stable
  # store paths, to speed up build and push time.
  layers ? [ ]
, # Store the layer tar in the derivation. This is useful when the
  # layer dependencies are not bit reproducible.
  reproducible ? true
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
  maxLayers ? 1
, # Deprecated: will be removed on v1
  contents ? null
,
}:
let
  subcommand =
    if reproducible
    then "layers-from-reproducible-storepaths"
    else "layers-from-non-reproducible-storepaths";
  copyToRootList =
    let derivations = if !isNull contents then contents else copyToRoot;
    in if isNull derivations
    then [ ]
    else if !builtins.isList derivations
    then [ derivations ]
    else derivations;
  # This is to move all storepaths in the copyToRoot attribute to the
  # image root.
  rewrites = map
    (p: {
      path = p;
      regex = "^${p}";
      repl = "";
    })
    copyToRootList;
  rewritesFile = writeText "rewrites.json" (builtins.toJSON rewrites);
  rewritesFlag = "--rewrites ${rewritesFile}";
  permsFile = writeText "perms.json" (builtins.toJSON perms);
  permsFlag = lib.optionalString (perms != [ ]) "--perms ${permsFile}";
  allDeps = deps ++ copyToRootList;
  tarDirectory = lib.optionalString (! reproducible) "--tar-directory $out";
  layersJSON = runCommand "layers.json"
    {
      nativeBuildInputs = [ nix2container-bin ];
    } ''
    mkdir $out
    nix2container ${subcommand} \
      $out/layers.json \
      ${closureGraph allDeps ignore} \
      --max-layers ${toString maxLayers} \
      ${rewritesFlag} \
      ${permsFlag} \
      ${tarDirectory} \
      ${lib.concatMapStringsSep " "  (l: l + "/layers.json") layers} \
  '';
in
checkedParams { inherit copyToRoot contents; } layersJSON
