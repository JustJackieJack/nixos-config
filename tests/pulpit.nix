# Test pulpitu w maszynie wirtualnej: nix build .#checks.x86_64-linux.pulpit -L
#
# SDDM loguje Jacka automatycznie do Plasmy (Wayland). Sprawdzamy to, czego test bez pulpitu
# nie widzi: okno pytań OpenSnitch w sesji, strażnika w sesji, ego (program okienkowy i dźwięk
# jako game_user) oraz zeroroot-uruchom (ego → gamescope → bubblewrap).
# Grafika: wirtualna karta + programowy OpenGL/Vulkan (llvmpipe/lavapipe) – bez NVIDIA.
{ pkgs, inputs }:
pkgs.testers.runNixOSTest {
  name = "justjackpc-pulpit";

  node.specialArgs = { inherit inputs; };
  node.pkgsReadOnly = false;

  nodes.pc =
    { lib, pkgs, ... }:
    {
      imports = [
        inputs.lanzaboote.nixosModules.lanzaboote
        inputs.sops-nix.nixosModules.sops
        ../modules
      ];

      networking.hostName = "pc";
      moje.lan = "192.168.1.0/24";
      moje.secureBoot.enable = false;
      system.stateVersion = "26.05";

      # --- tylko na potrzeby testu ---
      services.xserver.videoDrivers = lib.mkForce [ "modesetting" ];
      environment.sessionVariables.LIBVA_DRIVER_NAME = lib.mkForce "";
      services.displayManager.autoLogin = {
        enable = true;
        user = "Jacek";
      };
      services.displayManager.defaultSession = "plasma";
      services.clamav.daemon.enable = lib.mkForce false;
      services.clamav.clamonacc.enable = lib.mkForce false;
      services.clamav.updater.enable = lib.mkForce false;
      services.snapper.configs = lib.mkForce { };
      services.smartd.enable = lib.mkForce false;
      networking.networkmanager.unmanaged = [ "eth1" ];
      environment.systemPackages = [
        pkgs.pulseaudio # pactl – sprawdzenie dźwięku
        pkgs.wayland-utils # wayland-info
        pkgs.xorg.xdpyinfo
      ];
      virtualisation = {
        memorySize = 6144;
        cores = 4;
        diskSize = 4096;
        qemu.options = [
          "-vga none"
          "-device virtio-vga"
        ];
      };
    };

  testScript = ''
    import shlex

    def w_sesji(user, cmd):
        # polecenie jako Jacek ze środowiskiem jego sesji Plasma (Wayland, X, D-Bus)
        env = (
            "export $(tr '\\0' '\\n' < /proc/$(pgrep -u Jacek -x plasmashell | head -1)/environ"
            " | grep -E '^(WAYLAND_DISPLAY|DISPLAY|XDG_RUNTIME_DIR|DBUS_SESSION_BUS_ADDRESS|XAUTHORITY)=' | xargs)"
        )
        return f"{env}; runuser -u {user} -- env WAYLAND_DISPLAY=$WAYLAND_DISPLAY DISPLAY=$DISPLAY XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS=$DBUS_SESSION_BUS_ADDRESS XAUTHORITY=$XAUTHORITY sh -c {shlex.quote(cmd)}"

    start_all()
    pc.wait_for_unit("display-manager.service")

    with subtest("Plasma (Wayland) startuje dla Jacka"):
        pc.wait_until_succeeds("pgrep -u Jacek -x plasmashell", timeout=300)
        pc.wait_until_succeeds("pgrep -u Jacek -x kwin_wayland", timeout=60)
        pc.sleep(15)
        pc.screenshot("1-pulpit")

    with subtest("okno pytań OpenSnitch działa w sesji Jacka i jest połączone z demonem"):
        pc.wait_until_succeeds("pgrep -u Jacek -f opensnitch-ui", timeout=120)
        pc.wait_until_succeeds("journalctl -u opensnitchd | grep -qiE 'ui.*connect|connected'", timeout=120)

    with subtest("strażnik działa w sesji Jacka (liczniki)"):
        out = pc.succeed(w_sesji("Jacek", "systemctl --user list-timers --all --no-pager"))
        assert "straznik-pliki-startowe" in out and "straznik-miejsce" in out, out

    with subtest("menu: zwykły Steam/Heroic/Chromium ukryte, są wersje game_user/claude"):
        sw = "/run/current-system/sw/share/applications"
        for f in ["steam.desktop", "com.heroicgameslauncher.hgl.desktop", "chromium-browser.desktop"]:
            pc.succeed(f"grep -q '^Hidden=true' {sw}/{f}")
        pc.succeed(f"grep -q 'ego --machinectl --user=game_user steam' {sw}/Steam-game-user.desktop")
        pc.succeed(f"grep -q 'ego --machinectl --user=claude chromium' {sw}/chromium-claude.desktop")

    with subtest("ego: program jako game_user widzi ekran i dźwięk Jacka"):
        out = pc.succeed(w_sesji("Jacek", "ego --machinectl --user=game_user sh -c 'id -un; wayland-info > /dev/null && echo WAYLAND-OK; pactl info | grep -i \"server name\"' < /dev/null"))
        print(out)
        assert "game_user" in out, out
        assert "WAYLAND-OK" in out, "game_user nie łączy się z Wayland Jacka"
        assert "PipeWire" in out or "PulseAudio" in out, "game_user nie ma dźwięku"
        # okno programu jako game_user
        pc.execute(w_sesji("Jacek", "ego --machinectl --user=game_user konsole > /dev/null 2>&1 < /dev/null &"))
        pc.wait_until_succeeds("pgrep -u game_user -x konsole", timeout=60)
        pc.sleep(5)
        pc.screenshot("2-konsole-game_user")

    with subtest("zeroroot-uruchom: ego → gamescope → bubblewrap"):
        skrypt = (
            "id -un > /srv/zeroroot-wymiana/wynik; "
            "echo XDG=$XDG_RUNTIME_DIR >> /srv/zeroroot-wymiana/wynik; "
            "echo RUN_USER=[$(ls -A /run/user)] >> /srv/zeroroot-wymiana/wynik; "
            "echo WAYLAND=$WAYLAND_DISPLAY >> /srv/zeroroot-wymiana/wynik; "
            "(curl -sm3 http://192.168.1.1 > /dev/null && echo SIEC=JEST || echo SIEC=BRAK) >> /srv/zeroroot-wymiana/wynik; "
            "(ls /home/Jacek > /dev/null 2>&1 && echo DOM_JACKA=WIDAC || echo DOM_JACKA=ZAMKNIETY) >> /srv/zeroroot-wymiana/wynik; "
            "(touch /etc/x 2>/dev/null && echo SYSTEM=ZAPIS || echo SYSTEM=TYLKO_ODCZYT) >> /srv/zeroroot-wymiana/wynik; "
            "(ls /dev/dri > /dev/null 2>&1 && echo GPU=JEST || echo GPU=BRAK) >> /srv/zeroroot-wymiana/wynik; "
            "echo KONIEC >> /srv/zeroroot-wymiana/wynik; sleep 20"
        )
        pc.execute(w_sesji("Jacek", f"zeroroot-uruchom sh -c {shlex.quote(skrypt)} > /tmp/zeroroot.log 2>&1 < /dev/null &"))
        r = pc.execute("for i in $(seq 1 60); do grep -q KONIEC /srv/zeroroot-wymiana/wynik 2>/dev/null && break; sleep 2; done; cat /srv/zeroroot-wymiana/wynik")
        print("WYNIK ZEROROOT:\n" + r[1])
        print("LOG:\n" + pc.execute("cat /tmp/zeroroot.log")[1])
        pc.screenshot("3-zeroroot-gamescope")
        wynik = r[1]
        assert "zeroroot" in wynik, "program nie wystartował jako zeroroot (gamescope/ego?)"
        assert "RUN_USER=[]" in wynik, "w piaskownicy widać /run/user"
        assert "WAYLAND=" in wynik and "WAYLAND=wayland" not in wynik, "piaskownica ma dostęp do Wayland Jacka"
        assert "SIEC=BRAK" in wynik
        assert "DOM_JACKA=ZAMKNIETY" in wynik
        assert "SYSTEM=TYLKO_ODCZYT" in wynik
        assert "GPU=JEST" in wynik
  '';
}
