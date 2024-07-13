{ pkgs, nix2container, examples }:

let
  testScript = {
    image,
    command ? "",
    grepFlags ? "",
    runFlags ? "",
    pattern,
  }: pkgs.writeScriptBin "test-script" ''
    ${image.copyToPodman}/bin/copy-to-podman
    ${pkgs.podman}/bin/podman run ${runFlags} ${image.imageName}:${image.imageTag} ${command} | ${pkgs.gnugrep}/bin/grep ${grepFlags} '${pattern}'
    ret=$?
    if [ $ret -ne 0 ];
    then
      echo "image list"
      ${pkgs.podman}/bin/podman image list
      echo ""
      echo "Actual output:"
      ${pkgs.podman}/bin/podman run ${image.imageName}:${image.imageTag} ${command}
      echo
      echo "Expected pattern:"
      echo '${pattern}'
      echo
      echo "Error: test failed"
      exit $ret
    else
      echo "Test passed"
    fi
  '';
  tests = {
    hello = testScript {
      image = examples.hello;
      pattern = "dying";
    };
    basic = testScript {
      image = examples.basic;
      pattern = "Hello, world";
    };
    openbar = testScript {
      image = examples.openbar;
      pattern = "^drwxrwxrwx.*tmp$";
    };
    bashVersion = testScript {
      image = examples.bash;
      command = "bash --version";
      pattern = "^GNU bash, version";
    };
    bashLs = testScript {
      image = examples.bash;
      command = "ls";
      pattern = "^bin$";
    };
    fromImage = testScript {
      image = examples.fromImage;
      pattern = "/etc/alpine-release$";
    };
    fromImageManifest = testScript {
      image = examples.fromImageManifest;
      pattern = "/etc/alpine-release$";
    };
    layered = testScript {
      image = examples.layered;
      pattern = "Hello, world";
    };
    nonReproducible = testScript {
      image = examples.nonReproducible;
      pattern = "A non reproducible image built the";
    };
    nested = testScript {
      image = examples.nested;
      pattern = "Hello, world";
    };
    ownership = testScript {
      image = examples.ownership;
      pattern = "^-r--r--r-- 1 1001 1001 0 Jan  1  1970 test1.txt";
    };
    # Ensure the Nix database is correctly initialized by querying the
    # closure of the Nix binary.
    nix = testScript {
      image = examples.nix;
      command = "nix-store -qR ${pkgs.nix}";
      pattern = "${pkgs.nix}";
    };
    nix-user = testScript {
      image = examples.nix-user;
      grepFlags = "-Pz";
      pattern = "(?s)\[PASS].*\[PASS].*\[PASS].*drwxr-xr-x \\d+ user user 4096 Jan  1  1970 store";
    };
    shadow-somebody = testScript {
      image = examples.shadow-tmp;
      command = "id";
      pattern = "uid=1000(somebody) gid=1000(somebody) groups=1000(somebody)";
    };
    shadow-root = testScript {
      image = examples.shadow-tmp;
      runFlags = "-u root";
      command = "id";
      pattern = "uid=0(root) gid=0(root) groups=0(root)";
    };
    tmp-stat = testScript {
      image = examples.shadow-tmp;
      command = "stat -c %a /tmp";
      pattern = "1777";
    };
    tmp-mktemp = testScript {
      image = examples.shadow-tmp;
      command = "mktemp";
      pattern = "/tmp/tmp.";
    };
    # Ensure the Nix database is correctly initialized by querying the
    # closure of the Nix binary.
    # The store path is in a dedicated layer
    nixNested = testScript {
      image = examples.nix;
      command = "nix-store -qR ${pkgs.hello}";
      pattern = "${pkgs.hello}";
    };
    # The /nix have to be explicitly present in the archive with 755 perms
    nonRegressionIssue12 = pkgs.runCommand "test-script" { buildInputs = [pkgs.jq pkgs.gnutar]; } ''
      set -e
      ${examples.basic.copyTo}/bin/copy-to dir://$PWD/image
      cd $PWD/image
      echo "Checking /nix permission are 755 in the tar archive..."
      cat manifest.json | jq -r '.layers[].digest' | cut -d":" -f2 | xargs tar -tvf | grep "^drwxr-xr-x.*nix$"
      echo Test passed
      # TODO: actually this test doesn't need to be run
      mkdir -p $out/bin
      echo echo Test passed > $out/bin/test-script
      chmod a+x $out/bin/test-script
    '';
    nonRegressionIssue45 = testScript {
      image = let
        test = pkgs.runCommand "test" { } ''
          mkdir -p $out/tmp
          touch $out/tmp/test1.txt
          touch $out/tmp/test2.txt
        '';
      in nix2container.buildImage {
        name = "perms";
        config.entrypoint = ["${pkgs.coreutils}/bin/ls" "-l" "/tmp/"];
        copyToRoot = [ test ];
        perms = [
          {
            path = test;
            regex = "test1.txt";
            mode = "0777";
          }
        ];
      };
      # The file test2.txt should not have 777 perms
      pattern = "^-r--r--r-- 1 0 0 0 Jan  1  1970 test2.txt";
    };
    copyToRoot = testScript {
      image = nix2container.buildImage {
        name = "copy-to-root";
        copyToRoot = [ pkgs.hello pkgs.bash ];
        config.entrypoint = ["/bin/bash" "-c" "/bin/hello"];
      };
      pattern = "Hello, world!";
    };
  } //
  (pkgs.lib.mapAttrs' (name: drv: {
    name = "${name}GetManifest";
    value = pkgs.writeScriptBin "test-script" ''
      set -e
      # Don't pipe directly here, as we don't want to swallow a return code.
      manifest=$(${drv.getManifest}/bin/get-manifest)
      echo "$manifest" | ${pkgs.jq}/bin/jq -e 'has("layers")' > /dev/null
      echo "Test Passed"
    '';
  }) examples.getManifest.images);

  all =
    let scripts =
      pkgs.lib.concatStringsSep
      "\n"
      (pkgs.lib.mapAttrsToList (n: v: "echo Running test '${n}'\n${v}/bin/test-script") tests);
    in pkgs.writeScriptBin "all-test-scripts" ''
      set -e
      ${scripts}
    '';
in tests // { inherit all; }
