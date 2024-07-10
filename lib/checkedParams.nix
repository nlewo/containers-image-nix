{ lib }:

{ copyToRoot, contents }:

lib.warnIf (contents != null)
  "The contents parameter is deprecated. Change to copyToRoot if the contents are designed to be copied to the root filesystem, such as when you use `buildEnv` or similar between contents and your packages. Use copyToRoot = buildEnv { ... }; or similar if you intend to add packages to /bin."
  lib.throwIf
  (contents != null && copyToRoot != null)
  "You can not specify both contents and copyToRoot."
