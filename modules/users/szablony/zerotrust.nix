# Szablon "zerotrust": kwarantanna dla podejrzanych programów. Wołany z konta.nix, raz per
# instancja (dziś tylko zeroroot).
#  1. BEZ SIECI: nftables odrzuca każdy pakiet tego UID (+ reguła w OpenSnitch),
#  2. gamescope: program dostaje jedno okno, nie widzi reszty pulpitu,
#  3. bubblewrap: system tylko do odczytu, zapis tylko w domu tego konta i w folderze wymiany,
#  4. ClamAV skanuje folder wymiany i dom tego konta przy każdym dostępie (monitoring.nix - trzeba
#     dopisać ścieżkę ręcznie, jeśli dojdzie druga instancja - to nie jest tu generowane).
#
# Folder wymiany (/srv/<name>-exchange) wywodzi się z nazwy konta automatycznie, z WŁASNĄ grupą
# per instancja (<name>-exchange) - konto i (jeśli podany) `parent` są jedynymi jej członkami, więc
# dwie różne instancje tego szablonu NIE widzą nawzajem swoich folderów wymiany.
#
# Użycie: wrzuć plik do folderu wymiany, potem: <name>-run program (np. wine setup.exe)
{ name, parent ? null, ... }:
{ config, pkgs, lib, ... }:
let
  uid = toString config.users.users.${name}.uid;
  exchangeDir = "/srv/${name}-exchange";
  exchangeGroup = "${name}-exchange";

  insideWrapper = pkgs.writeShellApplication {
    name = "${name}-inside";
    runtimeInputs = [ pkgs.bubblewrap ];
    text = ''
      nr="''${DISPLAY#*:}"
      nr="''${nr%%.*}"
      x="/tmp/.X11-unix/X$nr"
      [ -S "$x" ] || { echo "${name}: brak gniazda X gamescope ($x)" >&2; exit 1; }
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
        --bind /home/${name} /home/${name} \
        --bind ${exchangeDir} ${exchangeDir} \
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

  runWrapper = pkgs.writeShellApplication {
    name = "${name}-run";
    runtimeInputs = [ pkgs.ego ];
    text = ''
      [ "$#" -ge 1 ] || { echo "użycie: ${name}-run PROGRAM [ARGUMENTY…]" >&2; exit 1; }
      exec ego --machinectl --user=${name} -- \
        ${pkgs.gamescope}/bin/gamescope -W 1600 -H 900 -- \
        ${insideWrapper}/bin/${name}-inside "$@"
    '';
  };
in
{
  users.groups.${exchangeGroup} = { };

  users.users = {
    ${name}.extraGroups = [
      "video"
      "render"
      exchangeGroup
    ];
  } // lib.optionalAttrs (parent != null) {
    ${parent}.extraGroups = [ exchangeGroup ];
  };

  networking.nftables.tables.${name} = {
    family = "inet";
    content = ''
      chain output {
        type filter hook output priority filter; policy accept;
        meta skuid ${uid} limit rate 5/minute log prefix "${name}-blokada: "
        meta skuid ${uid} reject
      }
    '';
  };

  environment.systemPackages = [
    runWrapper
    pkgs.bubblewrap
  ];

  systemd.tmpfiles.rules = [
    "d ${exchangeDir} 2770 ${name} ${exchangeGroup} -"
    "a+ ${exchangeDir} - - - - default:group:${exchangeGroup}:rwx,group:${exchangeGroup}:rwx"
  ];
}
