# Szablon "gry": Steam/Heroic na osobnym koncie, odpalane przez ego. Wołany z konta.nix, raz per
# instancja (dziś tylko game_user; w przyszłości np. dziecko-games).
# library: gdzie trzymać SteamLibrary/Heroic - domyślnie katalog domowy konta, ale /mnt/games
# jest konkretną, fizyczną partycją (nie czymś wywodzącym się z nazwy konta), więc istniejąca
# instancja (game_user) podaje ją jawnie w konta.nix, żeby zachować dzisiejsze zachowanie 1:1.
{
  name,
  library ? "/home/${name}",
  ...
}:
{ pkgs, ... }:
{
  users.users.${name}.extraGroups = [
    "video"
    "render"
  ];

  environment.systemPackages = [
    (pkgs.makeDesktopItem {
      name = "${name}-steam";
      desktopName = "Steam (${name})";
      exec = "${pkgs.ego}/bin/ego --machinectl --user=${name} steam";
      icon = "steam";
      categories = [ "Game" ];
    })
    # --ozone-platform=x11: Heroic (Electron) zawieszało samo okno losowo na NVIDIA + natywny
    # Wayland Ozone - wymuszenie XWayland naprawia to bez utraty funkcji (patrz historia commitów
    # dla game_user - ten sam fix, teraz część szablonu, nie jednorazowej łatki).
    (pkgs.makeDesktopItem {
      name = "${name}-heroic";
      desktopName = "Heroic (${name})";
      exec = "${pkgs.ego}/bin/ego --machinectl --user=${name} heroic --ozone-platform=x11";
      icon = "com.heroicgameslauncher.hgl";
      categories = [ "Game" ];
    })
  ];

  systemd.tmpfiles.rules = [
    # 0700: grupa users to wszystkie zwykłe konta - nie mają tu wstępu.
    "d ${library} 0700 ${name} users -"
    "d ${library}/SteamLibrary 0700 ${name} users -"
    "d ${library}/Heroic 0700 ${name} users -"
  ];

  # Sesja tego konta ma zarejestrowaną usługę D-Bus dla powiadomień, ale żaden pełny plasmashell w
  # tej minimalnej sesji nigdy nie startuje - więc każda próba Heroica/Steama pokazania
  # powiadomienia wisi ~25s na timeout D-Bus (wygląda jak losowe zawieszenie UI). Ten lekki demon
  # odpowiada na wywołanie od razu.
  systemd.user.services."dunst-${name}" = {
    description = "Lekki demon powiadomień dla sesji ${name} (naprawia zawieszenia Heroic/Steam od D-Bus)";
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    unitConfig.ConditionUser = name;
    serviceConfig = {
      ExecStart = "${pkgs.dunst}/bin/dunst";
      Restart = "on-failure";
      RestartSec = 2;
    };
  };
}
