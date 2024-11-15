{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  wazuhUser = "wazuh";
  wazuhGroup = wazuhUser;
  stateDir = "/var/ossec";
  cfg = config.services.wazuh-agent;
  pkg = config.services.wazuh-agent.package;

  generatedConfig = import ./generate-agent-config.nix {
    cfg = config.services.wazuh-agent;
    inherit pkgs;
  };

  preStart = ''
    # Create required directories and set ownership
#     mkdir -pv ${stateDir}/{etc/shared}
#     find ${stateDir} -type d -exec chmod 750 {} \;
    chown -R ${wazuhUser}:${wazuhGroup} ${stateDir}

    ${concatMapStringsSep "\n"
        (dir: "cp -Rv ${pkg}/${dir} ${stateDir}/${dir}")
        [ "queue" "var" "wodles" "logs" "lib" "tmp" "agentless" "active-response" "etc" ]
     }

    chown -R ${wazuhUser}:${wazuhGroup} ${stateDir}

    find ${stateDir} -type d -exec chmod 770 {} \;
    find ${stateDir} -type f -exec chmod 750 {} \;

    # Generate and copy ossec.config
    cp ${pkgs.writeText "ossec.conf" generatedConfig} ${stateDir}/etc/ossec.conf

  '';

  daemons =
    ["wazuh-modulesd" "wazuh-logcollector" "wazuh-syscheckd" "wazuh-agentd" "wazuh-execd"];
  daemonsWithDeps = # get an attrset where fst is the service and snd is the dependency
    zipLists (tail daemons) daemons;

  mkService = d:
    {
      description = "${d}";
      wants = [ "network-online.target" ];
      after = [ "network.target" "network-online.target" ];
      partOf = [ "wazuh.target" ];
      path = [ "/run/current-system/sw/bin" "/run/wrappers/bin" ];
      environment = {
        WAZUH_HOME = stateDir;
      };

      serviceConfig = {
        Type = "exec";
        User = wazuhUser;
        Group = wazuhGroup;
        WorkingDirectory = "${stateDir}/";
        CapabilityBoundingSet = [ "CAP_SETGID" ];

        ExecStart =
          if (d != "wazuh-modulesd")
          then "/run/wrappers/bin/${d} -f -c ${stateDir}/etc/ossec.conf"
          else "/run/wrappers/bin/${d} -f";
      };
    };

in {
  options = {
    services.wazuh-agent = {
      enable = lib.mkEnableOption "Wazuh agent";

      managerIP = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = ''
          The IP address or hostname of the manager.
        '';
        example = "192.168.1.2";
      };

      managerPort = lib.mkOption {
        type = lib.types.port;
        description = ''
          The port the manager is listening on to receive agent traffic.
        '';
        example = 1514;
        default = 1514;
      };

      package = lib.mkPackageOption pkgs "wazuh-agent" {};

      extraConfig = lib.mkOption {
        type = lib.types.lines;
        description = ''
          Extra configuration values to be appended to the bottom of ossec.conf.
        '';
        default = "";
        example = ''
          <!-- The added ossec_config root tag is required -->
          <ossec_config>
            <!-- Extra configuration options as needed -->
          </ossec_config>
        '';
      };
    };
  };

  config = mkIf cfg.enable {

    users.users.${wazuhUser} = {
      #       isSystemUser = true;
      isNormalUser = true;
      group = wazuhGroup;
      shell = pkgs.bashInteractive;
      description = "Wazuh daemon user";
      home = stateDir;
      createHome = true;
      homeMode = "770";
    };

    users.groups.${wazuhGroup} = {};

    # systemd.tmpfiles.rules = [
#       "d ${stateDir} 0750 ${wazuhUser} ${wazuhGroup}"
#     ];;

    systemd.targets.multi-user.wants = [ "wazuh.target" ];
    systemd.targets.wazuh.wants = forEach daemons (d: "${d}.service" );

    systemd.services =
      listToAttrs
        (map
          (daemon: nameValuePair daemon (mkService daemon))
          daemons) //
      { setup-pre-wazuh = {
         description = "Sets up wazuh's directory structure";
         wantedBy = map (d: "${d}.service") daemons;
         before = map (d: "${d}.service") daemons;
         serviceConfig = {
           Type = "oneshot";
           User = wazuhUser;
           Group = wazuhGroup;
           ExecStart =
             let
               script = pkgs.writeShellApplication { name = "wazuh-prestart"; text = preStart; };
             in "${script}/bin/wazuh-prestart";
         };
        };
      };

    security.wrappers =
      listToAttrs
        (forEach daemons
          (d:
            nameValuePair
              d
              {
                setgid = true;
                setuid = true;
                owner = "root";
                group = "root";
                source = "${pkg}/bin/${d}";
              }
          )
        );

    # systemd.services.wazuh-agent = {


#       description = "Wazuh agent";
#       wants = ["network-online.target"];
#       after = ["network.target" "network-online.target"];
#       wantedBy = ["multi-user.target"];

#       serviceConfig = {
#         Type = "forking";
#         WorkingDirectory = "${stateDir}/bin";
#         ExecStart = "${stateDir}/bin/wazuh-control start";
#         ExecStop = "${stateDir}/bin/wazuh-control stop";
#         ExecReload = "${stateDir}/bin/wazuh-control reload";
#         KillMode = "process";
#         RemainAfterExit = "yes";
#       };
#     };
  } # //
#   listToAttrs
#     (forEach
#       daemonsWithDeps
#       ({fst, snd}:
#         let
#           service = fst;
#           its-dep = snd;
#         in
#           {
#             name = "systemd.services.${service}.requires";
#             value = [ "${its-dep}.service" ];
#           })) //
#   listToAttrs
#     (forEach
#       daemonsWithDeps
#       ({fst, snd}:
#         let
#           service = fst;
#           its-dep = snd;
#         in
#           {
#             name = "systemd.services.${service}.after";
#             value = [ "${its-dep}.service" ];
#           }))
  ;
}
