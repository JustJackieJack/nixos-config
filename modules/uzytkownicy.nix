# Użytkownicy:
#   Jacek     (1000) – główny, wheel
#   claude    (1001) – asystent; dostęp tylko do /home/wspolne + to, co Jacek da (daj-claude)
#   game_user (1002) – Steam/Heroic; gry na /mnt/games
#   zeroroot  (1003) – podejrzane programy; bez sieci, w gamescope + bubblewrap
# Hasło Jacka ustawia się przy instalacji (passwd). Pozostali nie mają hasła (konto zablokowane),
# uruchamia się ich przez ego / sudo z pulpitu Jacka.
{ config, lib, ... }:
{
  users.mutableUsers = true;

  users.groups = {
    proc.gid = 2000; # widzi wszystkie procesy przy hidepid
    wspolne.gid = 2001; # Jacek + claude
    zeroroot-wymiana.gid = 2002; # Jacek + zeroroot
  };

  users.users = {
    Jacek = {
      isNormalUser = true;
      uid = 1000;
      description = "Jacek";
      extraGroups = [
        "wheel"
        "networkmanager"
        "wireshark"
        "proc"
        "wspolne"
        "zeroroot-wymiana"
      ];
      autoSubUidGidRange = true; # podman bez roota
    };

    claude = {
      isNormalUser = true;
      uid = 1001;
      description = "Claude (asystent)";
      hashedPassword = "!";
      extraGroups = [
        "wspolne"
        "proc" # audytor: widzi procesy
        "systemd-journal" # audytor: czyta dziennik systemu
      ];
    };

    game_user = {
      isNormalUser = true;
      uid = 1002;
      description = "Gry (Steam, Heroic)";
      hashedPassword = "!";
      extraGroups = [
        "video"
        "render"
      ];
    };

    zeroroot = {
      isNormalUser = true;
      uid = 1003;
      description = "Kwarantanna (podejrzane programy)";
      hashedPassword = "!";
      extraGroups = [
        "video"
        "render"
        "zeroroot-wymiana"
      ];
    };
  };

  # ego (uruchamianie aplikacji jako inny użytkownik na Wayland) – zawsze z --machinectl,
  # bo tryb sudo ego używa flagi -H, której sudo-rs nie ma.
  # Jacek może bez hasła otworzyć sesję TYLKO dla tych trzech kont.
  security.polkit.extraConfig = ''
    polkit.addRule(function(action, subject) {
      if (action.id == "org.freedesktop.machine1.host-shell" &&
          subject.user == "Jacek" &&
          ["claude", "game_user", "zeroroot"].indexOf(action.lookup("user")) >= 0) {
        return polkit.Result.YES;
      }
    });
  '';

  systemd.tmpfiles.rules = [
    # Foldery wspólne Jacek ↔ claude (setgid + domyślne ACL: nowe pliki od razu dostępne dla obu).
    "d /home/wspolne 0750 root wspolne -"
    "d /home/wspolne/Obsydian 2770 Jacek wspolne -"
    "d /home/wspolne/Projekty 2770 Jacek wspolne -"
    "d /home/wspolne/Dla_Claude 2770 Jacek wspolne -" # kopie z pokaz-claude
    "a+ /home/wspolne/Obsydian - - - - default:group:wspolne:rwx,group:wspolne:rwx"
    "a+ /home/wspolne/Projekty - - - - default:group:wspolne:rwx,group:wspolne:rwx"
    "a+ /home/wspolne/Dla_Claude - - - - default:group:wspolne:rwx,group:wspolne:rwx"
    # Skróty w domu Jacka („L” bez „+”: nie nadpisuje, jeśli coś już tam jest).
    "L /home/Jacek/Obsydian - - - - /home/wspolne/Obsydian"
    "L /home/Jacek/Projekty - - - - /home/wspolne/Projekty"
    "d /home/Jacek/Downloads 0700 Jacek users -" # musi istnieć dla ClamAV (clamonacc)

    # Dom game_usera to osobny podwolumin – nadaj właściciela po zamontowaniu.
    "d /home/game_user 0700 game_user users -"
  ];
}
