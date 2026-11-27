# Gry: Steam i Heroic działają na osobnych kontach (ego), nie jako Jacek.
# programs.steam to NIE jest piaskownica – izolację daje osobne konto (patrz
# modules/users/szablony/gry.nix - tam jest sama logika konta/launchera/tmpfiles, tutaj tylko
# globalne włączenia i pakiety, niezależne od tego, ile jest instancji tego szablonu).
{
  lib,
  pkgs,
  inputs,
  ...
}:
let
  # heroic ze stabilnego nixpkgs (26.05) miał błąd logowania do GOG (Cloudflare blokował
  # niestandardowy User-Agent) – naprawione w 2.22.4, czego 26.05 jeszcze nie ma. Tylko ten
  # jeden pakiet bierzemy z nixpkgs-unstable, reszta systemu zostaje na stabilnej gałęzi.
  pkgsUnstable = import inputs.nixpkgs-unstable { inherit (pkgs) system; };
  # Zwykłe skróty Steama i Heroica uruchamiałyby je jako Jacek – chowamy je,
  # w menu zostają tylko wersje wygenerowane per-konto przez szablon "gry".
  ukryjSkroty = lib.hiPrio (
    pkgs.runCommand "ukryj-skroty-gier" { } ''
      mkdir -p $out/share/applications
      for n in steam.desktop com.heroicgameslauncher.hgl.desktop; do
        printf '[Desktop Entry]\nType=Application\nName=%s\nNoDisplay=true\nHidden=true\n' "$n" \
          > "$out/share/applications/$n"
      done
    ''
  );
in
{
  programs.steam = {
    enable = true;
    extraCompatPackages = [ pkgs.proton-ge-bin ];
    protontricks.enable = true;
    remotePlay.openFirewall = false;
    localNetworkGameTransfers.openFirewall = false;
  };

  # „Osobne okno” dla gier (obowiązkowe w zerotrust, opcjonalne tutaj): gamescope -W 1920 -H 1080 -- %command%
  programs.gamescope.enable = true;
  # W opcjach uruchamiania gry w Steam: gamemoderun %command%
  programs.gamemode.enable = true;

  environment.systemPackages = with pkgs; [
    ego
    pkgsUnstable.heroic
    prismlauncher # Minecraft – jako Jacek (buildy modów)
    wineWow64Packages.stable
    winetricks
    mangohud
    ukryjSkroty
  ];
}
