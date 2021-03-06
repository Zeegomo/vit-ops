{ mkNomadJob, systemdSandbox, writeShellScript, coreutils, lib, cacert, curl
, dnsutils, gawk, gnugrep, iproute, jq, lsof, netcat, nettools, procps
, jormungandr-monitor, jormungandr, telegraf, remarshal, dockerImages }:
let
  namespace = "catalyst-dryrun";

  block0 = {
    source =
      "s3::https://s3-eu-central-1.amazonaws.com/iohk-vit-artifacts/${namespace}/block0.bin";
    destination = "local/block0.bin";
    options.checksum =
      "sha256:9cb70f7927201fd11f004de42c621e35e49b0edaf7f85fc1512ac142bcb9db0f";
  };

  mkVit = { index, requiredPeerCount, backup ? false, public ? false, memoryMB ? 512 }:
    let
      localRpcPort = (if public then 10000 else 7000) + index;
      localRestPort = (if public then 11000 else 9000) + index;
      localPrometheusPort = 10000 + index;
      publicPort = 7200 + index;

      role =
        if public then "follower" else if backup then "backup" else "leader";
      name = "${role}-${toString index}";
    in {
      ${name} = {
        count = 1;

        ephemeralDisk = {
          sizeMB = 1024;
          migrate = true;
          sticky = true;
        };

        networks = [{
          mode = "bridge";
          ports = {
            prometheus.to = 6000;
            rest.to = localRestPort;
            rpc.to = localRpcPort;
          };
        }];

        services."${namespace}-${name}-monitor" = {
          portLabel = "prometheus";
          task = "monitor";
        };

        tasks = (lib.optionalAttrs (!backup) {
          monitor =
            import ./tasks/monitor.nix { inherit dockerImages namespace name; };
          env = import ./tasks/env.nix { inherit dockerImages; };
          telegraf = import ./tasks/telegraf.nix {
            inherit dockerImages namespace name;
          };
          jormungandr = import ./tasks/jormungandr.nix {
            inherit lib dockerImages namespace name requiredPeerCount public
              block0 index memoryMB;
          };
        }) // (lib.optionalAttrs backup {
          backup = import ./tasks/backup.nix {
            inherit dockerImages namespace name block0 memoryMB;
          };
        });

        services."${namespace}-${name}-jormungandr" = {
          addressMode = "host";
          portLabel = "rpc";
          task = "jormungandr";
          tags = [ name role ] ++ (lib.optional public "ingress");
          meta = lib.optionalAttrs public {
            ingressHost = "${name}.vit.iohk.io";
            ingressPort = toString publicPort;
            ingressBind = "*:${toString publicPort}";
            ingressMode = "tcp";
            ingressServer =
              "_${namespace}-${name}-jormungandr._tcp.service.consul";
            ingressBackendExtra = ''
              option tcplog
            '';
          };
        };

        services."${namespace}-jormungandr" = {
          addressMode = "host";
          portLabel = "rpc";
          task = "jormungandr";
          tags = [ name "peer" role ];
        };

        services."${namespace}-jormungandr-internal" = lib.mkIf (role != "backup") {
          portLabel = "rpc";
          task = "jormungandr";
          tags = [ name "peer" role ];
        };

        services."${namespace}-${name}-jormungandr-rest" = {
          addressMode = "host";
          portLabel = "rest";
          task = "jormungandr";
          tags = [ name role ];

          checks = [{
            type = "http";
            path = "/api/v0/node/stats";
            portLabel = "rest";

            checkRestart = {
              limit = 5;
              grace = "300s";
              ignoreWarnings = false;
            };
          }];
        };
      };
    };
in {
  ${namespace} = mkNomadJob "vit" {
    datacenters = [ "eu-central-1" "us-east-2" ];
    type = "service";
    inherit namespace;

    spreads = [ {
      attribute = "\${node.unique.name}";
      # attribute = "\${node.datacenter}";
      weight = 100;
    } ];

    migrate = {
      maxParallel     = 1;
      # health_check     = "checks"
      minHealthyTime = "30s";
      healthyDeadline = "5m";
    };

    update = {
      maxParallel = 1;
      healthCheck = "checks";
      minHealthyTime = "30s";
      healthyDeadline = "5m";
      progressDeadline = "10m";
      # autoRevert = true;
      # autoPromote = true;
      # canary = 1;
      stagger = "1m";
    };

    taskGroups = (mkVit {
      index = 0;
      public = false;
      requiredPeerCount = 0;
    }) // (mkVit {
      index = 1;
      public = false;
      requiredPeerCount = 1;
    }) // (mkVit {
      index = 2;
      public = false;
      requiredPeerCount = 2;
    }) // (mkVit {
      index = 0;
      public = true;
      requiredPeerCount = 3;
    });
  };

  "${namespace}-backup" = mkNomadJob "backup" {
    datacenters = [ "eu-central-1" "us-east-2" ];
    type = "batch";
    inherit namespace;

    periodic = {
      cron = "25 */1 * * * *";
      prohibitOverlap = true;
      timeZone = "UTC";
    };

    taskGroups = (mkVit {
      index = 0;
      public = false;
      backup = true;
      requiredPeerCount = 3;
    });
  };
}
