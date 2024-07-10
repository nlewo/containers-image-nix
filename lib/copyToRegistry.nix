{ writeSkopeoApplication }:

image:

writeSkopeoApplication "copy-to-registry" ''
  echo "Copy to Docker registry image ${image.imageName}:${image.imageTag}"
  skopeo --insecure-policy copy nix:${image} docker://${image.imageName}:${image.imageTag} $@
''
