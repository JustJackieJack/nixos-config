# Szablon "gry": Steam/Heroic na osobnym koncie, odpalane przez ego. Wołany z konta.nix, raz per
# instancja (dziś tylko game_user; w przyszłości np. dziecko-games).
# biblioteka: gdzie trzymać SteamLibrary/Heroic - domyślnie katalog domowy konta, ale /mnt/games
# jest konkretną, fizyczną partycją (nie czymś wywodzącym się z nazwy konta), więc istniejąca
# instancja (game_user) podaje ją jawnie w konta.nix, żeby zachować dzisiejsze zachowanie 1:1.
{
  nazwa,
  biblioteka ? "/home/${nazwa}",
  ...
}:
{ pkgs, ... }:
{
  users.users.${nazwa}.extraGroups = [
    "video"
    "render"
  ];

  environment.systemPackages = [
    (pkgs.makeDesktopItem {
      name = "${nazwa}-steam";
      desktopName = "Steam (${nazwa})";
      exec = "${pkgs.ego}/bin/ego --machinectl --user=${nazwa} steam";
      icon = "steam";
      categories = [ "Game" ];
    })
    # --ozone-platform=x11: Heroic (Electron) zawieszało samo okno losowo na NVIDIA + natywny
    # Wayland Ozone - wymuszenie XWayland naprawia to bez utraty funkcji (patrz historia commitów
    # dla game_user - ten sam fix, teraz część szablonu, nie jednorazowej łatki).
    (pkgs.makeDesktopItem {
      name = "${nazwa}-heroic";
      desktopName = "Heroic (${nazwa})";
      exec = "${pkgs.ego}/bin/ego --machinectl --user=${nazwa} heroic --ozone-platform=x11";
      icon = "com.heroicgameslauncher.hgl";
      categories = [ "Game" ];
    })
  ];

  systemd.tmpfiles.rules = [
    # 0700: grupa users to wszystkie zwykłe konta - nie mają tu wstępu.
    "d ${biblioteka} 0700 ${nazwa} users -"
    "d ${biblioteka}/SteamLibrary 0700 ${nazwa} users -"
    "d ${biblioteka}/Heroic 0700 ${nazwa} users -"
  ];

  # Sesja tego konta ma zarejestrowaną usługę D-Bus dla powiadomień, ale żaden pełny plasmashell w
  # tej minimalnej sesji nigdy nie startuje - więc każda próba Heroica/Steama pokazania
  # powiadomienia wisi ~25s na timeout D-Bus (wygląda jak losowe zawieszenie UI). Ten lekki demon
  # odpowiada na wywołanie od razu.
  systemd.user.services."dunst-${nazwa}" = {
    description = "Lekki demon powiadomień dla sesji ${nazwa} (naprawia zawieszenia Heroic/Steam od D-Bus)";
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    unitConfig.ConditionUser = nazwa;
    serviceConfig = {
      ExecStart = "${pkgs.dunst}/bin/dunst";
      Restart = "on-failure";
      RestartSec = 2;
    };
  };
}
