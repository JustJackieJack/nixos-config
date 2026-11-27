# Test w maszynie wirtualnej: nix build .#checks.x86_64-linux.vm -L
#
# Uruchamia NASZE moduły (modules/) na wirtualnym „pc” obok wirtualnego „nas” (udaje LAN)
# i sprawdza zachowanie na żywym systemie. Pominięte, bo wymagają prawdziwego sprzętu:
# NVIDIA, Secure Boot, disko, ekran logowania (SDDM), snapper (wymaga btrfs),
# smartd (wirtualne dyski bez SMART). Pulpit i dyski: tests/pulpit.nix, tests/dyski.nix.
# ClamAV działa z własną sygnaturą testową (bez internetu nie pobierze prawdziwej bazy),
# sekrety: plik sops zaszyfrowany JAWNYM kluczem testowym (tests/dane/).
{ pkgs, inputs }:
pkgs.testers.runNixOSTest {
  name = "justjackpc";

  node.specialArgs = { inherit inputs; };
  node.pkgsReadOnly = false; # nasze moduły ustawiają nixpkgs.config (licencje)

  nodes.nas = {
    networking.firewall.allowedTCPPorts = [
      80
      445
      8000
    ];
    services.nginx = {
      enable = true;
      virtualHosts.default.locations."/".return = "200 'nas-ok'";
    };
    # repozytorium restic (jak kopia na NAS)
    services.restic.server = {
      enable = true;
      listenAddress = "8000";
      extraFlags = [ "--no-auth" ];
    };
    # udział Modele_3D (jak //10.0.190.5/Modele_3D)
    users.users.modele.isNormalUser = true;
    services.samba = {
      enable = true;
      settings.Modele_3D = {
        path = "/srv/modele";
        "read only" = "no";
        "valid users" = "modele";
      };
    };
    systemd.tmpfiles.rules = [
      "d /srv/modele 0777 modele users -"
      "f /srv/modele/kostka.stl 0644 modele users - solid-test"
    ];
  };

  nodes.pc =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    {
      imports = [
        inputs.lanzaboote.nixosModules.lanzaboote
        inputs.sops-nix.nixosModules.sops
        ../modules
        # Druga instancja szablonu "gry" (tylko w teście) - dowód, że szablon faktycznie działa
        # dla więcej niż jednej instancji, nie tylko teoretycznie. "rodzic = Jacek" bo żadnego
        # realnego drugiego człowieka jeszcze nie ma.
        (import ../modules/users/szablony/gry.nix { nazwa = "dziecko-games"; })
      ];

      networking.hostName = "pc";
      moje.lan = "192.168.1.0/24"; # sieć testowa
      moje.secureBoot.enable = false;
      system.stateVersion = "26.05";

      # --- tylko na potrzeby testu (sprzęt / internet) ---
      services.xserver.videoDrivers = lib.mkForce [ "modesetting" ];
      services.displayManager.sddm.enable = lib.mkForce false;
      # ClamAV: bez pobierania bazy, za to własna sygnatura (MD5 pliku testowego)
      services.clamav.updater.enable = lib.mkForce false;
      systemd.tmpfiles.rules = [
        "L+ /var/lib/clamav/test.hdb - - - - ${pkgs.writeText "test.hdb" "c59e105b47e44a9c9121b5705e130aea:33:Test.JustJack.Zly\n"}"
      ];
      # sekrety: testowy plik sops + jawny klucz testowy
      moje.sekrety.plik = ./dane/sekrety-testowe.yaml;
      # NAS w sieci testowej; moduł maszyny wirtualnej podmienia fileSystems, więc ten sam
      # wpis montowania (z backups.nix) podajemy mu jawnie. Scalamy (nie nadpisujemy) z
      # mountami z admin-access.nix (ClaudeFiles) – stąd osobna opcja moje.claude.*, a nie
      # odwołanie do config.fileSystems (to by było cykliczne: config.fileSystems sam jest
      # ustawiany NA PODSTAWIE virtualisation.fileSystems przez moduł qemu-vm).
      moje.nas.adres = "nas";
      moje.secure.domeny = [ "nas" ]; # domena „dozwolona” w sieci testowej
      networking.extraHosts = "192.168.1.1 obcy-serwer"; # nazwa spoza listy domen secure_user
      virtualisation.fileSystems = config.moje.nas.montowania // config.moje.claude.adminAccessFileSystems;
      # klucz trafia tam, gdzie na prawdziwym systemie (backups.nix), przed odszyfrowaniem sekretów
      system.activationScripts.kluczTestowy = lib.stringAfter [ "specialfs" ] ''
        install -d -m 0700 /var/lib/sops-nix
        install -m 0400 ${./dane/klucz-testowy.txt} /var/lib/sops-nix/key.txt
      '';
      system.activationScripts.setupSecrets.deps = [ "kluczTestowy" ];
      services.snapper.configs = lib.mkForce { };
      services.smartd.enable = lib.mkForce false; # wirtualne dyski nie mają SMART
      networking.networkmanager.unmanaged = [ "eth1" ]; # adres nadaje framework testów
      users.users.Jacek.linger = true; # menedżer usług Jacka bez logowania (access-mcp, strażnik)
      # Konto dla drugiej instancji szablonu "gry" (patrz import wyżej) - w prawdziwym rejestrze
      # (konta.nix) byłby to jeden wpis; tu, tylko na potrzeby testu szablonu, deklarujemy je
      # wprost, bez przechodzenia przez cały rejestr.
      users.users."dziecko-games" = {
        isNormalUser = true;
        uid = 1010;
        hashedPassword = "!";
      };
      virtualisation = {
        memorySize = 4096;
        cores = 4;
        diskSize = 4096;
      };
    };

  testScript =
    { nodes, ... }:
    ''
      import shlex

      def jako(user, cmd, uid=None):
          env = ""
          if uid is not None:
              env = f"env XDG_RUNTIME_DIR=/run/user/{uid} DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{uid}/bus "
          return f"runuser -u {user} -- {env}sh -c {shlex.quote(cmd)}"

      def jacek(cmd):
          return jako("Jacek", cmd, 1000)

      start_all()
      nas.wait_for_unit("nginx.service")
      pc.wait_for_unit("multi-user.target")
      pc.wait_for_unit("opensnitchd.service")
      pc.wait_for_unit("user@1000.service")

      with subtest("brak nieudanych usług"):
          out = pc.succeed("systemctl --failed --no-legend --plain | awk '{print $1}'").split()
          assert out == [], f"nieudane usługi: {out}"

      with subtest("użytkownicy, grupy, foldery"):
          for u, n in [("Jacek", 1000), ("claude", 1001), ("game_user", 1002), ("zeroroot", 1003), ("straznik", 399)]:
              assert pc.succeed(f"id -u {u}").strip() == str(n), u
          pc.succeed("id -nG Jacek | grep -qw wheel")
          pc.succeed("id -nG claude | grep -qw systemd-journal")
          pc.fail("id -nG claude | grep -qw wheel")
          pc.succeed("test \"$(stat -c '%a %U %G' /home/shared/Projects)\" = '2770 Jacek projects'")
          pc.succeed("test \"$(stat -c '%a %U %G' /srv/zeroroot-exchange)\" = '2770 zeroroot zeroroot-exchange'")
          pc.succeed("test \"$(stat -c '%a %U' /home/game_user)\" = '700 game_user'")
          pc.succeed("test \"$(readlink /home/Jacek/Projects)\" = /home/shared/Projects")
          pc.succeed("test \"$(stat -c %U /mnt/games)\" = game_user")
          # bity "inni" muszą zostać 0 - grupowy nibble zmienia się po dodaniu ACL (odzwierciedla
          # maskę ACL, nie prawa grupy "users"), to jest oczekiwane, sprawdzane dalej w podteście
          # dostepRodzica (inne konta i tak bez dostępu)
          pc.succeed("stat -c %a /mnt/games | grep -qE '0$'")

      with subtest("dostepRodzica: Jacek ma stały dostęp do /mnt/games (gry) i /home/zeroroot, bez sudo/ego"):
          # usługa jednorazowa (nie activationScript - patrz komentarz w konta.nix), musi
          # dokończyć PRZED sprawdzeniem ACL - wantedBy=multi-user.target nie gwarantuje tego
          # samo z siebie (to Wants, nie blokująca zależność)
          pc.wait_for_unit("dostepRodzicowDoPoduserow.service")
          # ACL, nie bit grupy - mode zostaje 0700, dostęp Jacka idzie przez wpis ACL
          pc.succeed(jako("game_user", "echo zapis-gry > /mnt/games/plik_gry.txt"))
          assert pc.succeed(jacek("cat /mnt/games/plik_gry.txt")).strip() == "zapis-gry"
          pc.succeed(jacek("echo od-jacka > /mnt/games/nowy_od_jacka.txt"))  # nowe pliki: default ACL
          assert pc.succeed(jako("game_user", "cat /mnt/games/nowy_od_jacka.txt")).strip() == "od-jacka"
          pc.succeed(jako("zeroroot", "echo zapis-zeroroot > /home/zeroroot/plik.txt"))
          assert pc.succeed(jacek("cat /home/zeroroot/plik.txt")).strip() == "zapis-zeroroot"
          # skróty w domu Jacka
          assert pc.succeed("readlink /home/Jacek/Gry").strip() == "/mnt/games"
          assert pc.succeed("readlink /home/Jacek/Zeroroot").strip() == "/home/zeroroot"
          assert pc.succeed(jacek("cat ~/Gry/plik_gry.txt")).strip() == "zapis-gry"
          # inne konta nadal bez dostępu - to jest TYLKO dla rodzica (Jacka)
          for u in ["claude", "dev_user", "browse_user", "secure_user"]:
              pc.fail(jako(u, "ls /mnt/games"))
              pc.fail(jako(u, "ls /home/zeroroot"))

      with subtest("hidepid: game_user widzi tylko swoje procesy, Jacek wszystkie"):
          g = int(pc.succeed(jako("game_user", "ps -e --no-headers | wc -l")))
          j = int(pc.succeed(jako("Jacek", "ps -e --no-headers | wc -l")))
          print(f"procesy: game_user={g} Jacek={j}")
          assert g < 6 and j > 40, (g, j)

      with subtest("polkit + machinectl (droga ego): Jacek → game_user/claude/zeroroot/dev_user/browse_user bez hasła, root nie"):
          for u, n in [("game_user", 1002), ("claude", 1001), ("zeroroot", 1003), ("dev_user", 1005), ("browse_user", 1006)]:
              out = pc.succeed(jako("Jacek", f"machinectl shell --quiet --uid={u} .host /bin/sh -c 'id -u' < /dev/null"))
              assert str(n) in out, (u, out)
          pc.fail(jako("Jacek", "machinectl shell --quiet --uid=root .host /bin/sh -c 'id -u' < /dev/null"))
          pc.fail(jako("game_user", "machinectl shell --quiet --uid=zeroroot .host /bin/true < /dev/null"))

      with subtest("sudo-rs"):
          assert pc.succeed(jako("Jacek", "sudo -n -u claude id -u")).strip() == "1001"
          pc.fail(jako("Jacek", "sudo -n true"))  # root wymaga hasła
          # konta.nix generuje regułę sudo-rs jednolicie dla KAŻDEGO wpisu z `rodzic` (nie tylko
          # claude jak dawniej) - game_user/zeroroot/dev_user mają teraz ten sam, symetryczny
          # dostęp co przez ego/machinectl, nie nowe uprawnienie (Jacek i tak miał tam pełny
          # dostęp przez ego).
          assert pc.succeed(jako("Jacek", "sudo -n -u game_user id -u")).strip() == "1002"
          pc.fail(jako("game_user", "sudo -n true"))  # execWheelOnly: nie może nawet uruchomić sudo

      with subtest("foldery wspólne: Jacek i claude piszą sobie nawzajem"):
          pc.succeed(jako("Jacek", "echo od-jacka > /home/shared/Projects/a.txt"))
          pc.succeed(jako("claude", "echo dopisek >> /home/shared/Projects/a.txt && mkdir /home/shared/Projects/kat && echo c > /home/shared/Projects/kat/b.txt"))
          pc.succeed(jako("Jacek", "echo d >> /home/shared/Projects/kat/b.txt"))
          pc.fail(jako("game_user", "ls /home/shared/Projects"))

      with subtest("claude-view / claude-edit / claude-copy / claude-revoke"):
          pc.succeed(jacek("mkdir -p ~/Documents ~/.config/gh ~/Projekt2 && echo tajne > ~/Documents/t.txt && chmod 600 ~/Documents/t.txt && echo token > ~/.config/gh/hosts.yml && echo a > ~/Projekt2/f"))
          pc.fail(jako("claude", "cat /home/Jacek/Documents/t.txt"))
          pc.fail(jacek("claude-view ~/.config"))  # zawiera sekret
          pc.fail(jacek("claude-view ~/.config/gh/hosts.yml"))  # sam sekret
          pc.fail(jacek("claude-view ~"))  # cały dom
          pc.fail(jacek("claude-view -t zly ~/Documents/t.txt"))  # zły czas
          cel = pc.succeed(jacek("claude-view -t 10s ~/Documents/t.txt")).strip()
          print("udostępniono (view):", cel)
          assert pc.succeed(jako("claude", f"cat {cel}")).strip() == "tajne"
          pc.fail(jako("claude", f"echo x >> {cel}"))  # tylko odczyt – test na naprawiony bug z flagą ro
          # dom Jacka nadal zamknięty – także dla plików 644 (to był błąd poprzedniej wersji)
          pc.fail(jako("claude", "cat /home/Jacek/Documents/t.txt"))
          pc.fail(jako("claude", "cat /home/Jacek/.config/gh/hosts.yml"))
          pc.fail(jako("claude", "ls /home/Jacek"))
          # claude-edit: zapis NA ORYGINALE + zabranie od razu
          cel2 = pc.succeed(jacek("claude-edit -t 1h ~/Projekt2")).strip()
          pc.succeed(jako("claude", f"echo od-claude >> {cel2}/f"))
          pc.succeed(jako("Jacek", "grep -q od-claude /home/Jacek/Projekt2/f"))
          pc.succeed(jacek("claude-revoke ~/Projekt2"))
          pc.fail(jako("claude", f"cat {cel2}/f"))
          pc.fail(f"test -e {cel2}")
          # wygaśnięcie (view z 10s wyżej)
          pc.sleep(15)
          pc.fail(jako("claude", f"cat {cel}"))
          pc.fail(f"test -e {cel}")
          # claude-copy: TRWAŁA kopia – edycja kopii nie wraca do oryginału, kopia nie wygasa
          cel3 = pc.succeed(jacek("claude-copy ~/Documents/t.txt")).strip()
          assert pc.succeed(jako("claude", f"cat {cel3}")).strip() == "tajne"
          pc.succeed(jako("claude", f"echo zmiana >> {cel3}"))  # kopia jest zapisywalna
          pc.fail(jako("Jacek", "grep -q zmiana /home/Jacek/Documents/t.txt"))  # ale oryginał nietknięty
          pc.sleep(2)
          pc.succeed(f"test -e {cel3}")  # kopia NIE wygasa jak view/edit
          # atak: pomocnik root dostaje dowiązanie do pliku roota → musi odmówić
          pc.succeed(jacek("ln -s /etc/shadow ~/Documents/zly && ln -s /root ~/Documents/zlykat"))
          pc.fail(jacek("sudo -n \"$(readlink -f \"$(command -v claude-share)\")\" add view Jacek claude /home/Jacek/Documents/zly 1h"))
          pc.fail(jacek("sudo -n \"$(readlink -f \"$(command -v claude-share)\")\" add view Jacek claude /home/Jacek/Documents/zlykat 1h"))
          pc.fail(jacek("sudo -n \"$(readlink -f \"$(command -v claude-share)\")\" add view Jacek claude /etc/shadow 1h"))
          pc.fail(jacek("sudo -n \"$(readlink -f \"$(command -v claude-share)\")\" remove claude /etc"))
          pc.succeed("test -z \"$(ls -A /home/shared/Views/claude 2>/dev/null)\"")
          pc.succeed("! findmnt -rn -o TARGET | grep -q Shared")
          # inny użytkownik nie może użyć pomocnika, nawet dla samego siebie
          pc.fail(jako("game_user", "sudo -n /run/current-system/sw/bin/claude-share remove claude"))
          # źle zadeklarowane source-user: plik nie należy do podanego konta
          pc.fail(jacek("sudo -n \"$(readlink -f \"$(command -v claude-share)\")\" add view game_user claude /home/Jacek/Documents/t.txt 1h"))

      with subtest("claude-share: inne konto źródłowe (game_user → claude), bez furtki domyślnej"):
          pc.succeed(jako("game_user", "echo gra-dane > /mnt/games/sekret_testowy.txt"))
          pc.fail(jako("claude", "ls /mnt/games"))  # bez wyjątku wciąż zablokowane
          cel4 = pc.succeed(jacek("sudo -n \"$(readlink -f \"$(command -v claude-share)\")\" add view game_user claude /mnt/games/sekret_testowy.txt 10s")).strip()
          assert pc.succeed(jako("claude", f"cat {cel4}")).strip() == "gra-dane"
          pc.fail(jako("claude", "ls /mnt/games"))  # wyjątek dotyczy tylko udostępnionego pliku
          pc.sleep(15)
          pc.fail(jako("claude", f"cat {cel4}"))

      with subtest("claude-share: secure_user/dev_user/browse_user też jako źródło, własny profil Firefoksa chroniony"):
          share = "sudo -n \"$(readlink -f \"$(command -v claude-share)\")\""
          for u in ["secure_user", "dev_user", "browse_user"]:
              testfile = f"/home/{u}/nie-profil.txt"
              pc.succeed(jako(u, f"echo dane-{u} > {testfile}"))
              cel = pc.succeed(jacek(f"{share} add view {u} claude {testfile} 10s")).strip()
              assert pc.succeed(jako("claude", f"cat {cel}")).strip() == f"dane-{u}", u
          # profil Firefoksa (secure_user, browse_user) i .ssh (dev_user) - chronione nawet
          # jako skonfigurowane, dozwolone konta źródłowe (ta sama zasada co .ssh/.mozilla Jacka)
          pc.fail(jacek(f"{share} add view secure_user claude /home/secure_user/profil-firefox/user.js 10s"))
          pc.fail(jacek(f"{share} add view browse_user claude /home/browse_user/profil-firefox/user.js 10s"))
          pc.fail(jacek(f"{share} add view dev_user claude /home/dev_user/.ssh/config.d/ssh-agent.conf 10s"))

      with subtest("old Polish command names no longer exist"):
          for old in ["daj-claude", "pokaz-claude", "zabierz-claude", "claude-montuj", "claude-udostepnij", "claude-sesja", "claude-dom", "dostep-mcp"]:
              pc.fail(f"command -v {old}")

      with subtest("claude-code nie jest dostępny bezpośrednio - tylko przez claude-session/-home jako konto claude"):
          pc.fail(jacek("command -v claude"))
          pc.succeed(jacek("command -v claude-session"))
          pc.succeed(jacek("command -v claude-home"))
          # claude-session odpala PRAWDZIWĄ binarkę po pełnej ścieżce /nix/store, nie goły "claude"
          pc.succeed("grep -q '/nix/store/.*-claude-code-.*/bin/claude' \"$(readlink -f \"$(command -v claude-session)\")\"")

      with subtest("ClaudeFiles: trwały, zapisywalny widok plików claude dla Jacka"):
          for nazwa in ["ssh", "CLAUDE.md", "skills", "claude.json", "rules", "agents", "commands"]:
              pc.succeed(f"findmnt /home/shared/ClaudeFiles/{nazwa}")
          # CLAUDE.md jest tylko do odczytu - instructions.nix nadpisuje je co restart (zob.
          # komentarz w admin-access.nix), więc zapis przez ten mount musi się nie udać.
          out = pc.succeed(jacek("cat ~/Claude/CLAUDE.md"))
          assert "claude" in out.lower()
          pc.fail(jacek("echo x >> ~/Claude/CLAUDE.md"))
          pc.succeed(jako("claude", "echo 'Host test' > ~/.ssh/config"))
          # Jacek czyta, bez sudo
          out = pc.succeed(jacek("cat ~/Claude/ssh/config"))
          assert "test" in out.lower()
          # Jacek edytuje – to ten sam i-węzeł, zmiana trafia do prawdziwego pliku claude
          pc.succeed(jacek("echo dopisek-jacka >> ~/Claude/ssh/config"))
          pc.succeed(jako("claude", "grep -q dopisek-jacka /home/claude/.ssh/config"))
          # nowy plik, który CLAUDE stworzy w udostępnionym KATALOGU, widoczny u Jacka od razu (bez remontowania)
          pc.succeed(jako("claude", "mkdir -p ~/.claude/skills/nowy && echo x > ~/.claude/skills/nowy/SKILL.md"))
          pc.succeed(jacek("test -f ~/Claude/skills/nowy/SKILL.md"))
          # Jacek też może DOPISAĆ nowy plik w udostępnionym katalogu (domyślne ACL = prawo zapisu na katalogu)
          pc.succeed(jacek("echo od-jacka > ~/Claude/skills/od-jacka.txt"))
          pc.succeed(jako("claude", "cat /home/claude/.claude/skills/od-jacka.txt"))
          # inne konta nie mają żadnego dostępu do folderu ClaudeFiles (0700 Jacek)
          pc.fail(jako("claude", "ls /home/shared/ClaudeFiles"))
          pc.fail(jako("game_user", "ls /home/shared/ClaudeFiles"))

      with subtest("zapora przychodząca: KDE Connect z LAN tak, inne porty nie"):
          pc.succeed("systemd-run --unit=kdec python3 -m http.server 1716")
          pc.succeed("systemd-run --unit=inny python3 -m http.server 8081")
          pc.wait_for_open_port(1716)
          pc.wait_for_open_port(8081)
          nas.succeed("curl -sf -m 5 http://pc:1716 > /dev/null")
          nas.fail("curl -sf -m 5 http://pc:8081 > /dev/null")

      with subtest("zeroroot bez sieci (nawet localhost), inni mają localhost"):
          pc.succeed("systemd-run --unit=lokalny python3 -m http.server 8080 --bind 127.0.0.1")
          pc.wait_for_open_port(8080)
          pc.succeed(jako("Jacek", "curl -sf -m 5 http://127.0.0.1:8080 > /dev/null"))
          pc.succeed(jako("game_user", "curl -sf -m 5 http://127.0.0.1:8080 > /dev/null"))
          pc.fail(jako("zeroroot", "curl -sf -m 5 http://127.0.0.1:8080 > /dev/null"))
          pc.fail(jako("zeroroot", "curl -sf -m 5 http://nas > /dev/null"))
          # Z OpenSnitch blokuje już jego reguła 000 (działa wcześniej niż nftables).
          # Teraz to samo BEZ OpenSnitch (jak w trybie awaryjnym) – musi wystarczyć sam nftables.
          pc.succeed("systemctl stop opensnitchd")
          pc.succeed(jako("Jacek", "curl -sf -m 5 http://nas > /dev/null"))  # bez OpenSnitch Jacek ma sieć
          pc.fail(jako("zeroroot", "curl -sf -m 5 http://nas > /dev/null"))
          pc.fail(jako("zeroroot", "curl -sf -m 5 http://127.0.0.1:8080 > /dev/null"))
          pc.succeed("journalctl -k | grep -q zeroroot-blokada")
          pc.succeed("systemctl start opensnitchd")
          pc.wait_for_unit("opensnitchd.service")
          pc.sleep(3)

      with subtest("OpenSnitch: ścieżki w regułach to prawdziwe pliki – nie dowiązania ani opakowania"):
          out = pc.succeed("grep -ho '\"data\":\"/nix/store/[^\"]*' /var/lib/opensnitch/rules/*.json | cut -d'\"' -f4")
          for sciezka in out.split():
              pc.succeed(f"test -f {sciezka} && test ! -L {sciezka} && test \"$(readlink -f {sciezka})\" = {sciezka}")
              # opakowanie (wrapProgram/makeBinaryWrapper): prawdziwy proces to .NAZWA-wrapped
              pc.succeed(f"test ! -e $(dirname {sciezka})/.$(basename {sciezka})-wrapped")

      with subtest("OpenSnitch: reguły załadowane, domyślnie odmowa, wyjątki działają"):
          out = pc.succeed("journalctl -u opensnitchd -b --no-pager")
          print(out[-3000:])
          assert "rror" not in "\n".join(l for l in out.splitlines() if "rule" in l.lower()), "błąd w regułach"
          # Jacek (zwykły program, okno pytań nie działa) → odmowa
          pc.fail(jako("Jacek", "curl -sf -m 8 http://nas > /dev/null"))
          # claude → pełna sieć
          assert "nas-ok" in pc.succeed(jako("claude", "curl -sf -m 8 http://nas"))
          # nix jako root → dozwolony (reguła listowa: ścieżka + UID 0)
          # nix.package (ten sam co nix-daemon i nixos-rebuild); framework testów dokłada do PATH
          # własną kompilację nix, więc wywołujemy dokładnie tę z konfiguracji
          nix = "${nodes.pc.nix.package}/bin/nix --option connect-timeout 5 --option download-attempts 1 store prefetch-file"
          pc.succeed(f"{nix} http://nas/plik1")
          # ten sam nix jako Jacek → odmowa
          pc.fail(jako("Jacek", f"{nix} http://nas/plik2"))
          # strażnik (vulnix) → dozwolony
          pc.succeed(jako("straznik", "curl -sf -m 8 http://nas > /dev/null"))

      with subtest("strażnik ma dostęp do demona Nix (vulnix), game_user nie"):
          pc.succeed(jako("straznik", "nix-store -qR /run/current-system > /dev/null"))
          pc.fail(jako("game_user", "nix-store -qR /run/current-system > /dev/null"))

      with subtest("secure_user: osobne konto, start tylko z hasłem, lista domen, utwardzony Firefox"):
          pc.succeed("test \"$(id -u secure_user)\" = 1004")
          pc.succeed("test \"$(stat -c '%a %U' /home/secure_user)\" = '700 secure_user'")
          pc.fail(jako("Jacek", "ls /home/secure_user"))
          pc.fail(jako("secure_user", "ls /home/Jacek"))
          pc.fail(jako("secure_user", "ls /home/shared"))
          for u in ["claude", "game_user", "zeroroot"]:
              pc.fail(jako(u, "ls /home/secure-documents"))
              pc.fail(jako(u, "ls /home/secure_user"))
          # dokumenty: secure_user zapisuje, Jacek czyta (także przez skrót w domu)
          pc.succeed(jako("secure_user", "echo wyciag > /home/secure-documents/wyciag.pdf"))
          pc.succeed(jako("Jacek", "grep -q wyciag /home/Jacek/BankDocuments/wyciag.pdf"))
          # ego/machinectl do secure_user wymaga hasła – bez potwierdzenia (brak agenta) odmowa
          pc.fail(jako("Jacek", "machinectl shell --quiet --uid=secure_user .host /bin/true < /dev/null"))
          pc.fail(jako("game_user", "machinectl shell --quiet --uid=secure_user .host /bin/true < /dev/null"))
          # OpenSnitch: domena z listy (w teście „nas”) bez pytania, adres spoza listy – odmowa
          pc.succeed(jako("secure_user", "curl -sf -m 8 http://nas > /dev/null"))
          # „obcy-serwer” to ten sam adres co nas, ale nazwa spoza listy (jak fałszywa strona banku).
          # OpenSnitch ocenia NAZWĘ, przez którą program dostał adres – musi być odmowa.
          pc.fail(jako("secure_user", "curl -sf -m 8 http://obcy-serwer > /dev/null"))
          # blokada Firefoksa Jacka dotyczy tylko JEGO UID (inaczej omijałaby listę domen secure_user)
          pc.succeed("grep -q '\"data\":\"1000\"' /var/lib/opensnitch/rules/020-firefox-blokada-jacka.json")
          pc.succeed("grep -q '\"action\":\"reject\"' /var/lib/opensnitch/rules/020-firefox-blokada-jacka.json")
          # lista domen = stała część (urzędy) + dopisane w hoście/teście (nie zastępuje)
          pc.succeed("grep -q 'gov\\\\\\\\.pl' /var/lib/opensnitch/rules/030-secure_user-domeny.json")
          # utwardzony profil Firefoksa: user.js stosowany przy starcie (Firefox zapisuje go do prefs.js)
          pc.execute(jako("secure_user", "timeout 180 firefox --headless --new-instance --profile /home/secure_user/profil-firefox --screenshot /tmp/ff.png about:blank"))
          prefs = pc.succeed("cat /home/secure_user/profil-firefox/prefs.js")
          for wpis in ['"dom.security.https_only_mode", true', '"signon.rememberSignons", false',
                       '"network.IDN_show_punycode", true', '"xpinstall.enabled", false',
                       '"media.peerconnection.enabled", false', '"browser.contentblocking.category", "strict"']:
              assert wpis in prefs, f"brak w prefs.js: {wpis}"
          # YubiKey (FIDO2) dla secure_user i skrót w menu
          pc.succeed("grep -rq 'ID_FIDO_TOKEN.*secure-fido' /etc/udev/rules.d/")
          pc.succeed("grep -q 'ego --machinectl --user=secure_user firefox' /run/current-system/sw/share/applications/secure_user-firefox.desktop")

      with subtest("Paperwork: stały folder Jacek <-> secure_user, secure-give/-revoke czasowe"):
          pc.succeed("test \"$(stat -c '%a %U %G' /home/Paperwork)\" = '2770 Jacek paperwork'")
          pc.succeed(jako("Jacek", "echo od-jacka > /home/Paperwork/formularz.pdf"))
          pc.succeed(jako("secure_user", "grep -q od-jacka /home/Paperwork/formularz.pdf && echo dopisek-secure_user >> /home/Paperwork/formularz.pdf"))
          pc.succeed(jako("Jacek", "grep -q dopisek-secure_user /home/Paperwork/formularz.pdf"))
          for u in ["claude", "game_user", "zeroroot", "dev_user"]:
              pc.fail(jako(u, "ls /home/Paperwork"))
          # secure-give: czasowy, tylko-do-odczytu (bez -w) podgląd konkretnego pliku
          pc.succeed(jako("Jacek", "echo tajne > ~/do-oddania.txt"))
          cel = pc.succeed(jacek("secure-give -t 10s ~/do-oddania.txt")).strip()
          pc.succeed(f"grep -q tajne {cel}")
          pc.fail(jako("secure_user", f"echo zmiana >> {cel}"))  # view, nie edit - tylko odczyt
          pc.fail(jako("claude", f"cat {cel}"))  # udostępnione tylko secure_user, nie innym
          pc.succeed(jacek("secure-revoke ~/do-oddania.txt"))
          pc.fail(jako("secure_user", f"cat {cel}"))

      with subtest("dev_user: osobne konto do kodowania, ego, sudo, Podman rootless, OpenSnitch"):
          pc.succeed("test \"$(id -u dev_user)\" = 1005")
          pc.succeed("test \"$(stat -c '%a %U' /home/dev_user)\" = '700 dev_user'")
          pc.fail(jako("dev_user", "ls /home/Jacek"))
          pc.fail(jako("dev_user", "ls /home/shared"))
          for u in ["claude", "game_user", "zeroroot", "secure_user"]:
              pc.fail(jako(u, "ls /home/dev_user"))
          # ego/machinectl do dev_user: Jacek bez hasła (jak claude/game_user/zeroroot, nie jak secure_user)
          out = pc.succeed(jako("Jacek", "machinectl shell --quiet --uid=dev_user .host /bin/sh -c 'id -u' < /dev/null"))
          assert "1005" in out, out
          pc.fail(jako("game_user", "machinectl shell --quiet --uid=dev_user .host /bin/true < /dev/null"))
          # sudo-rs: Jacek -> dev_user bez hasła, dev_user sam nie może sudo (execWheelOnly)
          assert pc.succeed(jako("Jacek", "sudo -n -u dev_user id -u")).strip() == "1005"
          pc.fail(jako("dev_user", "sudo -n true"))
          # wrapper dev_user-home (lekki terminal bez ego/sesji graficznej)
          assert pc.succeed(jacek("dev_user-home id -un")).strip() == "dev_user"
          # Podman rootless (subuid/subgid, bez roota) - bez sieci: samo utworzenie user namespace
          assert pc.succeed(jako("dev_user", "podman unshare id -u")).strip() == "0"
          # OpenSnitch: domeny startowe (GitHub itp.) wczytane
          pc.succeed("grep -q 'github\\\\\\\\.com' /var/lib/opensnitch/rules/040-dev_user-domeny.json")

      with subtest("dev_user: współdzielony ssh-agent Jacka (bez własnych kluczy w dev_user)"):
          # ~/.ssh/config dev_user wskazuje na agenta Jacka, nie na własny klucz
          pc.succeed("grep -q 'IdentityAgent /run/dev_user-ssh-agent/agent.sock' /home/dev_user/.ssh/config.d/ssh-agent.conf")
          pc.succeed("grep -qxF 'Include config.d/*.conf' /home/dev_user/.ssh/config")
          # Prawdziwy agent jest wantedBy=graphical-session.target - w tej headless maszynie
          # testowej ten target nigdy nie jest osiągnięty (brak prawdziwej sesji Plasma), tak samo
          # jak dla opensnitch-ui/access-mcp-claude - stąd ręczny start (jak przy straznik-* niżej
          # w pliku). Gniazdo proxy (.socket, wantedBy=sockets.target) powinno wystartować samo,
          # ale startujemy jawnie dla pewności/powtarzalności testu.
          pc.succeed(jacek("systemctl --user start dev_user-ssh-agent-real.service dev_user-ssh-agent.socket"))
          # Jacek ładuje TESTOWY klucz (bez hasła) do agenta przez dev_user-ssh-add
          pc.succeed(jacek('ssh-keygen -t ed25519 -N "" -f ~/.ssh/testkey -C test'))
          odcisk = pc.succeed(jacek("ssh-keygen -lf ~/.ssh/testkey.pub")).split()[1]
          pc.succeed(jacek("dev_user-ssh-add -t 1h ~/.ssh/testkey"))
          # dev_user widzi TEN SAM klucz przez wspólne gniazdo, inne konta - wcale
          wynik = pc.succeed(jako("dev_user", "SSH_AUTH_SOCK=/run/dev_user-ssh-agent/agent.sock ssh-add -l"))
          assert odcisk in wynik, wynik
          for u in ["claude", "game_user", "zeroroot", "secure_user"]:
              pc.fail(jako(u, "SSH_AUTH_SOCK=/run/dev_user-ssh-agent/agent.sock ssh-add -l"))

      with subtest("browse_user: główna przeglądarka izolowana od plików/sudo Jacka, folder pobierania dwukierunkowy"):
          assert pc.succeed("id -u browse_user").strip() == "1006"
          # izolacja: żadnej z grup Jacka (shared/projects/paperwork/wheel) - tylko grupa pierwotna
          # "users" (jak każde isNormalUser) i własna grupa pobierania
          grupy = pc.succeed("id -nG browse_user").split()
          assert grupy == ["users", "browse_user-downloads"], grupy
          pc.fail(jako("browse_user", "ls /home/Jacek"))
          pc.fail(jako("browse_user", "ls /home/shared"))
          # profil Firefoksa: user.js wskazuje pobieranie na wspólny folder
          pc.succeed("grep -q 'browser.download.dir\", \"/home/browse_user-downloads' /home/browse_user/profil-firefox/user.js")
          # folder pobierania: dwukierunkowy (Jacek i browse_user), skrót w domu Jacka
          pc.succeed(jacek("echo z-sieci > /home/browse_user-downloads/plik-z-necu.txt"))
          pc.succeed("test -e /home/Jacek/BrowserDownloads/plik-z-necu.txt")  # to jest symlink na ten sam katalog
          pc.succeed(jako("browse_user", "echo od-jacka > /home/browse_user-downloads/do-wyslania.txt"))
          pc.succeed(jacek("cat /home/browse_user-downloads/do-wyslania.txt"))
          for u in ["claude", "game_user", "zeroroot", "secure_user", "dev_user"]:
              pc.fail(jako(u, "ls /home/browse_user-downloads"))
          # OpenSnitch: pełny dostęp do sieci dla TEGO konta (klucz po UID, nie tylko ścieżce binarki)
          reguła = pc.succeed("cat /var/lib/opensnitch/rules/025-browse_user-firefox.json")
          assert '"action":"allow"' in reguła and '"data":"1006"' in reguła, reguła

      with subtest("vpn_user/tor_user: konta przygotowane pod tunel WireGuard (moje.vpn.enable=false - jeszcze bez pliku .wg)"):
          assert pc.succeed("id -u vpn_user").strip() == "1007"
          assert pc.succeed("id -u tor_user").strip() == "1008"
          for u in ["vpn_user", "tor_user"]:
              pc.fail(jako(u, "ls /home/Jacek"))
              pc.fail(jako(u, "ls /home/shared"))
          # moje.vpn.enable=false w tym teście (tak jak domyślnie na realnym hoście, dopóki nie
          # dojdzie plik .wg) - interfejs wgVpn nie istnieje, więc jednostka wireguard-wgVpn nie
          # jest wygenerowana i sops nie próbuje deszyfrować nieistniejącego sekretu
          pc.fail("systemctl status wireguard-wgVpn.service")
          pc.fail("test -e /run/secrets/vpn")
          # vpn_user: kill switch działa NIEZALEŻNIE od tego, czy tunel istnieje - zero sieci,
          # nie "zwykły internet w zastępstwie" (to jest cały sens "fail closed")
          pc.succeed(jako("vpn_user", "ip rule list | grep -q 'uidrange 1007-1007'"))
          pc.fail(jako("vpn_user", "curl -sf -m 5 http://nas > /dev/null"))
          # tor_user: domyślnie (przełącznik wyłączony) zwykły internet - ale TYLKO dla samej
          # binarki tor (OpenSnitch), nie dla dowolnego programu na tym koncie
          pc.fail(jako("tor_user", "ip rule list | grep -q 'uidrange 1008-1008'"))
          reguła_tor = pc.succeed("cat /var/lib/opensnitch/rules/027-tor_user-tor.json")
          assert "TorBrowser/Tor/tor" in reguła_tor and '"data":"1008"' in reguła_tor, reguła_tor
          # przełącznik tor-vpn-on/-off (root, bezhasłowo dla Jacka - dokładna ścieżka /nix/store)
          wlacz = jacek("sudo -n \"$(readlink -f \"$(command -v tor-vpn-on)\")\"")
          wylacz = jacek("sudo -n \"$(readlink -f \"$(command -v tor-vpn-off)\")\"")
          pc.succeed(wlacz)
          pc.succeed("ip rule list | grep -q 'uidrange 1008-1008'")
          pc.succeed(wylacz)
          pc.fail("ip rule list | grep -q 'uidrange 1008-1008'")
          # foldery pobierania: osobne od browse_user, osobne między sobą
          for u in ["vpn_user", "tor_user"]:
              pc.succeed(f"test -d /home/{u}-downloads")
          pc.fail(jako("vpn_user", "ls /home/tor_user-downloads"))
          pc.fail(jako("tor_user", "ls /home/vpn_user-downloads"))
          assert pc.succeed("readlink /home/Jacek/VpnDownloads").strip() == "/home/vpn_user-downloads"
          assert pc.succeed("readlink /home/Jacek/TorDownloads").strip() == "/home/tor_user-downloads"

      with subtest("request_command: claude może poprosić o komendę jako game_user/zeroroot/dev_user, nie jako root/Jacek"):
          # sudo-rs dopasowuje DOKŁADNĄ ścieżkę /nix/store, nie gołą nazwę z PATH (ten sam
          # wymóg co claude-share wyżej) - stąd readlink/command -v, nie gołe "claude-run-command".
          # Wywołanie przez `sh -c "..."` (nie goły "-- id -un") naumyślnie, bo to dokładnie tak
          # woła to access-mcp.py - pierwsza wersja tego testu wołała claude-run-command
          # bezpośrednio, bez "sh -c", i przez to NIE złapała prawdziwego buga (gołe "sh" w "--
          # sh -c ..." nie rozwiązywało się przez PATH, bo sudo je resetuje - "exec: sh: not
          # found", znaleziony dopiero przy prawdziwym użyciu przez Claude Code).
          run_cmd = "sudo -n -u game_user \"$(readlink -f \"$(command -v claude-run-command)\")\" -- \"$(readlink -f \"$(command -v bash)\")\" -c 'echo -n $(whoami)'"
          assert pc.succeed(jako("Jacek", run_cmd)).strip() == "game_user"
          run_cmd_root = "sudo -n -u root \"$(readlink -f \"$(command -v claude-run-command)\")\" -- \"$(readlink -f \"$(command -v bash)\")\" -c 'echo -n $(whoami)'"
          assert pc.succeed(jako("Jacek", run_cmd_root)).strip() == "root"
          pc.fail(jako("claude", "sudo -n -u game_user \"$(readlink -f \"$(command -v claude-run-command)\")\" -- true"))
          pc.fail(jako("game_user", "sudo -n -u claude \"$(readlink -f \"$(command -v claude-run-command)\")\" -- true"))

      with subtest("kde-sync: eksport z Jacka, wgranie do game_user, inne konta bez dostępu do narzędzia"):
          # tak jak claude-share/claude-run-command wyżej: sudo-rs dopasowuje dokładną ścieżkę
          # /nix/store, nie gołą nazwę z PATH.
          kde_sync = "\"$(readlink -f \"$(command -v kde-sync)\")\""
          pc.succeed(jako("Jacek", "mkdir -p ~/.config && echo test-look > ~/.config/kwinrc"))
          pc.succeed(jako("Jacek", f"sudo -n {kde_sync} export"))
          pc.succeed("test \"$(stat -c '%U %G' /home/shared/KdeLook)\" = 'root shared'")
          pc.succeed(jako("Jacek", f"sudo -n {kde_sync} apply game_user"))
          pc.succeed("grep -q test-look /home/game_user/.config/kwinrc")
          pc.succeed("test \"$(stat -c '%U' /home/game_user/.config/kwinrc)\" = 'game_user'")
          pc.fail(jako("Jacek", f"sudo -n {kde_sync} apply root"))
          pc.fail(jako("game_user", f"sudo -n {kde_sync} apply claude"))
          pc.fail(jako("claude", "kde-sync export"))

      with subtest("szablon gry: druga instancja (dziecko-games) działa niezależnie od game_user"):
          pc.succeed("test \"$(id -u dziecko-games)\" != \"$(id -u game_user)\"")
          pc.succeed("test \"$(stat -c '%a %U' /home/dziecko-games)\" = '700 dziecko-games'")
          pc.succeed("grep -q 'ego --machinectl --user=dziecko-games steam' /run/current-system/sw/share/applications/dziecko-games-steam.desktop")
          pc.succeed("test \"$(stat -c '%a %U' /home/dziecko-games/SteamLibrary)\" = '700 dziecko-games'")
          pc.succeed("test -e /etc/systemd/user/dunst-dziecko-games.service")
          # obie instancje niezależne - swoje biblioteki, nie kolidują
          pc.fail(jako("game_user", "ls /home/dziecko-games"))
          pc.fail(jako("dziecko-games", "ls /mnt/games"))

      with subtest("sekrety sops: odszyfrowane, tylko dla roota"):
          pc.succeed("test \"$(cat /run/secrets/restic/haslo)\" = haslo-testowe-restic")
          pc.succeed("grep -q username=modele /run/secrets/nas/modele")
          pc.fail(jako("Jacek", "cat /run/secrets/restic/haslo"))
          pc.fail(jako("claude", "cat /run/secrets/nas/modele"))

      with subtest("restic: kopia na NAS przez rest-server (i przez OpenSnitch)"):
          pc.succeed(jacek("echo wazne > ~/Documents/wazne.txt && mkdir -p ~/.cache/x && echo smiec > ~/.cache/x/s"))
          pc.succeed("echo od-claude > /home/claude/pamiec.md && chown claude /home/claude/pamiec.md")
          pc.succeed("systemctl start restic-backups-nas.service")
          nas.succeed("test -n \"$(ls /var/lib/restic/pc/snapshots)\"")
          lista = pc.succeed("restic-nas ls latest")
          assert "/home/Jacek/Documents/wazne.txt" in lista, "brak pliku Jacka w kopii"
          assert "/home/claude/pamiec.md" in lista, "brak pamięci claude w kopii"
          assert "/home/Jacek/.cache/x/s" not in lista, "cache nie powinien być w kopii"
          assert "/home/secure-documents/wyciag.pdf" in lista, "brak dokumentów z banku w kopii"
          assert "/home/secure_user/" not in lista, "profil przeglądarki bankowej nie powinien trafiać do kopii"

      with subtest("NAS: udział Modele_3D montuje się na żądanie, pliki należą do Jacka"):
          nas.wait_for_unit("samba-smbd.service")
          nas.succeed("(echo haslo-testowe-smb; echo haslo-testowe-smb) | smbpasswd -s -a modele")
          pc.succeed(jako("Jacek", "ls /mnt/nas/Modele_3D | grep -q kostka.stl"))
          pc.succeed("test \"$(stat -c %U /mnt/nas/Modele_3D/kostka.stl)\" = Jacek")
          pc.succeed(jako("Jacek", "echo nowy > /mnt/nas/Modele_3D/z-pc.stl"))
          nas.succeed("grep -q nowy /srv/modele/z-pc.stl")
          pc.fail(jako("game_user", "ls /mnt/nas/Modele_3D"))
          pc.fail(jako("zeroroot", "ls /mnt/nas/Modele_3D"))
          pc.fail(jako("claude", "cat /mnt/nas/Modele_3D/kostka.stl"))
          pc.fail(jako("zeroroot", "ls /mnt/games"))
          pc.fail(jako("claude", "ls /mnt/games"))

      with subtest("ClamAV: plik z sygnaturą wykryty przy zapisie do Downloads i do wymiany zeroroot"):
          pc.wait_for_unit("clamav-daemon.service")
          pc.wait_for_unit("clamav-clamonacc.service")
          pc.sleep(5)
          pc.succeed(jacek("printf 'ZLOSLIWY-PLIK-TESTOWY-JUSTJACKPC\\n' > ~/Downloads/zly.txt && cat ~/Downloads/zly.txt > /dev/null"))
          pc.wait_until_succeeds("journalctl -u clamav-clamonacc -u clamav-daemon | grep -q 'Test.JustJack.Zly'", timeout=60)
          pc.succeed(jacek("printf 'ZLOSLIWY-PLIK-TESTOWY-JUSTJACKPC\\n' > /srv/zeroroot-exchange/zly2.txt && cat /srv/zeroroot-exchange/zly2.txt > /dev/null"))
          pc.wait_until_succeeds("journalctl -u clamav-clamonacc -u clamav-daemon | grep 'Test.JustJack.Zly' | grep -q zly2", timeout=60)
          pc.succeed(jako("browse_user", "printf 'ZLOSLIWY-PLIK-TESTOWY-JUSTJACKPC\\n' > /home/browse_user-downloads/zly3.txt && cat /home/browse_user-downloads/zly3.txt > /dev/null"))
          pc.wait_until_succeeds("journalctl -u clamav-clamonacc -u clamav-daemon | grep 'Test.JustJack.Zly' | grep -q zly3", timeout=60)
          pc.succeed(jacek("echo zwykly > ~/Downloads/ok.txt && cat ~/Downloads/ok.txt > /dev/null"))
          pc.sleep(5)
          pc.fail("journalctl -u clamav-clamonacc -u clamav-daemon | grep 'ok.txt' | grep -q FOUND")

      with subtest("hardening: sysctl, moduły, coredump"):
          for k, v in [("kernel.kptr_restrict", "2"), ("kernel.yama.ptrace_scope", "1"), ("kernel.kexec_load_disabled", "1"),
                       ("kernel.unprivileged_bpf_disabled", "1"), ("net.ipv4.conf.all.accept_redirects", "0"), ("kernel.sysrq", "4")]:
              assert pc.succeed(f"sysctl -n {k}").strip() == v, k
          pc.fail("modprobe sctp")
          pc.fail("modprobe bluetooth")
          pc.succeed("grep -q 'intel_iommu=on' /proc/cmdline && grep -q slab_nomerge /proc/cmdline")
          pc.succeed("systemd-analyze cat-config systemd/coredump.conf | grep -q 'Storage=none'")
          pc.succeed("auditctl -l | grep -q jako-root")
          pc.succeed("resolvectl status | grep -qi -- '-LLMNR'")

      with subtest("strażnik plików startowych"):
          pc.succeed(jacek("echo a > ~/.bashrc && systemctl --user start straznik-pliki-startowe"))
          pc.succeed(jacek("echo b >> ~/.bashrc && systemctl --user start straznik-pliki-startowe"))
          pc.succeed("journalctl -t straznik | grep -q 'Zmiana w plikach startowych'")
          pc.succeed(jacek("systemctl --user start straznik-miejsce"))

      with subtest("Lynis i weryfikacja sklepu startują"):
          pc.succeed("systemctl start lynis")

      with subtest("tryb awaryjny istnieje i jest bez hardeningu/OpenSnitch"):
          s = "/run/current-system/specialisation/awaryjny"
          pc.succeed(f"test -e {s}")
          pc.fail(f"grep -q slab_nomerge {s}/kernel-params")
          pc.fail(f"test -e {s}/etc/systemd/system/opensnitchd.service")

      with subtest("otwarte porty: nic nie nasłuchuje na zewnątrz poza mDNS/DHCP"):
          pc.succeed("systemctl stop kdec inny lokalny || true")
          tcp = pc.succeed("ss -Htln | awk '{print $4}' | grep -vE '^(127\\.|\\[::1\\]|::1)' || true").split()
          print("TCP poza localhost:", tcp)
          assert tcp == [], f"nasłuchujące porty TCP na zewnątrz: {tcp}"
          udp = pc.succeed("ss -Huln | awk '{print $4}' | grep -vE '^(127\\.|\\[::1\\]|::1)' || true").split()
          print("UDP poza localhost:", udp)
          for adres in udp:
              port = adres.rsplit(":", 1)[1]
              assert port in ["5353", "68", "546", "323"], f"nieoczekiwany port UDP: {adres}"
          # IPv6 z sieci: nic nie przechodzi (wyjątki zapory są tylko dla IPv4 z LAN)
          pc.succeed("systemd-run --unit=v6test python3 -m http.server 1716 --bind ::")
          pc.wait_for_open_port(1716)
          nas.fail("curl -6 -sf -m 5 'http://[2001:db8:1::2]:1716' > /dev/null")
          pc.succeed("systemctl stop v6test")

      with subtest("kopia restic da się ODTWORZYĆ (plik identyczny z oryginałem)"):
          pc.succeed("rm -rf /tmp/odtw && restic-nas restore latest --target /tmp/odtw --include /home/Jacek/Documents/wazne.txt")
          pc.succeed("cmp /tmp/odtw/home/Jacek/Documents/wazne.txt /home/Jacek/Documents/wazne.txt")
          pc.succeed("restic-nas check")

      with subtest("sekrety nie leżą jawnym tekstem w /etc ani w konfiguracji systemu"):
          pc.fail("grep -RIl --exclude-dir=static -e haslo-testowe-restic -e haslo-testowe-smb /etc 2>/dev/null | grep -v '^/etc/static' | head -1 | grep -q .")
          pc.fail("grep -Il -e haslo-testowe-restic -e haslo-testowe-smb $(find -L /run/current-system/etc -maxdepth 3 -type f 2>/dev/null) 2>/dev/null | head -1 | grep -q .")
          pc.succeed("test \"$(stat -c %a /run/secrets/restic/haslo)\" = 400")

      with subtest("awaria OpenSnitch: systemd podnosi demona w kilka sekund"):
          pc.succeed("systemctl kill -s KILL opensnitchd")
          pc.sleep(1)
          pc.wait_until_succeeds("systemctl is-active opensnitchd", timeout=15)
          pc.sleep(3)
          pc.fail(jako("Jacek", "curl -sf -m 8 http://nas > /dev/null"))  # znów kontrola

      with subtest("próby eskalacji: claude, game_user, secure_user, zeroroot, dev_user, browse_user"):
          for u in ["claude", "game_user", "secure_user", "zeroroot", "dev_user", "browse_user"]:
              pc.fail(jako(u, "sudo -n true"))
              pc.fail(jako(u, "cat /run/secrets/restic/haslo"))
              pc.fail(jako(u, "ls /var/lib/sops-nix"))
              pc.fail(jako(u, "cat /var/lib/sops-nix/key.txt"))
              pc.fail(jako(u, "machinectl shell --quiet --uid=Jacek .host /bin/true < /dev/null"))
              pc.fail(jako(u, "machinectl shell --quiet --uid=root .host /bin/true < /dev/null"))
              pc.fail(jako(u, "cat /home/Jacek/.config/gh/hosts.yml"))
          # claude nie może podmienić źródeł paczek (nie jest trusted-user)
          out = pc.execute(jako("claude", "nix --extra-experimental-features nix-command store info --option substituters http://nas 2>&1"))[1]
          print("claude + substituters:", out[-300:])
          assert "trusted" in out, "nix nie odrzucił źródła paczek od nie-zaufanego użytkownika"
          # moduły jądra i kexec
          pc.fail("modprobe dccp")
          pc.succeed("test \"$(sysctl -n kernel.kexec_load_disabled)\" = 1")

      with subtest("tryb awaryjny: przełączenie w działającym systemie i powrót"):
          glowny = pc.succeed("readlink -f /run/current-system").strip()
          pc.succeed("/run/current-system/specialisation/awaryjny/bin/switch-to-configuration test")
          pc.fail("systemctl is-active opensnitchd")
          pc.succeed(jako("Jacek", "sudo -n -u claude true"))  # sudo-rs i reguły działają też tu
          pc.succeed("test \"$(systemctl --failed --no-legend --plain | wc -l)\" = 0")
          pc.fail(jako("zeroroot", "curl -sf -m 5 http://nas > /dev/null"))  # zeroroot nadal bez sieci
          pc.succeed(f"{glowny}/bin/switch-to-configuration test")
          pc.wait_for_unit("opensnitchd.service")
          pc.succeed("test \"$(systemctl --failed --no-legend --plain | wc -l)\" = 0")

      with subtest("restart: wszystko wraca, tymczasowe udostępnienia dla claude znikają"):
          pc.succeed(jacek("claude-view -t 1h ~/Documents/t.txt"))
          pc.succeed("test -n \"$(ls -A /home/shared/Views/claude)\"")
          pc.shutdown()
          pc.start()
          pc.wait_for_unit("multi-user.target")
          pc.wait_for_unit("opensnitchd.service")
          pc.wait_for_unit("user@1000.service")
          pc.succeed("test \"$(systemctl --failed --no-legend --plain | wc -l)\" = 0")
          pc.succeed("test -z \"$(ls -A /home/shared/Views/claude 2>/dev/null)\"")
          pc.fail(jako("claude", "cat /home/Jacek/Documents/t.txt"))
          # ClaudeFiles to NIE jest tymczasowe udostępnienie - musi wrócić po restarcie samo.
          # ssh/config (nie CLAUDE.md - to nadpisywane co restart z założenia, zob. wyżej) musi
          # przetrwać, bo to prawdziwy zapis na dysku.
          pc.succeed("findmnt /home/shared/ClaudeFiles/ssh")
          pc.succeed(jacek("grep -q dopisek-jacka ~/Claude/ssh/config"))
          pc.succeed("test \"$(cat /run/secrets/restic/haslo)\" = haslo-testowe-restic")
          pc.fail(jako("zeroroot", "curl -sf -m 5 http://nas > /dev/null"))
          pc.sleep(3)
          pc.fail(jako("Jacek", "curl -sf -m 8 http://nas > /dev/null"))
          assert "nas-ok" in pc.succeed(jako("claude", "curl -sf -m 8 http://nas"))
          pc.succeed("test \"$(stat -c '%a %U' /home/shared/Projects)\" = '2770 Jacek'")
    '';
}
