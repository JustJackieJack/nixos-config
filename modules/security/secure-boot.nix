# Secure Boot przez lanzaboote (własne klucze w /var/lib/sbctl).
# Kolejność wdrożenia – README, sekcja „Secure Boot”.
{
  config,
  lib,
  pkgs,
  ...
}:
lib.mkIf config.moje.secureBoot.enable {
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.lanzaboote = {
    enable = true;
    pkiBundle = "/var/lib/sbctl";
  };
  environment.systemPackages = [ pkgs.sbctl ];
}
