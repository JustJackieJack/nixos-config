# Test dysków w maszynie wirtualnej: nix build .#checks.x86_64-linux.dyski -L
#
# Prawdziwy przebieg instalacji z hosts/justjackpc/disko.nix na dwóch wirtualnych dyskach:
# disko formatuje (GPT + ESP + btrfs z podwoluminami, Lexar ext4), instalacja i rozruch od nowa.
# Różnice wobec prawdziwego systemu: bez Secure Boot, bez pulpitu.
{ pkgs, inputs }:
let
  inherit (pkgs) lib;
  diskoLib = import "${inputs.disko}/lib" {
    inherit lib;
    makeTest = import "${pkgs.path}/nixos/tests/make-test-python.nix";
    eval-config = import "${pkgs.path}/nixos/lib/eval-config.nix";
    qemu-common = import "${pkgs.path}/nixos/lib/qemu-common.nix";
  };
in
diskoLib.testLib.makeDiskoTest {
  inherit pkgs;
  name = "justjackpc-dyski";
  disko-config = import ../hosts/justjackpc/disko.nix;

  extraSystemConfig =
    { lib, ... }:
    {
      imports = [
        inputs.lanzaboote.nixosModules.lanzaboote
        inputs.sops-nix.nixosModules.sops
        ../modules
      ];
      # makeDiskoTest nie ma haczyka na specialArgs (inaczej niż pkgs.testers.runNixOSTest w
      # tests/vm.nix/pulpit.nix) - ../modules (games.nix) potrzebuje "inputs" jako argumentu
      # modułu (nixpkgs-unstable), więc dopisujemy go tak samo jak specialArgs by to zrobiło.
      _module.args.inputs = inputs;
      networking.hostName = "pc";
      moje.lan = "192.168.1.0/24";
      moje.secureBoot.enable = false;
      system.stateVersion = "26.05";
      # lżej (maszyna testowa ma 1 GB RAM): bez pulpitu i ciężkich usług
      services.xserver.videoDrivers = lib.mkForce [ "modesetting" ];
      services.displayManager.sddm.enable = lib.mkForce false;
      services.clamav.daemon.enable = lib.mkForce false;
      services.clamav.clamonacc.enable = lib.mkForce false;
      services.clamav.updater.enable = lib.mkForce false;
      services.smartd.enable = lib.mkForce false;
      services.opensnitch.enable = lib.mkForce false;
    };

  extraTestScript = ''
    machine.wait_for_unit("multi-user.target")

    with subtest("podwoluminy btrfs i punkty montowania jak w disko.nix"):
        for punkt, subvol in [("/", "@"), ("/home", "@home"), ("/home/.snapshots", "@home-snapshots"),
                              ("/home/game_user", "@game_user"), ("/nix", "@nix"), ("/var/log", "@log")]:
            if punkt == "/nix":
                continue  # w teście /nix/store jest podmontowany z hosta (9p)
            opcje = machine.succeed(f"findmnt -n -o FSTYPE,OPTIONS {punkt}")
            assert opcje.startswith("btrfs"), (punkt, opcje)
            assert f"subvol=/{subvol}" in opcje, (punkt, opcje)
            assert "compress=zstd:1" in opcje and "noatime" in opcje, (punkt, opcje)
        machine.succeed("btrfs subvolume list / | grep -q ' @nix$'")
        assert machine.succeed("findmnt -n -o FSTYPE /mnt/games").strip() == "ext4"
        assert machine.succeed("findmnt -n -o FSTYPE /boot").strip() == "vfat"
        machine.succeed("test \"$(stat -c '%a %U' /mnt/games)\" = '700 game_user'")
        machine.succeed("test \"$(stat -c '%a %U' /home/game_user)\" = '700 game_user'")
        machine.succeed("test \"$(stat -c %a /boot)\" = 700")  # umask=0077 na ESP

    with subtest("jeden wspólny btrfs: /home i system dzielą wolne miejsce"):
        przed = int(machine.succeed("df --output=avail / | tail -1"))
        machine.succeed("dd if=/dev/urandom of=/home/Jacek/duzy bs=1M count=300 status=none && sync")
        machine.sleep(2)
        po = int(machine.succeed("df --output=avail / | tail -1"))
        print(f"wolne na /: przed={przed} po={po} KiB")
        assert przed - po > 200 * 1024, "zapis w /home nie zmniejszył wolnego miejsca na / – to nie jest wspólna pula"
        machine.succeed("rm /home/Jacek/duzy")

    with subtest("snapper: migawki /home, Jacek może je przeglądać, dom game_usera poza migawkami"):
        machine.succeed("echo wersja1 > /home/Jacek/notatka.txt && echo gra > /home/game_user/save.dat")
        machine.succeed("snapper -c home create -d test-migawka")
        machine.succeed("echo wersja2 > /home/Jacek/notatka.txt")
        lista = machine.succeed("runuser -u Jacek -- snapper -c home list")
        print(lista)
        assert "test-migawka" in lista
        nr = machine.succeed("snapper -c home list --columns number,description | grep test-migawka | awk '{print $1}'").strip()
        assert machine.succeed(f"cat /home/.snapshots/{nr}/snapshot/Jacek/notatka.txt").strip() == "wersja1"
        machine.fail(f"test -e /home/.snapshots/{nr}/snapshot/game_user/save.dat")
        machine.succeed("systemctl start snapper-timeline.service snapper-cleanup.service")
        # systemctl start wraca, zanim usługa skończy – czekamy na migawkę „timeline”
        machine.wait_until_succeeds("snapper -c home list | grep -q timeline", timeout=30)

    with subtest("scrub btrfs działa"):
        machine.succeed("btrfs scrub start -B /")

    with subtest("wpisy rozruchu: główny + awaryjny"):
        machine.succeed("bootctl list --no-pager | grep -qi awaryjny")
  '';
}
