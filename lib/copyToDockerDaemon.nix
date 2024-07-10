{ writeSkopeoApplication }:

image:

writeSkopeoApplication "copy-to-docker-daemon" ''
  echo "Copy to Docker daemon image ${image.imageName}:${image.imageTag}"
  skopeo --insecure-policy copy nix:${image} docker-daemon:${image.imageName}:${image.imageTag} $@
''
