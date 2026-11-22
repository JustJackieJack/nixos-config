# Test w maszynie wirtualnej: nix build .#checks.x86_64-linux.vm -L
#
# Uruchamia NASZE moduły (modules/) na wirtualnym „pc” obok wirtualnego „nas” (udaje LAN)
# i sprawdza zachowanie na żywym systemie. Pominięte, bo wymagają prawdziwego sprzętu:
# NVIDIA, Secure Boot, LUKS/disko, ekran logowania (SDDM), snapper (wymaga btrfs),
# ClamAV (bez internetu nie pobierze bazy wirusów), smartd (wirtualne dyski bez SMART).
{ pkgs, inputs }:
pkgs.testers.runNixOSTest {
  name = "justjackpc";

  node.specialArgs = { inherit inputs; };
  node.pkgsReadOnly = false; # nasze moduły ustawiają nixpkgs.config (licencje)

  nodes.nas = {
    networking.firewall.allowedTCPPorts = [ 80 ];
    services.nginx = {
      enable = true;
      virtualHosts.default.locations."/".return = "200 'nas-ok'";
    };
  };

  nodes.pc =
    { lib, ... }:
    {
      imports = [
        inputs.lanzaboote.nixosModules.lanzaboote
        inputs.sops-nix.nixosModules.sops
        ../modules
      ];

      networking.hostName = "pc";
      moje.lan = "192.168.1.0/24"; # sieć testowa
      moje.secureBoot.enable = false;
      system.stateVersion = "26.05";

      # --- tylko na potrzeby testu (sprzęt / internet) ---
      services.xserver.videoDrivers = lib.mkForce [ "modesetting" ];
      services.displayManager.sddm.enable = lib.mkForce false;
      services.clamav.daemon.enable = lib.mkForce false;
      services.clamav.clamonacc.enable = lib.mkForce false;
      services.clamav.updater.enable = lib.mkForce false;
      services.snapper.configs = lib.mkForce { };
      services.smartd.enable = lib.mkForce false; # wirtualne dyski nie mają SMART
      networking.networkmanager.unmanaged = [ "eth1" ]; # adres nadaje framework testów
      users.users.Jacek.linger = true; # menedżer usług Jacka bez logowania (daj-claude, strażnik)
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
          pc.succeed("test \"$(stat -c '%a %U %G' /home/wspolne/Projekty)\" = '2770 Jacek wspolne'")
          pc.succeed("test \"$(stat -c '%a %U %G' /srv/zeroroot-wymiana)\" = '2770 zeroroot zeroroot-wymiana'")
          pc.succeed("test \"$(stat -c '%a %U' /home/game_user)\" = '700 game_user'")
          pc.succeed("test \"$(readlink /home/Jacek/Projekty)\" = /home/wspolne/Projekty")
          pc.succeed("test \"$(stat -c '%a %U' /mnt/games)\" = '750 game_user'")

      with subtest("hidepid: game_user widzi tylko swoje procesy, Jacek wszystkie"):
          g = int(pc.succeed(jako("game_user", "ps -e --no-headers | wc -l")))
          j = int(pc.succeed(jako("Jacek", "ps -e --no-headers | wc -l")))
          print(f"procesy: game_user={g} Jacek={j}")
          assert g < 6 and j > 40, (g, j)

      with subtest("polkit + machinectl (droga ego): Jacek → game_user/claude/zeroroot bez hasła, root nie"):
          for u, n in [("game_user", 1002), ("claude", 1001), ("zeroroot", 1003)]:
              out = pc.succeed(jako("Jacek", f"machinectl shell --quiet --uid={u} .host /bin/sh -c 'id -u' < /dev/null"))
              assert str(n) in out, (u, out)
          pc.fail(jako("Jacek", "machinectl shell --quiet --uid=root .host /bin/sh -c 'id -u' < /dev/null"))
          pc.fail(jako("game_user", "machinectl shell --quiet --uid=zeroroot .host /bin/true < /dev/null"))

      with subtest("sudo-rs"):
          assert pc.succeed(jako("Jacek", "sudo -n -u claude id -u")).strip() == "1001"
          pc.fail(jako("Jacek", "sudo -n true"))  # root wymaga hasła
          pc.fail(jako("Jacek", "sudo -n -u game_user true"))  # tylko claude bez hasła
          pc.fail(jako("game_user", "sudo -n true"))  # execWheelOnly: nie może nawet uruchomić sudo

      with subtest("foldery wspólne: Jacek i claude piszą sobie nawzajem"):
          pc.succeed(jako("Jacek", "echo od-jacka > /home/wspolne/Projekty/a.txt"))
          pc.succeed(jako("claude", "echo dopisek >> /home/wspolne/Projekty/a.txt && mkdir /home/wspolne/Projekty/kat && echo c > /home/wspolne/Projekty/kat/b.txt"))
          pc.succeed(jako("Jacek", "echo d >> /home/wspolne/Projekty/kat/b.txt"))
          pc.fail(jako("game_user", "ls /home/wspolne/Projekty"))

      with subtest("daj-claude / zabierz-claude / pokaz-claude"):
          pc.succeed(jacek("mkdir -p ~/Documents ~/.config/gh ~/Projekt2 && echo tajne > ~/Documents/t.txt && chmod 600 ~/Documents/t.txt && echo token > ~/.config/gh/hosts.yml && echo a > ~/Projekt2/f"))
          pc.fail(jako("claude", "cat /home/Jacek/Documents/t.txt"))
          pc.fail(jacek("daj-claude ~/.config"))  # zawiera sekret
          pc.fail(jacek("daj-claude ~/.config/gh/hosts.yml"))  # sam sekret
          pc.fail(jacek("daj-claude ~"))  # cały dom
          pc.fail(jacek("daj-claude -t zly ~/Documents/t.txt"))  # zły czas
          out = pc.succeed(jacek("daj-claude -t 10s ~/Documents/t.txt"))
          cel = out.split("→ ")[1].split(" ")[0]
          print("udostępniono:", cel)
          assert pc.succeed(jako("claude", f"cat {cel}")).strip() == "tajne"
          pc.fail(jako("claude", f"echo x >> {cel}"))  # tylko odczyt
          # dom Jacka nadal zamknięty – także dla plików 644 (to był błąd poprzedniej wersji)
          pc.fail(jako("claude", "cat /home/Jacek/Documents/t.txt"))
          pc.fail(jako("claude", "cat /home/Jacek/.config/gh/hosts.yml"))
          pc.fail(jako("claude", "ls /home/Jacek"))
          # katalog z zapisem + zabranie od razu
          out = pc.succeed(jacek("daj-claude -w -t 1h ~/Projekt2"))
          cel2 = out.split("→ ")[1].split(" ")[0]
          pc.succeed(jako("claude", f"echo od-claude >> {cel2}/f"))
          pc.succeed(jako("Jacek", "grep -q od-claude /home/Jacek/Projekt2/f"))
          pc.succeed(jacek("zabierz-claude ~/Projekt2"))
          pc.fail(jako("claude", f"cat {cel2}/f"))
          pc.fail(f"test -e {cel2}")
          # wygaśnięcie
          pc.sleep(15)
          pc.fail(jako("claude", f"cat {cel}"))
          pc.fail(f"test -e {cel}")
          # atak: pomocnik root dostaje dowiązanie do pliku roota → musi odmówić
          pc.succeed(jacek("ln -s /etc/shadow ~/Documents/zly && ln -s /root ~/Documents/zlykat"))
          pc.fail(jacek("sudo -n \"$(readlink -f \"$(command -v claude-montuj)\")\" dodaj ro /home/Jacek/Documents/zly 1h"))
          pc.fail(jacek("sudo -n \"$(readlink -f \"$(command -v claude-montuj)\")\" dodaj ro /home/Jacek/Documents/zlykat 1h"))
          pc.fail(jacek("sudo -n \"$(readlink -f \"$(command -v claude-montuj)\")\" dodaj ro /etc/shadow 1h"))
          pc.fail(jacek("sudo -n \"$(readlink -f \"$(command -v claude-montuj)\")\" zabierz /etc"))
          pc.succeed("test -z \"$(ls -A /home/wspolne/Udostepnione)\"")
          pc.succeed("! findmnt -rn -o TARGET | grep -q Udostepnione")
          # inny użytkownik nie może użyć pomocnika
          pc.fail(jako("game_user", "sudo -n /run/current-system/sw/bin/claude-montuj zabierz"))
          pc.succeed(jacek("pokaz-claude ~/Documents/t.txt"))
          pc.succeed(jako("claude", "cat /home/wspolne/Dla_Claude/t.txt_*"))

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

      with subtest("OpenSnitch: ścieżki w regułach to prawdziwe pliki, nie dowiązania"):
        out = pc.succeed("grep -ho '\"data\":\"/nix/store/[^\"]*' /var/lib/opensnitch/rules/*.json | cut -d'\"' -f4")
        for sciezka in out.split():
            pc.succeed(f"test -f {sciezka} && test ! -L {sciezka} && test \"$(readlink -f {sciezka})\" = {sciezka}")

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
    '';
}
