# Szablon "zerotrust": kwarantanna dla podejrzanych programów. Wołany z konta.nix, raz per
# instancja (dziś tylko zeroroot).
#  1. BEZ SIECI: nftables odrzuca każdy pakiet tego UID (+ reguła w OpenSnitch),
#  2. gamescope: program dostaje jedno okno, nie widzi reszty pulpitu,
#  3. bubblewrap: system tylko do odczytu, zapis tylko w domu tego konta i w folderze wymiany,
#  4. ClamAV skanuje folder wymiany i dom tego konta przy każdym dostępie (monitoring.nix - trzeba
#     dopisać ścieżkę ręcznie, jeśli dojdzie druga instancja - to nie jest tu generowane).
#
# Folder wymiany (/srv/<nazwa>-exchange) wywodzi się z nazwy konta automatycznie, z WŁASNĄ grupą
# per instancja (<nazwa>-exchange) - konto i (jeśli podany) `rodzic` są jedynymi jej członkami, więc
# dwie różne instancje tego szablonu NIE widzą nawzajem swoich folderów wymiany.
#
# Użycie: wrzuć plik do folderu wymiany, potem: <nazwa>-run program (np. wine setup.exe)
{ nazwa, rodzic ? null, ... }:
{ config, pkgs, lib, ... }:
let
  uid = toString config.users.users.${nazwa}.uid;
  wymiana = "/srv/${nazwa}-exchange";
  grupaWymiany = "${nazwa}-exchange";

  wnetrze = pkgs.writeShellApplication {
    name = "${nazwa}-inside";
    runtimeInputs = [ pkgs.bubblewrap ];
    text = ''
      nr="''${DISPLAY#*:}"
      nr="''${nr%%.*}"
      x="/tmp/.X11-unix/X$nr"
      [ -S "$x" ] || { echo "${nazwa}: brak gniazda X gamescope ($x)" >&2; exit 1; }
      gpu=()
      for d in /dev/dri /dev/nvidia*; do
        [ -e "$d" ] && gpu+=(--dev-bind "$d" "$d")
      done
      exec bwrap \
        --ro-bind / / \
        --dev /dev \
        "''${gpu[@]}" \
        --proc /proc \
        --tmpfs /tmp \
        --ro-bind "$x" "$x" \
        --perms 0700 --dir /tmp/run \
        --setenv XDG_RUNTIME_DIR /tmp/run \
        --tmpfs /run/user \
        --bind /home/${nazwa} /home/${nazwa} \
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

  uruchom = pkgs.writeShellApplication {
    name = "${nazwa}-run";
    runtimeInputs = [ pkgs.ego ];
    text = ''
      [ "$#" -ge 1 ] || { echo "użycie: ${nazwa}-run PROGRAM [ARGUMENTY…]" >&2; exit 1; }
      exec ego --machinectl --user=${nazwa} -- \
        ${pkgs.gamescope}/bin/gamescope -W 1600 -H 900 -- \
        ${wnetrze}/bin/${nazwa}-inside "$@"
    '';
  };
in
{
  users.groups.${grupaWymiany} = { };

  users.users = {
    ${nazwa}.extraGroups = [
      "video"
      "render"
      grupaWymiany
    ];
  } // lib.optionalAttrs (rodzic != null) {
    ${rodzic}.extraGroups = [ grupaWymiany ];
  };

  networking.nftables.tables.${nazwa} = {
    family = "inet";
    content = ''
      chain output {
        type filter hook output priority filter; policy accept;
        meta skuid ${uid} limit rate 5/minute log prefix "${nazwa}-blokada: "
        meta skuid ${uid} reject
      }
    '';
  };

  environment.systemPackages = [
    uruchom
    pkgs.bubblewrap
  ];

  systemd.tmpfiles.rules = [
    "d ${wymiana} 2770 ${nazwa} ${grupaWymiany} -"
    "a+ ${wymiana} - - - - default:group:${grupaWymiany}:rwx,group:${grupaWymiany}:rwx"
  ];
}
