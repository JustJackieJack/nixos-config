# Gry: Steam i Heroic działają jako game_user (ego), biblioteki na /mnt/games (Lexar).
# programs.steam to NIE jest piaskownica – izolację daje osobne konto.
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
  # w menu zostają tylko wersje „(game_user)”.
  ukryjSkroty = lib.hiPrio (
    pkgs.runCommand "ukryj-skroty-gier" { } ''
      mkdir -p $out/share/applications
      for n in steam.desktop com.heroicgameslauncher.hgl.desktop; do
        printf '[Desktop Entry]\nType=Application\nName=%s\nNoDisplay=true\nHidden=true\n' "$n" \
          > "$out/share/applications/$n"
      done
    ''
  );

  jakoGameUser =
    nazwa: polecenie: ikona:
    pkgs.makeDesktopItem {
      name = "${nazwa}-game-user";
      desktopName = "${nazwa} (game_user)";
      exec = "${pkgs.ego}/bin/ego --machinectl --user=game_user ${polecenie}";
      icon = ikona;
      categories = [ "Game" ];
    };
in
{
  programs.steam = {
    enable = true;
    extraCompatPackages = [ pkgs.proton-ge-bin ];
    protontricks.enable = true;
    remotePlay.openFirewall = false;
    localNetworkGameTransfers.openFirewall = false;
  };

  # „Osobne okno” dla gier (obowiązkowe w zeroroot, opcjonalne tutaj): gamescope -W 1920 -H 1080 -- %command%
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
    (jakoGameUser "Steam" "steam" "steam")
    (jakoGameUser "Heroic" "heroic" "com.heroicgameslauncher.hgl")
  ];

  systemd.tmpfiles.rules = [
    # 0700: grupa users to wszystkie zwykłe konta (także zeroroot i claude)
    "d /mnt/games 0700 game_user users -"
    "d /mnt/games/SteamLibrary 0700 game_user users -"
    "d /mnt/games/Heroic 0700 game_user users -"
  ];
}
