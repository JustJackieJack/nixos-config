# Własne przełączniki (moje.*), żeby host i tryb awaryjny mogły włączać/wyłączać całe bloki.
{ lib, config, ... }:
{
  options.moje = {
    lan = lib.mkOption {
      type = lib.types.str;
      description = "Podsieć LAN (CIDR), z której wolno KDE Connect i mDNS.";
    };

    secureBoot.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        lanzaboote zamiast zwykłego systemd-boot. Przy PIERWSZEJ instalacji ustawić false
        (klucze sbctl jeszcze nie istnieją), potem create-keys i przełączyć na true.
      '';
    };

    hardening.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "sysctl, parametry jądra, blokada modułów (modules/hardening.nix).";
    };

    hardening.hidepid = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "hidepid=2 na /proc (użytkownicy nie widzą cudzych procesów). Najbardziej ryzykowna część – testować.";
    };

    opensnitch.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Zapora aplikacyjna OpenSnitch (modules/opensnitch.nix).";
    };

    nas.adres = lib.mkOption {
      type = lib.types.str;
      default = "10.0.190.5";
      description = "Adres NAS (udziały CIFS).";
    };

    nas.montowania = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      internal = true;
      description = "Wpisy montowania udziałów NAS (wyliczane w kopie.nix; test VM używa ich ponownie).";
    };

    sekrety.plik = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Plik sops tego hosta. Bez niego moduły zależne od sekretów (restic, NAS) się nie włączą.";
    };

    sekrety.gotowe = lib.mkOption {
      type = lib.types.bool;
      readOnly = true;
      default = config.moje.sekrety.plik != null && builtins.pathExists config.moje.sekrety.plik;
      description = "Czy plik sekretów istnieje (wyliczane).";
    };
  };
}
