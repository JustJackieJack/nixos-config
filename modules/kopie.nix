# Kopie:
#   snapper – lokalne snapshoty /home (24 godzinne + 7 dziennych, starsze kasowane same),
#   restic  – codzienna kopia na NAS (Jacek, claude, wspólne) – włącza się, gdy są sekrety,
#   NAS     – udział Modele_3D montowany na żądanie.
# Syncthing: TODO (ustalone na później).
{ config, lib, ... }:
let
  sekrety = config.moje.sekrety.gotowe;
in
{
  config = lib.mkMerge [
    {
      services.snapper.configs.home = {
        SUBVOLUME = "/home";
        ALLOW_USERS = [ "Jacek" ];
        TIMELINE_CREATE = true;
        TIMELINE_CLEANUP = true;
        TIMELINE_LIMIT_HOURLY = 24;
        TIMELINE_LIMIT_DAILY = 7;
        TIMELINE_LIMIT_WEEKLY = 0;
        TIMELINE_LIMIT_MONTHLY = 0;
        TIMELINE_LIMIT_YEARLY = 0;
      };
    }

    (lib.mkIf sekrety {
      sops = {
        defaultSopsFile = config.moje.sekrety.plik;
        age.keyFile = "/var/lib/sops-nix/key.txt";
        secrets = {
          "restic/repo" = { }; # np. sftp:kopie@NAS:/restic/justjackpc albo rest:http://…
          "restic/haslo" = { };
          "nas/modele" = { }; # zawartość jak ~/.smbcredentials-modele (username=… password=…)
        };
      };

      services.restic.backups.nas = {
        repositoryFile = config.sops.secrets."restic/repo".path;
        passwordFile = config.sops.secrets."restic/haslo".path;
        initialize = true;
        paths = [
          "/home/Jacek"
          "/home/claude" # cała pamięć i ustawienia Claude
          "/home/wspolne"
        ];
        exclude = [
          "/home/*/.cache"
          "/home/Jacek/.local/share/Trash"
          "/home/Jacek/.local/share/baloo"
          "**/node_modules"
          "**/.direnv"
          "**/target"
          "/home/wspolne/Udostepnione" # podmontowane pliki Jacka (są już w /home/Jacek)
        ];
        extraBackupArgs = [ "--exclude-caches" ];
        timerConfig = {
          OnCalendar = "daily";
          Persistent = true;
          RandomizedDelaySec = "1h";
        };
        pruneOpts = [
          "--keep-daily 7"
          "--keep-weekly 4"
          "--keep-monthly 6"
        ];
      };

      fileSystems."/mnt/nas/Modele_3D" = {
        device = "//10.0.190.5/Modele_3D";
        fsType = "cifs";
        options = [
          "credentials=${config.sops.secrets."nas/modele".path}"
          "uid=1000"
          "gid=100"
          "file_mode=0660"
          "dir_mode=0770"
          "iocharset=utf8"
          "vers=3.0"
          "serverino"
          "nosharesock"
          "nofail"
          "_netdev"
          "noauto"
          "x-systemd.automount"
          "x-systemd.device-timeout=10s"
          "x-systemd.idle-timeout=5min"
        ];
      };
    })
  ];
}
