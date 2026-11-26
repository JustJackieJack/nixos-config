# The `claude` account: Claude Code runs under its own, separate Linux user.
# Protection: claude has NO access to Jacek's secrets (SSH/GPG keys, KWallet, Bitwarden,
# browser). It has full network access (opensnitch.nix).
#
# Commands for Jacek:
#   claude-session [args]          - run Claude Code as claude in the current directory
#   claude-home                    - interactive shell as claude (~/.ssh, ~/.claude, skills setup)
#   claude-view PATH [-t DURATION]  - claude sees the REAL file, read-only, expires on its own
#   claude-edit PATH [-t DURATION]  - same, but claude can also write (change hits the original!)
#   claude-copy PATH                - claude gets a PERMANENT COPY (edits don't touch the original)
#   claude-revoke [PATH]            - revoke view/edit access immediately (no path: all; copies untouched)
#   claude-share                    - the general mechanism underneath (any account pair, see sharing.nix)
#   access-mcp                      - MCP server letting claude ask for access itself (see mcp-server.nix)
#   Chromium (claude) in the menu   - browser for Claude in Chrome
{ config, lib, pkgs, ... }:
let
  claudeHome = pkgs.writeShellApplication {
    name = "claude-home";
    text = ''exec sudo -u claude -i -- "$@"'';
  };

  claudeSession = pkgs.writeShellApplication {
    name = "claude-session";
    text = ''
      # Claude starts in the current directory - it must be somewhere it can access
      # (/home/wspolne/...).
      exec sudo -u claude -- ${pkgs.claude-code}/bin/claude "$@"
    '';
  };

  chromiumClaude = pkgs.makeDesktopItem {
    name = "chromium-claude";
    desktopName = "Chromium (claude)";
    comment = "Browser for the claude account - Claude in Chrome";
    exec = "${pkgs.ego}/bin/ego --machinectl --user=claude chromium";
    icon = "chromium";
    categories = [ "Network" ];
  };
  # Chromium is ONLY for claude - hide the regular shortcut (which would launch as Jacek).
  hideChromium = lib.hiPrio (
    pkgs.runCommand "hide-chromium" { } ''
      mkdir -p $out/share/applications
      printf '[Desktop Entry]\nType=Application\nName=Chromium\nNoDisplay=true\nHidden=true\n' \
        > $out/share/applications/chromium-browser.desktop
    ''
  );
in
{
  imports = [
    ./sharing.nix
    ./mcp-server.nix
    ./instructions.nix
    ./admin-access.nix
  ];

  environment.systemPackages = [
    pkgs.claude-code
    pkgs.chromium
    hideChromium
    claudeSession
    claudeHome
    chromiumClaude
  ];

  security.sudo-rs.extraRules = [
    # Jacek may run commands as claude without a password (and only as claude).
    {
      users = [ "Jacek" ];
      runAs = "claude";
      commands = [
        {
          command = "ALL";
          options = [ "NOPASSWD" ];
        }
      ];
    }
    # ...and the sharing helper as root - only this one program.
    {
      users = [ "Jacek" ];
      runAs = "root";
      commands = [
        {
          command = config.moje.claude.shareBin;
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];
}
