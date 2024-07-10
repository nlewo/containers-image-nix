{ writeShellApplication, jq, skopeo-nix2container }:

name: text:

writeShellApplication {
  inherit name text;
  runtimeInputs = [ jq skopeo-nix2container ];
  excludeShellChecks = [ "SC2068" ];
}
