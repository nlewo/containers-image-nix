{ pkgs, nix2container }:
let
    nginxPort = "80";
    nginxConf = pkgs.writeText "nginx.conf" ''
      user nobody nobody;
      daemon off;
      error_log /dev/stdout info;
      pid /dev/null;
      events {}
      http {
        access_log /dev/stdout;
        server {
          listen ${nginxPort};
          index index.html;
          location / {
            root ${nginxWebRoot};
          }
        }
      }
    '';
    nginxWebRoot = pkgs.writeTextDir "index.html" ''
      <html><body><h1>Hello from NGINX</h1></body></html>
    '';
    nginxVar = pkgs.runCommand "nginx-var" {} ''
      mkdir -p $out/var/log/nginx
      mkdir -p $out/var/cache/nginx
    '';
in
nix2container.buildImage {
  name = "nginx";
  
  layers = [
    (nix2container.buildLayer {
        copyToRoot = [
          pkgs.dockerTools.fakeNss
          nginxVar
        ];
    })
    (nix2container.buildLayer {
      copyToRoot = [
        pkgs.nginx
      ];
      capabilities = [
        {
          path = pkgs.nginx;
          regex = "bin/nginx";
          caps = [ "CAP_NET_BIND_SERVICE" ];
        }
      ];
    })
  ];
  config = {
    Cmd = [ "/bin/nginx" "-c" nginxConf ];
    ExposedPorts = {
      "${nginxPort}/tcp" = {};
    };
  };
}
