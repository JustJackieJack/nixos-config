# access-mcp: lets claude (as the target account) ask for temporary access to a file and have
# Jacek approve it with a kdialog window, instead of Jacek having to run claude-view/-edit/-copy
# by hand. One instance per target account, each on its own 127.0.0.1 port - register it in
# that account's .claude.json (see instructions.nix, which writes CLAUDE.md for the claude
# account).
#
# The actual server logic lives in ./access-mcp.py as plain Python (no Nix syntax inside it) -
# this file only wires up the absolute /nix/store paths it needs, as environment variables, so
# the Python stays readable/lintable/testable on its own.
{ config, lib, pkgs, ... }:
let
  accessMcpPorts = {
    claude = 8765;
    game_user = 8766;
    zeroroot = 8767;
  };

  accessMcpPython = pkgs.python3.withPackages (ps: [ ps.mcp ]);
  accessMcpScript = pkgs.writeShellApplication {
    name = "access-mcp";
    text = ''
      export SUDO=/run/wrappers/bin/sudo
      export SHARE_BIN=${config.moje.claude.shareBin}
      export NOTIFY_SEND=${pkgs.libnotify}/bin/notify-send
      export KDIALOG=${pkgs.kdePackages.kdialog}/bin/kdialog
      export TIMEOUT=${pkgs.coreutils}/bin/timeout
      exec ${accessMcpPython}/bin/python3 ${./access-mcp.py} "$@"
    '';
  };

  accessMcpServices = lib.mapAttrs' (
    targetUser: port:
    lib.nameValuePair "access-mcp-${targetUser}" {
      description = "MCP server: approve access to Jacek's files for account ${targetUser}";
      wantedBy = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];
      unitConfig.ConditionUser = "Jacek";
      serviceConfig = {
        ExecStart = "${accessMcpScript}/bin/access-mcp --target-user ${targetUser} --port ${toString port}";
        Restart = "on-failure";
        RestartSec = 5;
      };
    }
  ) accessMcpPorts;
in
{
  options.moje.claude.accessMcpPort = lib.mkOption {
    type = lib.types.port;
    readOnly = true;
    default = accessMcpPorts.claude;
    description = "Port of the access-mcp instance for the claude account, for registering it in ~/.claude.json.";
  };

  config = {
    environment.systemPackages = [ accessMcpScript ];

    # Runs in Jacek's session - only there does kdialog/notify-send actually show anything.
    systemd.user.services = accessMcpServices;
  };
}
