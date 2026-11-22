# zeroroot – kwarantanna dla podejrzanych programów.
#  1. osobne konto (nie widzi domu Jacka ani /home/wspolne),
#  2. BEZ SIECI: nftables odrzuca każdy pakiet tego UID (+ reguła w OpenSnitch),
#  3. gamescope: program dostaje jedno okno, nie widzi reszty pulpitu,
#  4. bubblewrap: system tylko do odczytu, zapis tylko w domu zeroroota i w folderze wymiany,
#  5. ClamAV skanuje folder wymiany i dom zeroroota przy każdym dostępie (monitoring.nix).
#
# Użycie: wrzuć plik do /srv/zeroroot-wymiana, potem: zeroroot-uruchom /srv/zeroroot-wymiana/program
# (np. zeroroot-uruchom wine /srv/zeroroot-wymiana/setup.exe)
{ config, pkgs, ... }:
let
  uid = toString config.users.users.zeroroot.uid;
  wymiana = "/srv/zeroroot-wymiana";

  # Wewnątrz gamescope (jako zeroroot). ego daje zerorootowi dostęp do Wayland, X11 i dźwięku
  # Jacka – to potrzebne tylko samemu gamescope. Program w piaskownicy widzi WYŁĄCZNIE ekran
  # gamescope: /tmp i /run/user są puste, z powrotem podpinamy tylko gniazdo X gamescope.
  # Skutek: brak dźwięku i mikrofonu, brak podglądu okien i klawiatury Jacka.
  zerorootWnetrze = pkgs.writeShellApplication {
    name = "zeroroot-wnetrze";
    runtimeInputs = [ pkgs.bubblewrap ];
    text = ''
      nr="''${DISPLAY#*:}"
      nr="''${nr%%.*}"
      x="/tmp/.X11-unix/X$nr"
      [ -S "$x" ] || { echo "zeroroot: brak gniazda X gamescope ($x)" >&2; exit 1; }
      exec bwrap \
        --ro-bind / / \
        --dev /dev \
        --proc /proc \
        --tmpfs /tmp \
        --ro-bind "$x" "$x" \
        --tmpfs /run/user \
        --bind /home/zeroroot /home/zeroroot \
        --bind ${wymiana} ${wymiana} \
        --unsetenv WAYLAND_DISPLAY \
        --unsetenv PULSE_SERVER \
        --unsetenv DBUS_SESSION_BUS_ADDRESS \
        --unshare-net \
        --unshare-pid \
        --unshare-ipc \
        --die-with-parent \
        --new-session \
        -- "$@"
    '';
  };

  zerorootUruchom = pkgs.writeShellApplication {
    name = "zeroroot-uruchom";
    runtimeInputs = [ pkgs.ego ];
    text = ''
      [ "$#" -ge 1 ] || { echo "użycie: zeroroot-uruchom PROGRAM [ARGUMENTY…]" >&2; exit 1; }
      exec ego --machinectl --user=zeroroot -- \
        ${pkgs.gamescope}/bin/gamescope -W 1600 -H 900 -- \
        ${zerorootWnetrze}/bin/zeroroot-wnetrze "$@"
    '';
  };
in
{
  # Każdy pakiet wychodzący od zeroroota (także do localhost) – odrzucony i zalogowany.
  networking.nftables.tables.zeroroot = {
    family = "inet";
    content = ''
      chain output {
        type filter hook output priority filter; policy accept;
        meta skuid ${uid} limit rate 5/minute log prefix "zeroroot-blokada: "
        meta skuid ${uid} reject
      }
    '';
  };

  environment.systemPackages = [
    zerorootUruchom
    pkgs.bubblewrap
  ];

  systemd.tmpfiles.rules = [
    "d ${wymiana} 2770 zeroroot zeroroot-wymiana -"
    "a+ ${wymiana} - - - - default:group:zeroroot-wymiana:rwx,group:zeroroot-wymiana:rwx"
  ];
}
