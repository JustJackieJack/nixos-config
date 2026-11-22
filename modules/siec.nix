# Sieć: NetworkManager, systemd-resolved, nftables (domyślnie odrzucaj przychodzące), avahi.
# ProtonVPN: aplikacja w pakiety.nix (korzysta z NetworkManagera).
{ config, ... }:
let
  lan = config.moje.lan;
in
{
  networking.networkmanager = {
    enable = true;
    # Stały, fabryczny MAC – router rozpoznaje komputer po MAC (rezerwacja 10.0.10.248).
    ethernet.macAddress = "permanent";
    wifi.macAddress = "permanent";
  };

  # Jeden resolver dla całego systemu → w OpenSnitch DNS ma tylko systemd-resolved,
  # a nie każdy program osobno.
  services.resolved = {
    enable = true;
    settings.Resolve = {
      # LLMNR (rozwiązywanie nazw rozgłoszeniem) – podatne na podszywanie, nie używamy.
      LLMNR = "false";
      # mDNS obsługuje avahi – resolved nie dubluje (konflikt o port 5353).
      MulticastDNS = "false";
    };
  };

  networking.nftables.enable = true;
  networking.firewall = {
    enable = true;
    # "loose": ścisłe rp_filter psuje WireGuard (ProtonVPN kieruje ruch przez fwmark).
    checkReversePath = "loose";
    allowedTCPPorts = [ ];
    allowedUDPPorts = [ ];
    # Wyjątki tylko z sieci domowej.
    extraInputRules = ''
      ip saddr ${lan} tcp dport 1714-1764 accept comment "KDE Connect"
      ip saddr ${lan} udp dport 1714-1764 accept comment "KDE Connect"
      ip saddr ${lan} udp dport 5353 accept comment "mDNS (drukarka, wykrywanie)"
    '';
  };

  # Avahi tylko do wykrywania (drukarka, urządzenia), bez rozgłaszania siebie.
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    openFirewall = false; # port 5353 otwarty wyżej, tylko z LAN
    publish.enable = false;
  };

  # Bez SSH na tym komputerze (na Fedorze też nie był włączony).
  services.openssh.enable = false;
}
