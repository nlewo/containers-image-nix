{ pkgs ? import <nixpkgs> { }, system }:
let
  l = pkgs.lib // builtins;

  nix2container-bin = { stdenv, buildGoModule }: buildGoModule {
    pname = "nix2container";
    version = "1.0.0";
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
    vendorHash = "sha256-/j4ZHOwU5Xi8CE/fHha+2iZhsLd/y2ovzVhvg8HDV78=";
    ldflags = l.optionals stdenv.isDarwin [
      "-X github.com/nlewo/nix2container/nix.useNixCaseHack=true"
    ];
  };

  skopeo-nix2container = { stdenv, skopeo, fetchpatch2, patchutils, nix2container-bin }: skopeo.overrideAttrs (old: {
    EXTRA_LDFLAGS = l.optionalString stdenv.isDarwin "-X github.com/nlewo/nix2container/nix.useNixCaseHack=true";
    nativeBuildInputs = old.nativeBuildInputs ++ [ patchutils ];
    preBuild = let
      # Needs to use fetchpatch2 to handle "git extended headers", which include
      # lines with semantic content like "rename from" and "rename to".
      # However, it also includes "index" lines which include the git revision(s) the patch was initially created from.
      # These lines may include revisions of differing length, based on how Github generates them.
      # fetchpatch2 does not filter out, but probably should    
      fetchgitpatch = args: fetchpatch2 (args // {
        postFetch = (args.postFetch or "") + ''
          sed -i \
            -e '/^index /d' \
            -e '/^similarity index /d' \
            -e '/^dissimilarity index /d' \
            $out
        '';
      });
      patch = fetchgitpatch {
        url = "https://github.com/nlewo/image/commit/c2254c998433cf02af60bf0292042bd80b96a77e.patch";
        sha256 = "sha256-6CUjz46xD3ORgwrHwdIlSu6JUj7WLS6BOSyRGNnALHY=";
      };
    in ''
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
  });

  writeSkopeoApplication = { writeShellApplication, jq, skopeo-nix2container }: name: text: writeShellApplication {
    inherit name text;
    runtimeInputs = [ jq skopeo-nix2container ];
    excludeShellChecks = [ "SC2068" ];
  };

  copyToDockerDaemon = { writeSkopeoApplication }: image: writeSkopeoApplication "copy-to-docker-daemon" ''
    echo "Copy to Docker daemon image ${image.imageName}:${image.imageTag}"
    skopeo --insecure-policy copy nix:${image} docker-daemon:${image.imageName}:${image.imageTag} $@
  '';

  copyToRegistry = { writeSkopeoApplication }: image: writeSkopeoApplication "copy-to-registry" ''
    echo "Copy to Docker registry image ${image.imageName}:${image.imageTag}"
    skopeo --insecure-policy copy nix:${image} docker://${image.imageName}:${image.imageTag} $@
  '';

  copyTo = { writeSkopeoApplication }: image: writeSkopeoApplication "copy-to" ''
    echo Running skopeo --insecure-policy copy nix:${image} $@
    skopeo --insecure-policy copy nix:${image} $@
  '';

  copyToPodman = { writeSkopeoApplication }: image: writeSkopeoApplication "copy-to-podman" ''
    echo "Copy to podman image ${image.imageName}:${image.imageTag}"
    skopeo --insecure-policy copy nix:${image} containers-storage:${image.imageName}:${image.imageTag}
    skopeo --insecure-policy inspect containers-storage:${image.imageName}:${image.imageTag}
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
  pullImage = { runCommand, go, skopeo, cacert, nix2container-bin }:
    let
      fixName = name: l.replaceStrings [ "/" ":" ] [ "-" "-" ] name;
    in
    { imageName
      # To find the digest of an image, you can use skopeo:
      # see doc/functions.xml
    , imageDigest
    , sha256
    , os ? "linux"
    , arch ? go.GOARCH
    , tlsVerify ? true
    , name ? fixName "docker-image-${imageName}"
    }: let
      authFile = "/etc/skopeo/auth.json";
      dir = runCommand name
      {
        inherit imageDigest;
        impureEnvVars = l.fetchers.proxyImpureEnvVars;
        outputHashMode = "recursive";
        outputHashAlgo = "sha256";
        outputHash = sha256;

        nativeBuildInputs = l.singleton skopeo;
        SSL_CERT_FILE = "${cacert.out}/etc/ssl/certs/ca-bundle.crt";

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
    in runCommand "nix2container-${imageName}.json"
      { nativeBuildInputs = [ nix2container-bin ]; }
      "nix2container image-from-dir $out ${dir}";

  pullImageFromManifest = { runCommand, writeText, go, cacert, curl, jq, nix2container-bin, selfBuildHost }: 
    { imageName
    , imageManifest ? null
    # The manifest dictates what is pulled; these three are only used for
    # the supplied manifest-pulling script.
    , imageTag ? "latest"
    , os ? "linux"
    , arch ? go.GOARCH
    , tlsVerify ? true
    , registryUrl ? "registry.hub.docker.com"
    , meta ? {}
    }: let
      manifest = l.fromJSON (l.readFile imageManifest);

      buildImageBlob = digest:
        let
          blobUrl = "https://${registryUrl}/v2/${imageName}/blobs/${digest}";
          plainDigest = l.replaceStrings ["sha256:"] [""] digest;
          insecureFlag = l.strings.optionalString (!tlsVerify) "--insecure";
        in runCommand plainDigest {
          nativeBuildInputs = [ curl jq ];
          outputHash = plainDigest;
          outputHashMode = "flat";
          outputHashAlgo = "sha256";
        } ''
          SSL_CERT_FILE="${cacert.out}/etc/ssl/certs/ca-bundle.crt";

          # This initial access is expected to fail as we don't have a token.
          curl --location ${insecureFlag} "${blobUrl}" --head --silent --write-out '%header{www-authenticate}' --output /dev/null > bearer.txt
          tokenUrl=$(sed -n 's/Bearer realm="\(.*\)",service="\(.*\)",scope="\(.*\)"/\1?service=\2\&scope=\3/p' bearer.txt)

          declare -a auth_args
          if [ -n "$tokenUrl" ]; then
            echo "Token URL: $tokenUrl"
            curl --location ${insecureFlag} --fail --silent "$tokenUrl" --output token.json
            token="$(jq --raw-output .token token.json)"
            auth_args=(-H "Authorization: Bearer $token")
          else
            echo "No token URL found, trying without authentication"
            auth_args=()
          fi

          echo "Blob URL: ${blobUrl}"
          curl ${insecureFlag} --fail "''${auth_args[@]}" "${blobUrl}" --location --output $out
        '';

      # Pull the blobs (archives) for all layers, as well as the one for the image's config JSON.
      layerBlobs = map (layerManifest: buildImageBlob layerManifest.digest) manifest.layers;
      configBlob = buildImageBlob manifest.config.digest;

      # Write the blob map out to a JSON file for the GO executable to consume.
      blobMap = l.listToAttrs(map (drv: { name = drv.name; value = drv; }) (layerBlobs ++ [configBlob]));
      blobMapFile = writeText "${imageName}-blobs.json" (l.toJSON blobMap);

      # Convenience scripts for manifest-updating.
      filter = ''.manifests[] | select((.platform.os=="${os}") and (.platform.architecture=="${arch}")) | .digest'';
      getManifest = selfBuildHost.writeSkopeoApplication "get-manifest" ''
        set -e
        manifest=$(skopeo inspect docker://${registryUrl}/${imageName}:${imageTag} --raw | jq)
        if echo "$manifest" | jq -e .manifests >/dev/null; then
          # Multi-arch image, pick the one that matches the supplied platform details.
          hash=$(echo "$manifest" | jq -r '${filter}')
          skopeo inspect "docker://${registryUrl}/${imageName}@$hash" --raw | jq
        else
          # Single-arch image, return the initial response.
          echo "$manifest"
        fi
      '';

    in runCommand "nix2container-${imageName}.json"
      { nativeBuildInputs = [ nix2container-bin ]; passthru = { inherit getManifest; }; }
      "nix2container image-from-manifest $out ${imageManifest} ${blobMapFile}";

  buildLayer = { runCommand, writeText, closureGraph, nix2container-bin }: {
    # A list of store paths to include in the layer.
    deps ? [],
    # A derivation (or list of derivations) to include in the layer
    # root directory. The store path prefix /nix/store/hash-path is
    # removed. The store path content is then located at the layer /.
    copyToRoot ? null,
    # A store path to ignore. This is mainly useful to ignore the
    # configuration file from the container layer.
    ignore ? null,
    # A list of layers built with the buildLayer function: if a store
    # path in deps or copyToRoot belongs to one of these layers, this
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
    # Deprecated: will be removed on v1
    contents ? null,
    # Author, comment, created_by
    metadata ? { created_by = "nix2container"; },
  }: let
    subcommand = if reproducible
              then "layers-from-reproducible-storepaths"
              else "layers-from-non-reproducible-storepaths";
    copyToRootList =
      let derivations = if !isNull contents then contents else copyToRoot;
      in if isNull derivations
         then []
         else if !builtins.isList derivations
              then [derivations]
              else derivations;
    # This is to move all storepaths in the copyToRoot attribute to the
    # image root.
    rewrites = l.map (p: {
	    path = p;
	    regex = "^${p}";
	    repl = "";
    }) copyToRootList;
    rewritesFile = writeText "rewrites.json" (l.toJSON rewrites);
    rewritesFlag = "--rewrites ${rewritesFile}";
    permsFile = writeText "perms.json" (l.toJSON perms);
    permsFlag = l.optionalString (perms != []) "--perms ${permsFile}";
    historyFile = pkgs.writeText "history.json" (l.toJSON metadata);
    historyFlag = l.optionalString (metadata != {}) "--history ${historyFile}";
    allDeps = deps ++ copyToRootList;
    tarDirectory = l.optionalString (! reproducible) "--tar-directory $out";
    layersJSON = runCommand "layers.json" { nativeBuildInputs = [ nix2container-bin ]; } ''
      mkdir $out
      nix2container ${subcommand} \
        $out/layers.json \
        ${closureGraph allDeps ignore} \
        --max-layers ${toString maxLayers} \
        ${rewritesFlag} \
        ${permsFlag} \
        ${historyFlag} \
        ${tarDirectory} \
        ${l.concatMapStringsSep " "  (l: l + "/layers.json") layers} \
      '';
  in checked { inherit copyToRoot contents; } layersJSON;

  # Create a nix database from all paths contained in the given closureGraphJson.
  # Also makes all these paths store roots to prevent them from being garbage collected.
  makeNixDatabase = { runCommand, jq, nix, sqlite }: closureGraphJson:
    assert l.isDerivation closureGraphJson;
    runCommand "nix-database" { nativeBuildInputs = [ jq nix sqlite ]; } ''
      mkdir $out
      echo "Generating the nix database from ${closureGraphJson}..."
      export NIX_REMOTE=local?root=$PWD
      # A user is required by nix
      # https://github.com/NixOS/nix/blob/9348f9291e5d9e4ba3c4347ea1b235640f54fd79/src/libutil/util.cc#L478
      export USER=nobody
      # Avoid including the closureGraph derivation itself.
      # Transformation taken from https://github.com/NixOS/nixpkgs/blob/e7f49215422317c96445e0263f21e26e0180517e/pkgs/build-support/closure-info.nix#L33
      jq -r 'map([.path, .narHash, .narSize, "", (.references | length)] + .references) | add | map("\(.)\n") | add' ${closureGraphJson} \
        | head -n -1 \
        | nix-store --load-db -j 1

      # Sanitize time stamps
      sqlite3 $PWD/nix/var/nix/db/db.sqlite \
        'UPDATE ValidPaths SET registrationTime = 0;';

      # Dump and reimport to ensure that the update order doesn't somehow change the DB.
      sqlite3 $PWD/nix/var/nix/db/db.sqlite '.dump' > db.dump
      mkdir -p $out/nix/var/nix/db/
      sqlite3 $out/nix/var/nix/db/db.sqlite '.read db.dump'
      mkdir -p $out/nix/store/.links

      mkdir -p $out/nix/var/nix/gcroots/docker/
      for i in $(jq -r 'map("\(.path)\n") | add' ${closureGraphJson}); do
        ln -s $i $out/nix/var/nix/gcroots/docker/$(basename $i)
      done;
    '';

  # Write the references of `path' to a file but do not include `ignore' itself if non-null.
  closureGraph = { runCommand, pkgsBuildHost }: paths: ignore:
    let ignoreList =
      if ignore == null
      then []
      else if !(builtins.isList ignore)
      then [ignore]
      else ignore;
    in runCommand "closure-graph.json"
    {
      exportReferencesGraph.graph = paths;
      __structuredAttrs = true;
      PATH = "${pkgsBuildHost.jq}/bin";
      ignoreListJson = builtins.toJSON (builtins.map builtins.toString ignoreList);
      outputChecks.out = {
        disallowedReferences = ignoreList;
      };
      builder = l.toFile "builder"
      ''
        . .attrs.sh
        jq --argjson ignore "$ignoreListJson" \
          '.graph|map(select(.path as $p | $ignore | index($p) | not))|map(.references|=sort_by(.))|sort_by(.path)' \
          .attrs.json \
          > ''${outputs[out]}
      '';
    }
    "";

  buildImage = { runCommand, writeText, go, buildLayer, closureGraph, makeNixDatabase, nix2container-bin, selfBuildHost }: {
    name,
    # Image tag, when null then the nix output hash will be used.
    tag ? null,
    # An attribute set describing an image configuration as defined in
    # https://github.com/opencontainers/image-spec/blob/8b9d41f48198a7d6d0a5c1a12dc2d1f7f47fc97f/specs-go/v1/config.go#L23
    config ? {},
    # A list of layers built with the buildLayer function: if a store
    # path in deps or copyToRoot belongs to one of these layers, this
    # store path is skipped. This is pretty useful to
    # isolate store paths that are often updated from more stable
    # store paths, to speed up build and push time.
    layers ? [],
    # A derivation (or list of derivation) to include in the layer
    # root. The store path prefix /nix/store/hash-path is removed. The
    # store path content is then located at the image /.
    copyToRoot ? null,
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
    # If initializeNixDatabase is set to true, the uid/gid of /nix can be
    # controlled using nixUid/nixGid.
    nixUid ? 0,
    nixGid ? 0,
    # Time of creation of the image.
    created ? "0001-01-01T00:00:00Z",
    # Deprecated: will be removed
    contents ? null,
    meta ? {},
  }:
    let
      configFile = writeText "config.json" (l.toJSON config);
      copyToRootList =
        let derivations = if !isNull contents then contents else copyToRoot;
        in if isNull derivations
           then []
           else if !builtins.isList derivations
                then [derivations]
                else derivations;

      # Expand the given list of layers to include all their transitive layer dependencies.
      layersWithNested = layers:
        let layerWithNested = layer: [layer] ++ (builtins.concatMap layerWithNested (layer.layers or []));
        in builtins.concatMap layerWithNested layers;
      explodedLayers = layersWithNested layers;
      ignore = [configFile]++explodedLayers;

      closureGraphForAllLayers = closureGraph ([configFile] ++ copyToRootList ++ layers) ignore;
      nixDatabase = makeNixDatabase closureGraphForAllLayers;
      # This layer contains all config dependencies. We ignore the
      # configFile because it is already part of the image, as a
      # specific blob.

      perms' = perms ++ l.optionals initializeNixDatabase
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
        copyToRoot = if initializeNixDatabase
                   then copyToRootList ++ [nixDatabase]
                   else copyToRootList;
        deps = [configFile];
        ignore = configFile;
        layers = layers;
      };
      fromImageFlag = l.optionalString (fromImage != "") "--from-image ${fromImage}";
      archFlag = "--arch ${go.GOARCH}";
      createdFlag = "--created ${created}";
      layerPaths = l.concatMapStringsSep " " (l: l + "/layers.json") (layers ++ [customizationLayer]);
      image = let
        imageName = l.toLower name;
        imageTag =
          if tag != null
          then tag
          else
          l.head (l.strings.splitString "-" (baseNameOf image.outPath));
      in runCommand "image-${baseNameOf name}.json"
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
        $out \
        ${fromImageFlag} \
        ${archFlag} \
        ${createdFlag} \
        ${configFile} \
        ${layerPaths}
      '';
    in checked { inherit copyToRoot contents; } image;

    checked = { copyToRoot, contents }:
      l.warnIf (contents != null)
        "The contents parameter is deprecated. Change to copyToRoot if the contents are designed to be copied to the root filesystem, such as when you use `buildEnv` or similar between contents and your packages. Use copyToRoot = buildEnv { ... }; or similar if you intend to add packages to /bin."
        l.throwIf (contents != null && copyToRoot != null)
        "You can not specify both contents and copyToRoot."
        ;

    scopeFn = self: {
      nix2container-bin = self.callPackage nix2container-bin { };
      skopeo-nix2container = self.callPackage skopeo-nix2container { };

      buildImage = self.callPackage buildImage { };
      buildLayer = self.callPackage buildLayer { };
      pullImage = self.callPackage pullImage { };
      pullImageFromManifest = self.callPackage pullImageFromManifest { };

      closureGraph = self.callPackage closureGraph { };
      copyTo = self.callPackage copyTo { };
      copyToDockerDaemon = self.callPackage copyToDockerDaemon { };
      copyToPodman = self.callPackage copyToPodman { };
      copyToRegistry = self.callPackage copyToRegistry { };
      makeNixDatabase = self.callPackage makeNixDatabase { };
      writeSkopeoApplication = self.callPackage writeSkopeoApplication { };

      inherit (otherSplices) selfBuildBuild selfBuildHost selfBuildTarget selfHostHost selfHostTarget selfTargetTarget;
    };

    otherSplices = {
      selfBuildBuild = l.makeScope pkgs.pkgsBuildBuild.newScope scopeFn;
      selfBuildHost = l.makeScope pkgs.pkgsBuildHost.newScope scopeFn;
      selfBuildTarget = l.makeScope pkgs.pkgsBuildTarget.newScope scopeFn;
      selfHostHost = l.makeScope pkgs.pkgsHostHost.newScope scopeFn;
      selfHostTarget = l.makeScope pkgs.pkgsHostTarget.newScope scopeFn;
      selfTargetTarget = l.optionalAttrs (pkgs.pkgsTargetTarget?newScope) (l.makeScope pkgs.pkgsTargetTarget.newScope scopeFn);
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
