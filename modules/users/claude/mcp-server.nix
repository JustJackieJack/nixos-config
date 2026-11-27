# access-mcp: lets claude ask for temporary access to a file and have Jacek approve it with a
# kdialog window, instead of Jacek having to run claude-view/-edit/-copy by hand.
#
# ONLY claude gets an instance. This was briefly generalized to "one instance per target
# account" (game_user, zeroroot too) during the module-split refactor, but that was dead AND
# actively risky: nothing ever registered those ports in game_user's/zeroroot's own
# ~/.claude.json (no Claude agent runs as those accounts - they're a game launcher and a
# quarantine, not AI sessions), yet the listening port itself was still reachable. zeroroot's
# nftables rule blocks it from ALL network including loopback (harmless in practice), but
# game_user has normal network and OpenSnitch unconditionally allows ALL loopback traffic
# (rule 005-localhost, to avoid DNS friction) - so any untrusted process running as game_user
# (a Steam game, a mod, a Heroic plugin) could reach 127.0.0.1:8766 and call request_access
# itself, popping a kdialog approval prompt in Jacek's own session asking him to share one of
# his files. That's exactly the social-engineering path the claude-only design was meant to
# rule out - removed instead of "fixed", since there was never a real need for it.
#
# The actual server logic lives in ./access-mcp.py as plain Python (no Nix syntax inside it) -
# this file only wires up the absolute /nix/store paths it needs, as environment variables, so
# the Python stays readable/lintable/testable on its own.
{ config, lib, pkgs, ... }:
let
  accessMcpPorts = {
    claude = 8765;
  };

  accessMcpPython = pkgs.python3.withPackages (ps: [ ps.mcp ]);

  # request_command (claude only - see below): lets claude ask to run a shell command AS one of
  # the already-sandboxed, already-low-privilege accounts - never as root or Jacek, since this
  # path is a single kdialog click, not something that should be able to escalate fully. The
  # wrapper below does nothing but exec its argv - unlike claude-share.sh, there's no second
  # validation layer possible after sudo (the command can be anything, by design), so the
  # allowlist check in access-mcp.py (BEFORE calling sudo) and Jacek actually reading the command
  # text in the kdialog prompt are the WHOLE protection here.
  claudeRunCommand = pkgs.writeShellApplication {
    name = "claude-run-command";
    text = ''exec "$@"'';
  };
  # access-mcp.py runs the requested command via `claude-run-command -- sh -c <command>` - a bare
  # "sh" there relies on PATH, which sudo resets before claude-run-command ever starts, so every
  # request_command call failed with "exec: sh: not found" (exit 127) regardless of as_user -
  # caught by live use through claude-session, not by the VM test (which called claude-run-command
  # directly, without going through sh -c, so it never exercised this path). Fixed by giving
  # access-mcp.py an absolute, PATH-independent shell path instead.
  shForRunCommand = "${pkgs.bash}/bin/bash";
  allowedCommandTargets = [
    "game_user"
    "zeroroot"
    "dev_user"
  ];

  accessMcpScript = pkgs.writeShellApplication {
    name = "access-mcp";
    text = ''
      export SUDO=/run/wrappers/bin/sudo
      export SHARE_BIN=${config.moje.claude.shareBin}
      export RUN_COMMAND_BIN=${claudeRunCommand}/bin/claude-run-command
      export SH=${shForRunCommand}
      export ALLOWED_COMMAND_TARGETS=${lib.concatStringsSep "," allowedCommandTargets}
      export ALLOWED_SOURCE_ACCOUNTS=${lib.concatStringsSep "," config.moje.claude.shareSourceAccounts}
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
        # request_command (--allow-commands) only for claude - the only entry in accessMcpPorts
        # today, but kept as a real check (not hardcoded) in case a second, legitimate instance
        # is ever added back.
        ExecStart =
          "${accessMcpScript}/bin/access-mcp --target-user ${targetUser} --port ${toString port}"
          + lib.optionalString (targetUser == "claude") " --allow-commands";
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
    environment.systemPackages = [
      accessMcpScript
      claudeRunCommand
    ];

    # Runs in Jacek's session - only there does kdialog/notify-send actually show anything.
    systemd.user.services = accessMcpServices;

    # Lets Jacek (and ONLY Jacek, via access-mcp's kdialog gate) run claude-run-command as any
    # user, including root - sudo-rs's `runAs` is just a string spliced into sudoers' `(...)`,
    # and "ALL" is its own documented default meaning "any user/group". The real restriction
    # (never root, never Jacek) lives in access-mcp.py's allowlist check, not here.
    security.sudo-rs.extraRules = [
      {
        users = [ "Jacek" ];
        # Explicit list, not "ALL"/"ALL:ALL" - a wildcard runas here collided with the existing
        # `%wheel ALL=(ALL:ALL) SETENV: ALL` default rule (Jacek is in wheel) and sudo-rs picked
        # the wheel rule's PASSWD requirement over this NOPASSWD one despite this entry coming
        # later in the file - "interactive authentication is required" even with `-n`. An
        # explicit, closed list sidesteps whatever priority rule caused that and is also just
        # the better match for intent: root is included here (sudo-rs's own layer stays
        # permissive) but access-mcp.py's allowlist is still the thing that actually keeps
        # `as_user` away from root/Jacek in practice.
        runAs = "root,game_user,zeroroot,dev_user";
        commands = [
          {
            command = "${claudeRunCommand}/bin/claude-run-command";
            options = [ "NOPASSWD" ];
          }
        ];
      }
    ];
  };
}
