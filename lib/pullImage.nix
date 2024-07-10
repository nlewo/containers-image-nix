{ lib, runCommand, go, skopeo, cacert, nix2container-bin }:

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
let
  fixName = name: lib.replaceStrings [ "/" ":" ] [ "-" "-" ] name;
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
}:
let
  authFile = "/etc/skopeo/auth.json";
  dir = runCommand name
    {
      inherit imageDigest;
      impureEnvVars = lib.fetchers.proxyImpureEnvVars;
      outputHashMode = "recursive";
      outputHashAlgo = "sha256";
      outputHash = sha256;

      nativeBuildInputs = [ skopeo ];
      SSL_CERT_FILE = "${cacert.out}/etc/ssl/certs/ca-bundle.crt";

      sourceURL = "docker://${imageName}@${imageDigest}";
    } ''
    skopeo \
      --insecure-policy \
      --tmpdir=$TMPDIR \
      --override-os ${os} \
      --override-arch ${arch} \
      copy \
      --src-tls-verify=${lib.boolToString tlsVerify} \
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
in
runCommand "nix2container-${imageName}.json"
{ nativeBuildInputs = [ nix2container-bin ]; } ''
  nix2container image-from-dir $out ${dir}
''
