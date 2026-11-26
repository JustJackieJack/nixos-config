# Wspólne moduły dla wszystkich komputerów.
# Podział na podfoldery wg kategorii (system/security/users/desktop/apps/network) – tak samo
# grupuje swoje moduły sam nixpkgs (nixos/modules/{services,security,hardware,...}), patrz
# https://wiki.nixos.org/wiki/NixOS_modules. Układ katalogów flake nie ma jednego oficjalnego
# wzorca (patrz dyskusja: https://discourse.nixos.org/t/how-do-you-structure-your-nixos-configs/65851) –
# ten podział przyjęty świadomie, żeby nazwa pliku + folder od razu mówiły, czego dotyczy zmiana.
{
  imports = [
    ./system/options.nix
    ./system/base.nix
    ./system/backups.nix
    ./system/emergency.nix

    ./security/secure-boot.nix
    ./security/hardening.nix
    ./security/opensnitch.nix
    ./security/monitoring.nix

    ./users/users.nix
    ./users/claude
    ./users/zeroroot.nix
    ./users/secure.nix

    ./desktop/nvidia.nix
    ./desktop/desktop.nix

    ./apps/games.nix
    ./apps/packages.nix

    ./network/network.nix
  ];
}
