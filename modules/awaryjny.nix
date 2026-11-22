# Tryb awaryjny: osobna pozycja w menu rozruchu („awaryjny”) – ten sam system,
# ale bez hardeningu i bez OpenSnitch. Gdy po zmianie coś przestanie działać, uruchamiasz
# ten wpis, sprawdzasz, czy winny jest hardening, i poprawiasz konfigurację.
{ lib, ... }:
{
  specialisation.awaryjny.configuration = {
    system.nixos.tags = [ "awaryjny" ];
    moje.hardening.enable = lib.mkForce false;
    moje.opensnitch.enable = lib.mkForce false;
  };
}
