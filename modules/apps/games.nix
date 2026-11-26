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

  # trybEgo: "--machinectl" (domyślnie, z xdg-desktop-portal) albo "--machinectl-bare" (bez
  # portalu - patrz Heroic niżej: z portalem powiadomienia D-Bus (libnotify) nie miały komu
  # odpowiedzieć i blokowały UI na ~25s przy każdej próbie pokazania powiadomienia, co wyglądało
  # jak losowe zawieszenia bez restartu aplikacji. Bez portalu wołanie dostaje błąd od razu.
  jakoGameUser =
    nazwa: polecenie: ikona: trybEgo:
    pkgs.makeDesktopItem {
      name = "${nazwa}-game-user";
      desktopName = "${nazwa} (game_user)";
      exec = "${pkgs.ego}/bin/ego ${trybEgo} --user=game_user ${polecenie}";
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
    (jakoGameUser "Steam" "steam" "steam" "--machinectl")
    # --ozone-platform=x11: Heroic (Electron) zawieszało samo okno (nie cały pulpit) losowo na
    # NVIDIA + natywny Wayland Ozone - znany problem stabilności Electrona na Wayland/NVIDIA.
    # Wymuszenie XWayland naprawia to bez utraty funkcji.
    # --machinectl (nie -bare): próbowaliśmy -bare licząc że to naprawi zawieszenia od D-Bus,
    # ale to nie miało znaczenia (prawdziwa przyczyna niżej, usluga-powiadomien-game-user) -
    # bare kosztowałoby utratę xdg-desktop-portal (np. natywne okna wyboru plików).
    (jakoGameUser "Heroic" "heroic --ozone-platform=x11" "com.heroicgameslauncher.hgl" "--machinectl")
  ];

  systemd.tmpfiles.rules = [
    # 0700: grupa users to wszystkie zwykłe konta (także zeroroot i claude)
    "d /mnt/games 0700 game_user users -"
    "d /mnt/games/SteamLibrary 0700 game_user users -"
    "d /mnt/games/Heroic 0700 game_user users -"
  ];

  # Sesja game_user ma zarejestrowaną usługę D-Bus dla powiadomień
  # (org.kde.plasma.Notifications.service), ale plasmashell (prawdziwa obsługa) w tej minimalnej
  # sesji nigdy nie startuje - więc KAŻDA próba Heroica/Steama pokazania powiadomienia (np. przy
  # pobieraniu/instalacji) wisi ~25s na timeout D-Bus, i powtarza się tak długo, jak trwa dana
  # czynność - wygląda jak ciągłe losowe zawieszenia UI. Lekki demon poniżej odpowiada na
  # wywołanie od razu, więc nic nie czeka na timeout.
  systemd.user.services.dunst-game-user = {
    description = "Lekki demon powiadomień dla sesji game_user (naprawia zawieszenia Heroic/Steam od D-Bus)";
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    unitConfig.ConditionUser = "game_user";
    serviceConfig = {
      ExecStart = "${pkgs.dunst}/bin/dunst";
      Restart = "on-failure";
      RestartSec = 2;
    };
  };
}
