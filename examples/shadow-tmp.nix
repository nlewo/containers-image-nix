{
  pkgs,
  nix2container,
}:
nix2container.buildImage {
  name = "shadow-tmp";
  tag = "latest";

  layers = [
    (nix2container.layers.shadow {includeRoot = true;})
    nix2container.layers.tmp
  ];

  copyToRoot = [pkgs.coreutils];

  config = {
    User = "somebody";
  };
}
