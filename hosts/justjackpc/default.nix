# JustJackPC – stacjonarny: i5-8600K, RTX 2070, MSI Z370 TOMAHAWK, 32 GB RAM.
{ inputs, ... }:
{
  imports = [
    inputs.disko.nixosModules.disko
    inputs.lanzaboote.nixosModules.lanzaboote
    inputs.sops-nix.nixosModules.sops
    ./hardware.nix
    ./disko.nix
    ../../modules
  ];

  # Ta sama nazwa co na Fedorze; router przydziela 10.0.10.248 po MAC (eno1, 30:9C:23:9C:D6:BB).
  networking.hostName = "JustJackPC";

  # Sieć domowa, z której wolno KDE Connect i mDNS (modules/siec.nix).
  moje.lan = "10.0.10.0/24";

  # Bank (przeglądarka secure_user): ING Bank Śląski – www.ing.pl i logowanie login.ingbank.pl.
  # Dopisywane do listy z modules/secure.nix (gov.pl, zus.pl, Mozilla). Płatności kartą (3-D Secure)
  # i inne strony OpenSnitch zgłosi pytaniem.
  moje.secure.domeny = [
    "ing.pl"
    "ingbank.pl"
  ];

  # Sekrety tego hosta (sops). Plik powstaje przy instalacji – patrz README.
  moje.sekrety.plik = ../../secrets/justjackpc.yaml;

  # NIE zmieniać po instalacji (to nie jest wersja systemu, tylko punkt odniesienia dla danych stanowych).
  system.stateVersion = "26.05";

  moje.secureBoot.enable = false;
}
