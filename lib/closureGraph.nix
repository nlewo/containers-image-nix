{ lib, runCommand, pkgsBuildHost }:

# Write the references of `path' to a file but do not include `ignore' itself if non-null.
paths: ignore:

let
  ignoreList =
    if ignore == null
    then [ ]
    else if !(builtins.isList ignore)
    then [ ignore ]
    else ignore;
in
runCommand "closure-graph.json"
{
  exportReferencesGraph.graph = paths;
  __structuredAttrs = true;
  PATH = "${pkgsBuildHost.jq}/bin";
  ignoreListJson = builtins.toJSON (builtins.map builtins.toString ignoreList);
  outputChecks.out = {
    disallowedReferences = ignoreList;
  };
  builder = builtins.toFile "builder"
    ''
      . .attrs.sh
      jq --argjson ignore "$ignoreListJson" \
        '.graph|map(select(.path as $p | $ignore | index($p) | not))|map(.references|=sort_by(.))|sort_by(.path)' \
        .attrs.json \
        > ''${outputs[out]}
    '';
}
  ""
