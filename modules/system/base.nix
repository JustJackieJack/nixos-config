# Podstawy: język, czas, Nix, rozruch, pamięć wymiany, dziennik.
{ config, lib, ... }:
{
  # --- Język: interfejs po angielsku, klawiatura i formaty po polsku ---
  time.timeZone = "Europe/Warsaw";
  i18n.defaultLocale = "en_US.UTF-8";
  i18n.extraLocaleSettings = {
    LC_TIME = "pl_PL.UTF-8"; # data, godzina, pierwszy dzień tygodnia
    LC_MONETARY = "pl_PL.UTF-8"; # waluta
    LC_MEASUREMENT = "pl_PL.UTF-8"; # jednostki metryczne
    LC_PAPER = "pl_PL.UTF-8"; # A4
    LC_ADDRESS = "pl_PL.UTF-8";
    LC_TELEPHONE = "pl_PL.UTF-8";
    LC_NAME = "pl_PL.UTF-8";
    # LC_NUMERIC zostaje angielski (kropka dziesiętna) – polski przecinek psuje skrypty i CSV.
  };
  console.keyMap = "pl";
  services.xserver.xkb.layout = "pl";

  # --- Nix ---
  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    # Z demona Nix korzystają tylko Jacek, claude i straznik (vulnix pyta o zależności);
    # game_user i zeroroot nie.
    allowed-users = [
      "Jacek"
      "claude"
      "straznik"
    ];
    # trusted-users zostaje domyślne (tylko root): nikt inny nie doda niepodpisanych paczek.
    auto-optimise-store = true;
  };
  nix.channel.enable = false; # tylko flake
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };
  # Licencje niewolne: wypisane z nazwy, żeby nic nie weszło „przy okazji”.
  nixpkgs.config.allowUnfreePredicate =
    pkg:
    builtins.elem (lib.getName pkg) [
      "nvidia-x11"
      "nvidia-settings"
      "steam"
      "steam-unwrapped"
      "discord"
      "obsidian"
      "vscode"
      "claude-code"
      "flashprint"
    ];

  # --- Rozruch ---
  # systemd w initrd - niezależne od LUKS (kiedyś wymagane dla FIDO2 przy odblokowaniu, dziś
  # zostaje jako nowoczesny domyślny stage 1, i tak obowiązkowy od NixOS 26.11+).
  boot.initrd.systemd.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.systemd-boot = {
    enable = lib.mkDefault true; # lanzaboote wyłącza to w secure-boot.nix
    editor = false; # bez edycji parametrów jądra z menu rozruchu
    configurationLimit = 15;
  };
  boot.loader.timeout = 3;
  # IOMMU nie dla VM, tylko jako ochrona przed atakami DMA.
  boot.kernelParams = [ "intel_iommu=on" ];

  # ~/.local/bin w PATH (win7-rdp.sh, ffmpeg_mkv_convert i inne własne skrypty).
  environment.localBinInPath = true;

  # --- Pamięć, /tmp, dziennik ---
  zramSwap.enable = true; # bez partycji wymiany i bez hibernacji
  boot.tmp.useTmpfs = true;
  services.journald.extraConfig = ''
    SystemMaxUse=2G
  '';

  # --- Dyski ---
  services.fstrim.enable = true;
  services.btrfs.autoScrub = {
    enable = true;
    interval = "monthly";
    fileSystems = [ "/" ];
  };
  services.smartd.enable = true;
}
