# Utwardzenie bez hardened kernela (ten łamie NVIDIA i przestrzenie nazw).
# Świadomie POMINIĘTE: lockdown, module.sig_enforce (łamią NVIDIA), ptrace_scope=2 (gry, debugery),
# init_on_free (wydajność), AppArmor/SELinux (na NixOS praktycznie nie działają), USBGuard.
# Blok „hardening” wyłącza tryb awaryjny w menu rozruchu (awaryjny.nix); sudo-rs i dbus-broker zostają.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.moje.hardening;

  # Moduły, których się nie da załadować (nie tylko blacklist – blacklist blokuje tylko autoload).
  zablokowaneModuly = [
    # rzadkie protokoły sieciowe (historia dziur)
    "dccp"
    "sctp"
    "rds"
    "tipc"
    # interfejsy z dostępem DMA, których ta płyta nie ma
    "firewire-core"
    "firewire-ohci"
    "thunderbolt"
    # stare / nieużywane systemy plików
    "cramfs"
    "freevxfs"
    "jffs2"
    "hfs"
    "hfsplus"
    # Bluetooth (nieużywany)
    "bluetooth"
    "btusb"
  ];
in
{
  config = lib.mkMerge [
    # Zawsze (także w trybie awaryjnym) – to nie psuje programów, a reguły sudo (claude.nix)
    # muszą działać w obu wariantach.
    {
      # sudo-rs (Rust) zamiast sudo; tylko grupa wheel może w ogóle uruchomić sudo.
      security.sudo.enable = false;
      security.sudo-rs = {
        enable = true;
        execWheelOnly = true;
        wheelNeedsPassword = true;
      };

      # dbus-broker – nowsza, szybsza implementacja D-Bus.
      services.dbus.implementation = "broker";
    }

    (lib.mkIf cfg.enable {
      boot.kernel.sysctl = {
        # jądro
        "kernel.kptr_restrict" = 2;
        "kernel.dmesg_restrict" = 1;
        "kernel.yama.ptrace_scope" = 1; # tylko rodzic może śledzić proces (gry/Proton działają)
        "kernel.unprivileged_bpf_disabled" = 1;
        "net.core.bpf_jit_harden" = 2;
        "kernel.sysrq" = 4; # tylko klawiatura (SAK), bez reszty SysRq
        "kernel.perf_event_paranoid" = 3; # zwykłe jądro traktuje 3 jak 2 (najsurowsze) – zostawiamy
        "fs.suid_dumpable" = 0;
        "dev.tty.ldisc_autoload" = 0;
        "vm.unprivileged_userfaultfd" = 0;
        "fs.protected_fifos" = 2;
        "fs.protected_regular" = 2;
        "vm.max_map_count" = 1048576; # część gier tego wymaga

        # sieć (rp_filter – patrz checkReversePath w siec.nix)
        "net.ipv4.conf.all.accept_redirects" = 0;
        "net.ipv4.conf.default.accept_redirects" = 0;
        "net.ipv4.conf.all.secure_redirects" = 0;
        "net.ipv4.conf.default.secure_redirects" = 0;
        "net.ipv6.conf.all.accept_redirects" = 0;
        "net.ipv6.conf.default.accept_redirects" = 0;
        "net.ipv4.conf.all.send_redirects" = 0;
        "net.ipv4.conf.default.send_redirects" = 0;
        "net.ipv4.conf.all.accept_source_route" = 0;
        "net.ipv4.conf.default.accept_source_route" = 0;
        "net.ipv6.conf.all.accept_source_route" = 0;
        "net.ipv6.conf.default.accept_source_route" = 0;
        "net.ipv4.tcp_syncookies" = 1;
        "net.ipv4.conf.all.log_martians" = 1;
        "net.ipv4.icmp_echo_ignore_broadcasts" = 1;
      };

      boot.kernelParams = [
        "randomize_kstack_offset=on"
        "page_alloc.shuffle=1"
        "slab_nomerge"
        "init_on_alloc=1"
        "vsyscall=none"
        "debugfs=off"
      ];

      boot.blacklistedKernelModules = zablokowaneModuly;
      boot.extraModprobeConfig = lib.concatMapStrings (
        m: "install ${m} ${pkgs.coreutils}/bin/false\n"
      ) zablokowaneModuly;

      # Bez kexec (podmiana działającego jądra w locie) i bez hibernacji.
      security.protectKernelImage = true;

      # Zrzuty pamięci programów mogą zawierać hasła – nie zapisujemy ich.
      systemd.coredump.settings.Coredump.Storage = "none";
    })

    # hidepid: zwykli użytkownicy widzą tylko swoje procesy.
    # Grupa proc (gid 2000, uzytkownicy.nix: Jacek, claude + logind, polkit) widzi wszystko.
    (lib.mkIf (cfg.enable && cfg.hidepid) {
      boot.specialFileSystems."/proc".options = [
        "hidepid=2"
        "gid=2000"
      ];
      systemd.services.systemd-logind.serviceConfig.SupplementaryGroups = [ "proc" ];
      systemd.services.polkit.serviceConfig.SupplementaryGroups = [ "proc" ];
    })
  ];
}
