{ lib, runCommand, writeText, go, cacert, curl, jq, nix2container-bin, selfBuildHost }:

{ imageName
, imageManifest ? null
  # The manifest dictates what is pulled; these three are only used for
  # the supplied manifest-pulling script.
, imageTag ? "latest"
, os ? "linux"
, arch ? go.GOARCH
, tlsVerify ? true
, registryUrl ? "registry.hub.docker.com"
, meta ? { }
}:
let
  manifest = builtins.fromJSON (lib.readFile imageManifest);

  buildImageBlob = digest:
    let
      blobUrl = "https://${registryUrl}/v2/${imageName}/blobs/${digest}";
      plainDigest = lib.replaceStrings [ "sha256:" ] [ "" ] digest;
      insecureFlag = lib.strings.optionalString (!tlsVerify) "--insecure";
    in
    runCommand plainDigest
      {
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
  blobMap = lib.listToAttrs (map (drv: { name = drv.name; value = drv; }) (layerBlobs ++ [ configBlob ]));
  blobMapFile = writeText "${imageName}-blobs.json" (builtins.toJSON blobMap);

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

in
runCommand "nix2container-${imageName}.json"
{
  nativeBuildInputs = [ nix2container-bin ];
  passthru = { inherit getManifest; };
} ''
  nix2container image-from-manifest $out ${imageManifest} ${blobMapFile}
''
