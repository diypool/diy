{ 
  config, 
  pkgs,
  lib,
  cardano-node-src,
  cardano-rt-view-src,
  ... 
}:
with lib;
let
  cfg = config.services.stake-pool;

  cardanoSrc = builtins.fetchTarball {
    url = cardano-node-src.url;
    sha256 = cardano-node-src.hash;
  };

  cardanoNixos = "${cardanoSrc}/nix/nixos";
  cardano = import "${cardanoSrc}/nix" {};
  nodeCfg = config.services.cardano-node.environments.mainnet.nodeConfig;
  topology = builtins.toFile "topology.json" ''
          {
            "Producers": [
              ${concatMapStringsSep "," (r: 
              ''
                {"addr": "${r.addr}", "port": ${toString r.port}, "valency": ${toString r.valency}}
              '') cfg.topology
              }
            ]
          }
        '';

  newNodeCfg = nodeCfg // {
    setupBackends = nodeCfg.setupBackends ++ [ "TraceForwarderBK" "EKGViewBK" ];
    TurnOnLogMetrics = true;
    MaxConcurrencyDeadline = 2;
    options.mapBackends."cardano.node.metrics" = nodeCfg.options.mapBackends."cardano.node.metrics" ++ [ "TraceForwarderBK" ];
    options.mapBackends."cardano.node.Forge.metrics" = [ "TraceForwarderBK" ];
    traceForwardTo = {
      tag = "RemoteSocket";
      contents = ["127.0.0.1" (toString cfg.cardano-node.tracePort)];
    };
  };

  isBlockProducer = !isNull cfg.cardano-node.kesKey;
  userName = if isBlockProducer then "producer" else "relay";
  rtViewDisplayName = "${cfg.name}-${userName}";
  
  allowRelay = if isBlockProducer then
    lib.strings.concatStringsSep "\n" (lib.lists.forEach (cfg.topology) (t: ''
      iptables -A INPUT -p tcp -s ${t.addr} --dport ${toString cfg.cardano-node.port} -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT
    ''))
  else
    "";
in 
{
  imports = [
    cardanoNixos
  ];

  options = {
    services.stake-pool = {

      name = mkOption {
        type = types.str;
        description = ''
          Name of the stake pool
        '';
      };

      userShell = mkOption {
        type = types.either types.shellPackage types.path;
        default = pkgs.bash;
        description = ''
          Shell of the user
        '';
      };

      enableSudo = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Enable user to sudo
        '';
      };

      ssh = mkOption {
        type = with types; submodule {
          options = {
            port = mkOption {
              type = types.port;
              description = ''
                Port of the SSH server. Please choose a random port
              '';
            };

            public-key = mkOption {
              type = types.str;
              description = ''
                Public SSH keys to be used
              '';
            };
          };
        };
      };

      wireguard = mkOption {
        type = with types; (submodule {
          options = {
            port = mkOption {
              type = types.port;
              description = ''
                WireGuard port. Please choose a random port
              '';
            };

            peerPublicKey = mkOption {
              type = types.str;
              description = ''
                Public key of wireguard peer
              '';
            };

            allowedIP = mkOption {
              type = types.str;
              default = "10.100.0.1/32";
              description = ''
                Allowed IP
              '';
            };

            privateKeyPath = mkOption {
              type = types.str;
              default = "/keys/wg/privatekey";
              description = ''
                Path to private wireguard key file
              '';
            };

            ip = mkOption {
              type = types.str;
              default = if (isBlockProducer) then "10.100.0.2/24" else "10.100.0.3/24";
              description = ''
                WireGuard IP
              '';
            };
          };
        });
      };

      cardano-node = mkOption {
        type = with types; submodule {
          options = {

            enable = mkOption {
              type = types.bool;
              default = false;
              description = ''
                Enable cardano-node or not
              '';
            };

            port = mkOption {
              type = types.port;
              description = ''
                Port to bind cardano-node to
              '';
            };

            tracePort = mkOption {
              type = types.port;
              description = ''
                Port to send trace dat to
              '';
            };

            kesKey = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = ''
                Path to KES
              '';
            };

            vrfKey = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = ''
                Path to VRF key
              '';
            };

            operationalCertificate = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = ''
                Path to operational certificate
              '';
            };

          };
        };
      };

      cardano-rt-view = mkOption {
        type = with types; submodule {
          options = {
            port = mkOption {
              type = types.port;
              description = ''
                Port to bind cardano-rt-view
              '';
            };
          };
        };
      };

      topology = mkOption {
        type = with types; listOf (submodule {
          options = {
            addr = mkOption {
              type = types.str;
              description = ''
                Address of the relay to connect to
              '';
            };
            port = mkOption {
              type = types.port;
              description = ''
                Port of the relay to connect to
              '';
            };
            valency = mkOption {
              type = types.int;
              default = 1;
              description = ''
                Valency of relay
              '';
            };
          };
        });
        description = ''
          Nodes to connect to. If block producer node, only connect to a relays you control.
        '';
      };
    };
  };

  config = mkMerge [
    {
      assertions = [
        {
          assertion = !isNull cfg.name;
          message = "Stake pool must have a name";
        }
        {
          assertion = if isBlockProducer 
            then (
              !isNull cfg.cardano-node.kesKey && 
              !isNull cfg.cardano-node.vrfKey && 
              !isNull cfg.cardano-node.operationalCertificate
            ) 
            else 
              true;
          message = "Block producer node must have kesKey, vrfKey and operationalCertificate options set";
        }
      ];
    }
    
    {
      environment.systemPackages = with pkgs; [
        curl
        vim
        tmux
        htop
        iotop
        iftop
      ];
      networking.hostName = cfg.name;
      networking.firewall.allowPing = false;
      services.chrony.enable = true;
      services.chrony.servers = [];
      # Credit https://www.coincashew.com/coins/overview-ada/guide-how-to-build-a-haskell-stakepool-node/how-to-setup-chrony
      services.chrony.extraConfig = ''
        pool time.google.com       iburst minpoll 1 maxpoll 2 maxsources 3
        pool ntp.ubuntu.com        iburst minpoll 1 maxpoll 2 maxsources 3
        pool us.pool.ntp.org       iburst minpoll 1 maxpoll 2 maxsources 3

        maxupdateskew 5.0
        rtcsync
        makestep 0.1 -1
      '';
    }

    {
      users.users."${userName}" = {
        extraGroups = if cfg.enableSudo then [ "wheel" ] else [];
        shell = cfg.userShell;
        createHome = true;
        description = "${userName} user";
        home = "/home/${userName}";
        openssh.authorizedKeys.keys = [
          cfg.ssh.public-key
        ];
      };

      users.groups.cardano-rt-view.name = "cardano-rt-view";
      users.users.cardano-rt-view = {
        description = "cardano-rt-view daemon user";
        group = "cardano-rt-view";
        createHome = true;
        home = "/home/cardano-rt-view";
      };

      services.openssh = {
        enable = true;
        ports = [ cfg.ssh.port ];
        permitRootLogin = "no";
        passwordAuthentication = false;
        openFirewall = false;
        allowSFTP = false;
      };

      networking.wireguard.interfaces.wg0 = {
        ips = [ cfg.wireguard.ip ];
        listenPort = cfg.wireguard.port;
        privateKeyFile = cfg.wireguard.privateKeyPath;
        peers = [ 
          {
            allowedIPs = [ cfg.wireguard.allowedIP ];
            publicKey = cfg.wireguard.peerPublicKey;
          }
         ];
      };

      networking.firewall.allowedUDPPorts = [ cfg.wireguard.port ];
      networking.firewall.extraCommands = ''
        iptables -t nat -A POSTROUTING -s ${cfg.wireguard.ip} -o lo -j MASQUERADE
        iptables -A INPUT -p tcp -s ${cfg.wireguard.allowedIP} --dport ${toString cfg.ssh.port} -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT
        iptables -A INPUT -p tcp -s ${cfg.wireguard.allowedIP} --dport ${toString cfg.cardano-rt-view.port} -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT
        ${allowRelay}
      '';
    }

    (mkIf (!isBlockProducer && cfg.cardano-node.enable) { # Relay node
      services.cardano-node = {
        enable = true;
        port = cfg.cardano-node.port;
        topology = topology;
        hostAddr = "0.0.0.0";

        environment = "mainnet";
        nodeConfig = newNodeCfg;
      };

      networking.firewall.allowedTCPPorts = [ cfg.cardano-node.port ];
    })

    (mkIf (isBlockProducer && cfg.cardano-node.enable) { # Block producer node
      services.cardano-node = {
        enable = true;
        port = cfg.cardano-node.port;
        topology = topology;
        hostAddr = "0.0.0.0";

        environment = "mainnet";
        nodeConfig = newNodeCfg;
        kesKey = cfg.cardano-node.kesKey;
        vrfKey = cfg.cardano-node.vrfKey;
        operationalCertificate = cfg.cardano-node.operationalCertificate;
      };
    })

    (mkIf cfg.cardano-node.enable {
      environment.systemPackages = with pkgs; [
        cardano.pkgs.cardano-cli
      ];


      environment.variables = {
        CARDANO_NODE_SOCKET_PATH = "/run/cardano-node/node.socket";
      };


      systemd.services.cardano-rt-view = 
      let
        cardanoRTViewSrc = builtins.fetchTarball {
          url = cardano-rt-view-src.url;
          sha256 = cardano-rt-view-src.hash;
        };

        static = ''${cardanoRTViewSrc}/static'';
        rtView = import "${cardanoRTViewSrc}/" {};
        
        viewJson = ''
          {
            "rotation": null,
            "defaultBackends": [
              "KatipBK"
            ],
            "setupBackends": [
              "KatipBK",
              "LogBufferBK",
              "TraceAcceptorBK"
            ],
            "hasPrometheus": null,
            "hasGraylog": null,
            "hasGUI": null,
            "traceForwardTo": null,
            "traceAcceptAt": [
              {
                "remoteAddr": {
                  "tag": "RemoteSocket",
                  "contents": [
                    "127.0.0.1",
                    "${builtins.toString cfg.cardano-node.tracePort}"
                  ]
                },
                "nodeName": "${rtViewDisplayName}"
              }
            ],
            "defaultScribes": [
              [
                "StdoutSK",
                "stdout"
              ]
            ],
            "options": {
              "mapBackends": {
                "cardano-rt-view.acceptor": [
                  "LogBufferBK",
                  {
                    "kind": "UserDefinedBK",
                    "name": "ErrorBufferBK"
                  }
                ]
              }
            },
            "setupScribes": [
              {
                "scMaxSev": "Emergency",
                "scName": "stdout",
                "scRotation": null,
                "scMinSev": "Notice",
                "scKind": "StdoutSK",
                "scFormat": "ScText",
                "scPrivacy": "ScPublic"
              }
            ],
            "hasEKG": null,
            "forwardDelay": null,
            "minSeverity": "Info"
          }
        '';

        notificationJson = ''
          {
            "nsCheckPeriodInSec": 120,
            "nsEventsToNotify": {
              "errorsEvents": {
                "aboutCriticals": true,
                "aboutWarnings": true,
                "aboutEmergencies": true,
                "aboutAlerts": true,
                "aboutErrors": true
              },
              "blockchainEvents": {
                "aboutMissedSlots": true,
                "aboutCannotForge": true
              }
            },
            "nsHowToNotify": {
              "emailSettings": {
                "emServerPort": 587,
                "emSubject": "Cardano RTView Notification",
                "emEmailTo": "",
                "emServerHost": "",
                "emUsername": "",
                "emSSL": "TLS",
                "emPassword": "",
                "emEmailFrom": ""
              }
            },
            "nsEnabled": true
          }
        '';


        viewFile = builtins.toFile "cardano-rt-view.json" viewJson;
        notificationFile = builtins.toFile "cardano-rt-view-notifications.json" notificationJson;
      in
      {
        description = "cardano-rt-view service";
        wantedBy = [ "cardano-node.service" ];
        serviceConfig = {
          User = "cardano-rt-view";   
          Group = "cardano-rt-view";   
          Restart = "always";
          ExecStart = ''${rtView.cardano-rt-view}/bin/cardano-rt-view --config ${viewFile} --notifications ${notificationFile} --port ${builtins.toString cfg.cardano-rt-view.port} --static ${static}'';
          RuntimeDirectory = "cardano-rt-view";
          WorkingDirectory = "-";
          StateDirectory = "cardano-rt-view";
          RestartSec = 1;
          KillSignal = "SIGINT";
        };
      };
    })
  ];
}
