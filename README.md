# nix2container

nix2container provides an efficient container development workflow
with images built by Nix: it doesn't write tarballs to the Nix store
and allows to skip already pushed layers (without having to rebuild
them).

This is based on ideas developed in [this blog
post](https://lewo.abesis.fr/posts/nix-build-container-image/).


## Getting started

```nix
{
  inputs.nix2container.url = "github:nlewo/nix2container";

  outputs = { self, nixpkgs, nix2container }: let
    pkgs = import nixpkgs { system = "x86_64-linux"; };
    nix2containerPkgs = nix2container.packages.x86_64-linux;
  in {
    packages.x86_64-linux.hello = nix2containerPkgs.nix2container.buildImage {
      name = "hello";
      config = {
        entrypoint = ["${pkgs.hello}/bin/hello"];
      };
    };
  };
}
```

This image can then be loaded into Docker with

```
$ nix run .#hello.copyToDockerDaemon
$ docker run hello:latest
Hello, world!
```


## More Examples

To load and run the `bash` example image into Podman:

```
$ nix run github:nlewo/nix2container#examples.bash.copyToPodman
$ podman run -it bash
```

- [`bash`](./examples/bash.nix): Bash in `/bin/`
- [`fromImage`](./examples/from-image.nix): Alpine as base image
- [`fromImageManifest`](./examples/from-image-manifest.nix): Alpine as base image, from a stored `manifest.json`.
- [`nginx`](./examples/nginx.nix)
- [`nonReproducible`](./examples/non-reproducible.nix): with a non reproducible store path :/
- [`openbar`](./examples/openbar.nix): set permissions on files (without root nor VM)
- [`uwsgi`](./examples/uwsgi/default.nix): isolate dependencies in layers
- [`layered`](./examples/layered.nix): build a layered image as described in [this blog post](https://grahamc.com/blog/nix-and-layered-docker-images)


## Functions documentation

### `nix2container.buildImage`

Function arguments are:

- **`name`** (required): the name of the image.

- **`tag`** (defaults to the image output hash): the tag of the image.

- **`config`** (defaults to `{}`): an attribute set describing an image configuration as
    defined in the [OCI image
    specification](https://github.com/opencontainers/image-spec/blob/8b9d41f48198a7d6d0a5c1a12dc2d1f7f47fc97f/specs-go/v1/config.go#L23).

- **`copyToRoot`** (defaults to `null`): a derivation (or list of
    derivations) copied in the image root directory (store path
    prefixes `/nix/store/hash-path` are removed, in order to relocate
    them at the image `/`).

    `pkgs.buildEnv` can be used to build a derivation which has to be copied to
    the image root. For instance, to get bash and coreutils in the image `/bin`:
    ```
    copyToRoot = pkgs.buildEnv {
      name = "root";
      paths = [ pkgs.bashInteractive pkgs.coreutils ];
      pathsToLink = [ "/bin" ];
    };
    ```

- **`fromImage`** (defaults to `null`): an image that is used as base
    image of this image; use `pullImage` or `pullImageFromManifest` to
    supply this.

- **`maxLayers`** (defaults to `1`): the maximum number of layers to
    create. This is based on the store path "popularity" as described
    in this [blog
    post](https://grahamc.com/blog/nix-and-layered-docker-images). Note
    this is applied on the image layers and not on layers added with
    the `buildImage.layers` attribute.

- **`perms`** (defaults to `[]`): a list of file permisssions which are
    set when the tar layer is created: these permissions are not
    written to the Nix store.

    Each element of this permission list is a dict such as
    ```
    { path = "a store path";
      regex = ".*";
      mode = "0664";
    }
    ```
    The mode is applied on a specific path. In this path subtree,
    the mode is then applied on all files matching the regex.

- **`initializeNixDatabase`** (defaults to `false`): to initialize the
    Nix database with all store paths added into the image. Note this
    is only useful to run nix commands from the image, for instance to
    build an image used by a CI to run Nix builds.

- **`layers`** (defaults to `[]`): a list of layers built with the
    buildLayer function: if a store path in deps or contents belongs
    to one of these layers, this store path is skipped. This is pretty
    useful to isolate store paths that are often updated from more
    stable store paths, to speed up build and push time.


### `nix2container.pullImage`

Pull an image from a container registry by name and tag/digest, storing the
entirety of the image (manifest and layer tarballs) in a single store path.
The supplied `sha256` is the narhash of that store path.

Function arguments are:

- **`imageName`** (required): the name of the image to pull.

- **`imageDigest`** (required): the digest of the image to pull.

- **`sha256`** (required): the sha256 of the resulting fixed output derivation.

- **`os`** (defaults to `linux`)

- **`arch`** (defaults to `x86_64`)

- **`tlsVerify`** (defaults to `true`)


### `nix2container.pullImageFromManifest`

Pull a base image from a container registry using a supplied manifest file, and the
hashes contained within it. The advantages of this over the basic `pullImage`:

- Each layer archive is in its own store path, which means each will download just once
  and naturally deduplicate for multiple base images that share layers.
- There is no Nix-specific hash, so it's possible update the base image by simply
  re-fetching the `manifest.json` from the registry; no need to actually pull the whole
  image just to compute a new narhash for it.

With this function the `manifest.json` acts as a lockfile meant to be stored in
source control alongside the Nix container definitions. As a convenience, the manifest
can be fetched/updated using the supplied passthru script, eg:

```
nix run .#examples.fromImageManifest.fromImage.getManifest > examples/alpine-manifest.json
```

Function arguments are:

- **`imageName`** (required): the name of the image to pull.

- **`imageManifest`** (required): the manifest file of the image to pull.

- **`imageTag`** (defaults to `latest`)

- **`os`** (defaults to `linux`)

- **`arch`** (defaults to `x86_64`)

- **`tlsVerify`** (defaults to `true`)

- **`registryUrl`** (defaults to `registry.hub.docker.com`)

Note that `imageTag`, `os`, and `arch` do not affect the pulled image; that is
governed entirely by the supplied `manifest.json` file. These arguments are
used for the manifest-selection logic in the included `getManifest` script.


#### Authentication

If the Nix daemon is used for building, here is how to set up registry
authentication.

1. `docker login URL` to whatever it is
2. Copy `~/.docker/config.json` to `/etc/nix/skopeo/auth.json`
3. Make the directory and all the files readable to the `nixbld` group:
   ```
   sudo chmod -R g+rx /etc/nix/skopeo
   sudo chgrp -R nixbld /etc/nix/skopeo
   ```
4. Bind mount the file into the Nix build sandbox
   ```
   extra-sandbox-paths = /etc/skopeo/auth.json=/etc/nix/skopeo/auth.json
   ```

Every time a new registry authentication has to be added, update
`/etc/nix/skopeo/auth.json` file.


### `nix2container.buildLayer`

For most use cases, this function is not required. However, it could be
useful to explicitly isolate some parts of the image in dedicated
layers, for caching (see the "Isolate dependencies in dedicated
layers" section) or non reproducibility (see the `reproducible`
argument) purposes.

Function arguments are:

- **`deps`** (defaults to `[]`): a list of store paths to include in the
    layer.

- **`copyToRoot`** (defaults to `null`): a derivation (or list of
    derivations) copied in the image root directory (store path
    prefixes `/nix/store/hash-path` are removed, in order to relocate
    them at the image `/`).

    `pkgs.buildEnv` can be used to build a derivation which has to be copied to
    the image root. For instance, to get bash and coreutils in the image `/bin`:
    ```
    copyToRoot = pkgs.buildEnv {
      name = "root";
      paths = [ pkgs.bashInteractive pkgs.coreutils ];
      pathsToLink = [ "/bin" ];
    };
    ```

- **`reproducible`** (defaults to `true`): If `false`, the layer tarball
    is stored in the store path. This is useful when the layer
    dependencies are not bit reproducible: it allows to have the layer
    tarball and its hash in the same store path.

- **`maxLayers`** (defaults to `1`): the maximum number of layers to
    create. This is based on the store path "popularity" as described
    in this [blog
    post](https://grahamc.com/blog/nix-and-layered-docker-images). Note
    this is applied on the image layers and not on layers added with
    the `buildLayer.layers` attribute.

- **`perms`** (defaults to `[]`): a list of file permisssions which are
    set when the tar layer is created: these permissions are not
    written to the Nix store.

    Each element of this permission list is a dict such as
    ```
    { path = "a store path";
      regex = ".*";
      mode = "0664";
    }
    ```
    The mode is applied on a specific path. In this path subtree,
    the mode is then applied on all files matching the regex.

- **`layers`** (defaults to `[]`): a list of layers built with the
    `buildLayer` function: if a store path in deps or contents belongs
    to one of these layers, this store path is skipped. This is pretty
    useful to isolate store paths that are often updated from more
    stable store paths, to speed up build and push time.

- **`ignore`** (defaults to `null`): a store path to ignore when
    building the layer. This is mainly useful to ignore the
    configuration file from the container layer.

- **`metadata`** (defaults to `{ created_by = "nix2container"; }`): an attribute
    set containing this layer's `created_by`, `author` and `comment` values

## Isolate dependencies in dedicated layers

It is possible to isolate application dependencies in a dedicated
layer. This layer is built by its own derivation: if storepaths
composing this layer don't change, the layer is not rebuilt. Moreover,
Skopeo can avoid to push this layer if it has already been pushed.

Let's consider an `application` printing a conversation. This script
depends on `bash` and the `hello` binary. Because most of the changes
concern the script itself, it would be nice to isolate scripts
dependencies in a dedicated layer: when we modify the script, we only
need to rebuild and push the layer containing the script. The layer
containing dependencies won't be rebuilt and pushed.

As shown below, the `buildImage.layers` attribute allows to
explicitly specify a set of dependencies to isolate.

```nix
{ pkgs }:
let
  application = pkgs.writeScript "conversation" ''
    ${pkgs.hello}/bin/hello
    echo "Haaa aa... I'm dying!!!"
  '';
in
pkgs.nix2container.buildImage {
  name = "hello";
  config = {
    entrypoint = ["${pkgs.bash}/bin/bash" application];
  };
  layers = [
    (pkgs.nix2container.buildLayer { deps = [pkgs.bash pkgs.hello]; })
  ];
}
```

This image contains 2 layers: a layer with `bash` and `hello` closures
and a second layer containing the script only.

In real life, the isolated layer can contains a Python environment or
Node modules.

Keep in mind that each layer will only be able to strip out nix store paths
that exist in their _child_ layers (because layers can contain layers), not in
their _sibling_ layers. So, if you did it like this, chances are that there
were some repeated nix store paths between layers 1 and 2. In that case, you
must choose between optimizing image cache or image size:

```nix
{ pkgs }:
let
  application = pkgs.writeScript "conversation" ''
    ${pkgs.hello}/bin/hello
    echo "Haaa aa... I'm dying!!!"
  '';
  layer1 = pkgs.nix2container.buildLayer { deps = [pkgs.bash]; };
  layer2 = pkgs.nix2container.buildLayer { deps = [pkgs.hello]; };
in
pkgs.nix2container.buildImage {
  name = "hello";
  config = {
    entrypoint = ["${pkgs.bash}/bin/bash" application];
  };
  # These layers might duplicate a store path
  layers = [layer1 layer2];
}
```

If you have many layers and you want to control their splitting manually, but
still avoid duplicating data, you can just fold them:

```nix
{ lib, pkgs }:
let
  application = pkgs.writeScript "conversation" ''
    ${pkgs.hello}/bin/hello
    echo "Haaa aa... I'm dying!!!"
  '';
in
pkgs.nix2container.buildImage {
  name = "hello";
  config = {
    entrypoint = ["${pkgs.bash}/bin/bash" application];
  };
  # Folding layers to avoid duplicating store paths
  layers = lib.foldl
    (acc: current:
      [(pkgs.nix2container.buildLayer (current // {layers = acc;}))])
    []
    [
      {deps = [pkgs.bash]}
      {deps = [pkgs.hello]}
    ];
}
```

See
[Nix & Docker: Layer explicitly without duplicate packages!](https://blog.eigenvalue.net/2023-nix2container-everything-once/)
for learning how to avoid duplicate store paths in your explicitly layered
images.

## Quick and dirty benchmarks

The main goal of nix2container is to provide fast rebuild/push
container cycles. In the following, we provide an order of magnitude
of rebuild and repush time, for the [`uwsgi` image](https://github.com/nlewo/nix2container/blob/c6a8d82f1cdd80fabb76e7c1459471e1ea95a080/examples/uwsgi/default.nix).

**warning: this is quick and dirty benchmarks which only provide an order of magnitude**

We build the container and push the container. We then made a small
change in the `hello.py` file to trigger a rebuild and a push.

Method | Rebuild/repush time | Executed command
---|---|---
nix2container.buildImage | ~1.8s | `nix run .#example.uwsgi.copyToRegistry`
dockerTools.streamLayeredImage | ~7.5s | `nix build .#example.uwsgi \| docker load`
dockerTools.buildImage | ~10s | `nix build .#example.uwsgi; skopeo copy docker-archive://./result docker://localhost:5000/uwsgi:latest`

Note we could not compare the same distribution mechanisms because
- Skopeo is not able to skip already loaded layers by the Docker daemon and
- Skopeo failed to push to the registry an image streamed to stdin.


## Run the tests

```
nix run .#tests.all
```

This builds several example images with Nix, loads them with Skopeo,
runs them with Podman, and test output logs.

Not that, unfortunately, these tests are not executed in the Nix
sandbox because it is currently not possible to run a container in the
Nix sandbox.

It is also possible to run a specific test:

```
nix run .#tests.basic
```


## The nix2container Go library

This library is currently used by the Skopeo `nix` transport available
in [this branch](https://github.com/nlewo/image/tree/nix).

For more information, refer to [the Go
documentation](https://pkg.go.dev/github.com/nlewo/nix2container).
