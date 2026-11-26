# Aplikacje wybrane przy migracji z Fedory (lista ~/TMP/Migracja_NixOS/APLIKACJE.md, poza repo).
# Część jest w innych modułach: Firefox, GnuPG (desktop.nix), Steam/Heroic/Wine (games.nix),
# Claude Code/Chromium (claude.nix), ClamAV/Lynis/vulnix (monitoring.nix), sbctl (secure-boot.nix).
{ pkgs, ... }:
{
  # --- programy z modułem NixOS (ustawiają też uprawnienia/usługi) ---
  programs.wireshark = {
    enable = true;
    package = pkgs.wireshark; # wersja z interfejsem graficznym
  };
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };
  programs.partition-manager.enable = true;
  programs.kdeconnect.enable = false; # moduł otwiera porty dla wszystkich – paczka niżej, porty w network.nix
  programs.git.enable = true;
  programs.tmux.enable = true;

  virtualisation.podman = {
    enable = true;
    dockerCompat = true; # polecenie „docker” → podman (compose z projektów działa)
    defaultNetwork.settings.dns_enabled = true;
  };

  environment.systemPackages = with pkgs; [
    # komunikacja, hasła, notatki
    discord
    thunderbird
    bitwarden-desktop
    yubioath-flutter
    yubikey-manager
    libfido2
    obsidian
    super-productivity
    tor-browser

    # SSH / zdalny dostęp (zamiast SSH Pilot: menedżer SSH w Konsole + sshs w terminalu)
    sshs
    remmina
    filezilla
    proton-vpn
    kdePackages.kdeconnect-kde

    # sieć – diagnostyka
    nmap
    dnsutils
    traceroute
    mtr
    whois
    wireguard-tools
    qrencode

    # programowanie (kompilatory i biblioteki projektów: devShell w repo projektu)
    vscode
    gh
    nil
    nixfmt
    nix-tree
    nvd
    shellcheck
    python3
    jq
    ripgrep
    fd
    curl
    wget
    meld
    distrobox
    podman-compose

    # grafika, wideo, druk 3D
    gimp
    flashprint
    ffmpeg
    yt-dlp
    vlc
    pavucontrol

    # biuro
    libreoffice-qt6-fresh
    hunspell
    hunspellDicts.pl_PL
    hunspellDicts.en_US

    # system
    kitty
    btop
    htop
    fastfetch
    qdirstat
    # GPU: btop (klawisz 5) – nvtop dla NVIDIA wymaga całego CUDA
    lm_sensors
    smartmontools
    btrfs-assistant
    compsize
    gptfdisk
    parted
    bat
    tree
    unzip
    p7zip
    file
    lsof
    pciutils
    usbutils
    wl-clipboard
    restic
  ];
}
