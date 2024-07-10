{ writeSkopeoApplication }:

image:

writeSkopeoApplication "copy-to-podman" ''
  echo "Copy to podman image ${image.imageName}:${image.imageTag}"
  skopeo --insecure-policy copy nix:${image} containers-storage:${image.imageName}:${image.imageTag}
  skopeo --insecure-policy inspect containers-storage:${image.imageName}:${image.imageTag}
''
