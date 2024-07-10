{ writeSkopeoApplication }:

image:

writeSkopeoApplication "copy-to" ''
  echo Running skopeo --insecure-policy copy nix:${image} $@
  skopeo --insecure-policy copy nix:${image} $@
''
