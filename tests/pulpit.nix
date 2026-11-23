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
        pkgs.xdpyinfo
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
        # (pgrep -f: w NixOS programy są opakowane, więc nazwa procesu to np. .plasmashell-wrapped)
        env = (
            "export $(tr '\\0' '\\n' < /proc/$(pgrep -u Jacek -f bin/plasmashell | head -1)/environ"
            " | grep -E '^(WAYLAND_DISPLAY|DISPLAY|XDG_RUNTIME_DIR|DBUS_SESSION_BUS_ADDRESS|XAUTHORITY)=' | xargs)"
        )
        return f"{env}; runuser -u {user} -- env WAYLAND_DISPLAY=$WAYLAND_DISPLAY DISPLAY=$DISPLAY XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS=$DBUS_SESSION_BUS_ADDRESS XAUTHORITY=$XAUTHORITY sh -c {shlex.quote(cmd)}"

    start_all()
    pc.wait_for_unit("display-manager.service")

    with subtest("Plasma (Wayland) startuje dla Jacka"):
        pc.wait_until_succeeds("pgrep -u Jacek -f bin/plasmashell", timeout=300)
        pc.wait_until_succeeds("pgrep -u Jacek -f bin/kwin_wayland", timeout=60)
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
        # jak skrót z menu: przez menedżera usług Jacka (proces w tle w powłoce testu by zginął)
        pc.succeed(w_sesji("Jacek", "systemd-run --user --collect --unit=konsole-game-user ego --machinectl --user=game_user konsole"))
        pc.wait_until_succeeds("pgrep -u game_user -f konsole", timeout=60)
        pc.sleep(5)
        pc.screenshot("2-konsole-game_user")

    with subtest("zeroroot-uruchom: ego uruchamia gamescope jako zeroroot"):
        pc.succeed(w_sesji("Jacek", "systemd-run --user --collect --unit=zeroroot-gamescope zeroroot-uruchom sh -c 'sleep 30'"))
        pc.sleep(10)
        dziennik = pc.execute(w_sesji("Jacek", "journalctl --user -u zeroroot-gamescope --no-pager"))[1]
        assert "/home/zeroroot/.config/gamescope" in dziennik, "gamescope nie wystartował jako zeroroot:\n" + dziennik[-2000:]
        if "VK_EXT_physical_device_drm" in dziennik:
            print("OGRANICZENIE MASZYNY WIRTUALNEJ: gamescope wymaga prawdziwej karty (Vulkan z DRM) – "
                  "llvmpipe go nie ma. Na RTX 2070 sprawdzić ręcznie: zeroroot-uruchom kitty")
        pc.screenshot("3-zeroroot-gamescope")

    with subtest("piaskownica zeroroot (bubblewrap) uruchomiona przez ego – bez gamescope"):
        wnetrze = pc.succeed("grep -o '/nix/store/[^ ]*-zeroroot-wnetrze/bin/zeroroot-wnetrze' $(readlink -f $(command -v zeroroot-uruchom)) | head -1").strip()
        skrypt = (
            "id -un; echo XDG=$XDG_RUNTIME_DIR; echo RUN_USER=[$(ls -A /run/user)]; "
            "echo WAYLAND=[$WAYLAND_DISPLAY]; echo PULSE=[$PULSE_SERVER]; "
            "(curl -sm3 http://127.0.0.1 > /dev/null 2>&1 && echo SIEC=JEST || echo SIEC=BRAK); "
            "(ls /home/Jacek > /dev/null 2>&1 && echo DOM_JACKA=WIDAC || echo DOM_JACKA=ZAMKNIETY); "
            "(ls /home/wspolne > /dev/null 2>&1 && echo WSPOLNE=WIDAC || echo WSPOLNE=ZAMKNIETE); "
            "(touch /etc/x 2>/dev/null && echo SYSTEM=ZAPIS || echo SYSTEM=TYLKO_ODCZYT); "
            "(touch /srv/zeroroot-wymiana/ok 2>/dev/null && echo WYMIANA=ZAPIS || echo WYMIANA=BRAK); "
            "(ls /dev/dri > /dev/null 2>&1 && echo GPU=JEST || echo GPU=BRAK); "
            "echo PROCESY=$(ls /proc | grep -c '^[0-9]')"
        )
        wynik = pc.succeed(w_sesji("Jacek", f"ego --machinectl --user=zeroroot {wnetrze} sh -c {shlex.quote(skrypt)} < /dev/null"))
        print("WYNIK PIASKOWNICY:\n" + wynik)
        assert "zeroroot" in wynik
        assert "XDG=/tmp/run" in wynik
        assert "RUN_USER=[]" in wynik, "w piaskownicy widać /run/user (Wayland/dźwięk Jacka)"
        assert "WAYLAND=[]" in wynik and "PULSE=[]" in wynik
        assert "SIEC=BRAK" in wynik
        assert "DOM_JACKA=ZAMKNIETY" in wynik and "WSPOLNE=ZAMKNIETE" in wynik
        assert "SYSTEM=TYLKO_ODCZYT" in wynik and "WYMIANA=ZAPIS" in wynik
        assert "GPU=JEST" in wynik
        procesy = int(wynik.split("PROCESY=")[1].split()[0])
        assert procesy < 6, f"piaskownica widzi {procesy} procesów"
  '';
}
