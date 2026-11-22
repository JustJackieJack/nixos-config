# Układ dysków. UWAGA: uruchomienie disko (instalacja) KASUJE oba dyski poniżej.
# Samsung 860 SATA (ata-Samsung_SSD_860_EVO_250GB_S3YJNX0K607461V) celowo pominięty – zostaje pusty.
#
# Zasada: na dysku systemowym JEDEN btrfs. Podwoluminy dzielą wolne miejsce,
# więc /home nie zapcha się, gdy system ma wolne (problem z Fedory).
let
  btrfsOpcje = [
    "compress=zstd:1"
    "noatime"
  ];
in
{
  disko.devices.disk = {
    # Samsung 980 PRO 1 TB – system + /home, szyfrowany (LUKS2, YubiKey FIDO2 + PIN).
    system = {
      type = "disk";
      device = "/dev/disk/by-id/nvme-Samsung_SSD_980_PRO_1TB_S5GXNU0WC34243K";
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            size = "1G";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
              mountOptions = [ "umask=0077" ];
            };
          };
          luks = {
            size = "100%";
            content = {
              type = "luks";
              name = "cryptroot";
              # Hasło podawane przy instalacji = klucz awaryjny (zapisać w Bitwardenie).
              # YubiKeye dopisuje się po instalacji: systemd-cryptenroll --fido2-device=auto --fido2-with-client-pin=yes
              settings = {
                allowDiscards = true;
                crypttabExtraOpts = [
                  "fido2-device=auto"
                  "token-timeout=20"
                ];
              };
              content = {
                type = "btrfs";
                extraArgs = [
                  "-f"
                  "-L"
                  "nixos"
                ];
                subvolumes = {
                  "@" = {
                    mountpoint = "/";
                    mountOptions = btrfsOpcje;
                  };
                  "@home" = {
                    mountpoint = "/home";
                    mountOptions = btrfsOpcje;
                  };
                  # Snapshoty /home (snapper) – osobny podwolumin, żeby nie wchodziły same w siebie.
                  "@home-snapshots" = {
                    mountpoint = "/home/.snapshots";
                    mountOptions = btrfsOpcje;
                  };
                  # Dom game_usera osobno: nie trafia do snapshotów /home (cache shaderów, Proton).
                  "@game_user" = {
                    mountpoint = "/home/game_user";
                    mountOptions = btrfsOpcje;
                  };
                  "@nix" = {
                    mountpoint = "/nix";
                    mountOptions = btrfsOpcje;
                  };
                  "@log" = {
                    mountpoint = "/var/log";
                    mountOptions = btrfsOpcje;
                  };
                };
              };
            };
          };
        };
      };
    };

    # Lexar NM620 1 TB – gry, ext4, bez szyfrowania. Właściciel: game_user.
    gry = {
      type = "disk";
      device = "/dev/disk/by-id/nvme-Lexar_SSD_NM620_1TB_MM13022007393P1110";
      content = {
        type = "gpt";
        partitions.gry = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            extraArgs = [
              "-L"
              "games"
            ];
            mountpoint = "/mnt/games";
            mountOptions = [
              "noatime"
              "nofail"
            ];
          };
        };
      };
    };
  };
}
