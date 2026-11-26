# claude-share: general, root-owned mechanism to temporarily expose files from one configured
# account (`sourceAccounts`) to another (`allowedTargets`) — e.g. game_user's files
# (/mnt/games) to claude. claude-view/-edit/-copy/-revoke are convenience wrappers for the most
# common pair (Jacek -> claude). For other pairs call claude-share directly, through:
#   sudo -n "$(readlink -f "$(command -v claude-share)")" add view game_user claude /mnt/games/file 1h
# (sudo-rs matches the exact /nix/store path, not the bare name from PATH).
#
# Why a bind mount and not just an ACL: Jacek's home is 700 and that's what protects most files
# (which are individually 644). If claude got "traverse" (x) through /home/Jacek, it could read
# every 644 file in the home (e.g. ~/.config/gh/hosts.yml) — caught by the VM test
# (tests/vm.nix). So the shared object is bind-mounted into a common folder instead, and the
# home directory stays closed with no exceptions. The ACL on the source object itself is set by
# root (the source can be any configured account, not just Jacek — only root may change the ACL
# of a file it doesn't own).
{ lib, pkgs, ... }:
let
  sharedDir = "/home/wspolne/Shared"; # view/edit: bind mounts, cleared on boot
  forClientDir = "/home/wspolne/ForClient"; # copy: permanent copies, NOT cleared (delete by hand)
  mappingDir = "/run/claude-share"; # root-owned record of "who / which original", to drop the ACL on revoke

  # Accounts files may be taken FROM, and where each one may be read from.
  sourceAccounts = {
    Jacek = {
      uid = 1000;
      roots = [ "/home/Jacek" ];
      protected = [
        ".ssh"
        ".gnupg"
        ".local/share/kwalletd"
        ".local/share/keyrings"
        ".mozilla"
        ".thunderbird"
        ".config/Bitwarden"
        ".config/discord"
        ".config/gh"
        ".docker"
        ".config/remmina"
        ".local/share/remmina"
        ".config/sops"
        ".smbcredentials"
        ".config/chromium"
        ".config/Code/User/globalStorage"
        "homelab-ai"
      ];
    };
    game_user = {
      uid = 1002;
      roots = [
        "/home/game_user"
        "/mnt/games"
      ];
      protected = [ ];
    };
    zeroroot = {
      uid = 1003;
      roots = [ "/home/zeroroot" ];
      protected = [ ];
    };
  };
  # Accounts that may be given something (recipients).
  allowedTargets = [
    "claude"
    "game_user"
    "zeroroot"
  ];

  # Generates a bash `case` branch from `sourceAccounts`, setting uid/roots/protected variables.
  bashSourceAccounts = lib.concatMapStringsSep "\n" (
    name:
    let
      a = sourceAccounts.${name};
    in
    ''
      ${name})
        source_uid=${toString a.uid}
        source_roots="${lib.concatStringsSep ":" a.roots}"
        source_protected="${lib.concatStringsSep ":" a.protected}"
        ;;''
  ) (builtins.attrNames sourceAccounts);
  bashAllowedTargets = lib.concatStringsSep "|" allowedTargets;

  # Helper run as root (passwordless sudo for Jacek only, this one program only).
  # Does ONLY: ownership/protected-list checks, mount/copy, ACL, expiry.
  # Doesn't change file permissions beyond granting/revoking one ACL entry on the source object.
  #
  # Most of the logic lives in the plain, Nix-free ./claude-share.sh. This wrapper only
  # generates the two pieces that genuinely depend on Nix config data (source_info/target_ok,
  # derived from `sourceAccounts`/`allowedTargets` above) and passes the three paths as
  # environment variables, so claude-share.sh itself never needs any Nix templating.
  claudeShare = pkgs.writeShellApplication {
    name = "claude-share";
    runtimeInputs = with pkgs; [
      coreutils
      util-linux
      systemd
      acl
    ];
    text =
      ''
        export CLAUDE_SHARE_BASE="${sharedDir}"
        export CLAUDE_SHARE_FORCLIENT="${forClientDir}"
        export CLAUDE_SHARE_MAPPING="${mappingDir}"

        source_info() {
          case "$1" in
            ${bashSourceAccounts}
            *) echo "unknown source account: $1" >&2; return 1 ;;
          esac
        }

        target_ok() {
          case "$1" in
            ${bashAllowedTargets}) return 0 ;;
            *) return 1 ;;
          esac
        }

      ''
      + builtins.readFile ./claude-share.sh;
  };
  shareBin = "${claudeShare}/bin/claude-share";

  # --- Convenience wrappers for the most common case: Jacek -> claude ---

  claudeView = pkgs.writeShellApplication {
    name = "claude-view";
    runtimeInputs = with pkgs; [ coreutils ];
    text = ''
      duration="2h"
      while getopts "t:" opt; do
        case "$opt" in
          t) duration="$OPTARG" ;;
          *) echo "usage: claude-view PATH [-t DURATION]" >&2; exit 1 ;;
        esac
      done
      shift $((OPTIND - 1))
      [ "$#" -eq 1 ] || { echo "usage: claude-view PATH [-t DURATION]  (DURATION e.g. 30min, 2h, 1d; default 2h)" >&2; exit 1; }
      p="$(realpath -e -- "$1")" || { echo "does not exist: $1" >&2; exit 1; }
      target="$(sudo -n ${shareBin} add view Jacek claude "$p" "$duration")"
      echo "claude (read-only): $target (original: $p, expires in $duration)" >&2
      echo "$target"
    '';
  };

  claudeEdit = pkgs.writeShellApplication {
    name = "claude-edit";
    runtimeInputs = with pkgs; [ coreutils ];
    text = ''
      duration="2h"
      while getopts "t:" opt; do
        case "$opt" in
          t) duration="$OPTARG" ;;
          *) echo "usage: claude-edit PATH [-t DURATION]" >&2; exit 1 ;;
        esac
      done
      shift $((OPTIND - 1))
      [ "$#" -eq 1 ] || { echo "usage: claude-edit PATH [-t DURATION]  (DURATION e.g. 30min, 2h, 1d; default 2h)" >&2; exit 1; }
      p="$(realpath -e -- "$1")" || { echo "does not exist: $1" >&2; exit 1; }
      target="$(sudo -n ${shareBin} add edit Jacek claude "$p" "$duration")"
      echo "claude (WRITES to the original!): $target (original: $p, expires in $duration)" >&2
      echo "$target"
    '';
  };

  claudeCopy = pkgs.writeShellApplication {
    name = "claude-copy";
    runtimeInputs = with pkgs; [ coreutils ];
    text = ''
      [ "$#" -eq 1 ] || { echo "usage: claude-copy PATH" >&2; exit 1; }
      p="$(realpath -e -- "$1")" || { echo "does not exist: $1" >&2; exit 1; }
      target="$(sudo -n ${shareBin} add copy Jacek claude "$p")"
      echo "claude sees a copy (permanent, original untouched): $target" >&2
      echo "$target"
    '';
  };

  claudeRevoke = pkgs.writeShellApplication {
    name = "claude-revoke";
    runtimeInputs = with pkgs; [ coreutils ];
    text = ''
      if [ "$#" -eq 0 ]; then
        echo "Revoking ALL of claude's view/edit access (claude-copy copies stay)…"
        sudo -n ${shareBin} remove claude
        exit 0
      fi
      p="$(realpath -e -- "$1")" || { echo "does not exist: $1" >&2; exit 1; }
      found=0
      for target in ${sharedDir}/claude/*; do
        [ -e "$target" ] || continue
        if [ "$(stat -c %d:%i -- "$target" 2> /dev/null)" = "$(stat -c %d:%i -- "$p")" ]; then
          sudo -n ${shareBin} remove claude "$target"
          found=1
        fi
      done
      [ "$found" = 1 ] || echo "note: no active share found for $p (maybe it's a claude-copy copy?)" >&2
    '';
  };
in
{
  options.moje.claude.shareBin = lib.mkOption {
    type = lib.types.str;
    readOnly = true;
    description = "Absolute /nix/store path to claude-share, for the sudo-rs rule and the access-mcp server.";
  };

  config = {
    moje.claude.shareBin = shareBin;

    environment.systemPackages = [
      claudeShare
      claudeView
      claudeEdit
      claudeCopy
      claudeRevoke
    ];

    # "D": contents are wiped on boot - mounts are gone after a restart anyway, and empty mount
    # points would reveal the names of previously shared files (caught by the VM test).
    # ForClient (claude-copy copies) is NOT cleared - those are permanent, delete by hand.
    systemd.tmpfiles.rules = [
      "D ${sharedDir} 2750 root wspolne -"
      "d ${forClientDir} 2750 root wspolne -"
    ];
  };
}
