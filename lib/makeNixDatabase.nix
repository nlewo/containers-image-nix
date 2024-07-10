{ lib, runCommand, jq, nix, sqlite }:

# Create a nix database from all paths contained in the given closureGraphJson.
# Also makes all these paths store roots to prevent them from being garbage collected.
closureGraphJson:
assert lib.isDerivation closureGraphJson;
runCommand "nix-database"
{ nativeBuildInputs = [ jq nix sqlite ]; } ''
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
''
