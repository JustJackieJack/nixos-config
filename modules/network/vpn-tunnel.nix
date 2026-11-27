# Jeden tunel WireGuard (ProtonVPN), dzielony przez konta, które go potrzebują - `vpn_user`
# (zawsze, patrz szablony/vpn.nix) i `tor_user` (opcjonalnie, przełącznik tor-vpn-on/-off, patrz
# szablony/tor.nix). Ten plik NIE wie, które konta go używają - tylko udostępnia sam tunel +
# WŁASNĄ tabelę routingu (`moje.vpn.table`), z której te szablony same dopisują/usuwają wpisy
# `ip rule` dla swojego UID-u. Jeden tunel, wiele niezależnych "kranów" - bez tego trzeba by
# osobnego połączenia WireGuard na każde konto.
#
# PRZYGOTOWANE POD DODANIE, DZIŚ WYŁĄCZONE (`moje.vpn.enable = false` domyślnie) - Jacek nie ma
# jeszcze pliku .conf z panelu ProtonVPN. Gdy go dostanie:
#   1. `sops secrets/justjackpc.yaml` → dopisać klucz `vpn.private-key` (sama wartość
#      PrivateKey z pliku .conf),
#   2. w hosts/justjackpc/default.nix ustawić:
#      moje.vpn = {
#        enable = true;
#        serverPublicKey = "..."; # PublicKey z sekcji [Peer]
#        endpoint = "1.2.3.4:51820";   # Endpoint z sekcji [Peer]
#        internalAddress = "10.2.0.2/32"; # Address z sekcji [Interface]
#        dns = "10.2.0.1"; # DNS z sekcji [Interface], jeśli jest
#      };
#   3. `nixos-rebuild switch`.
# Do tego momentu interfejs po prostu nie istnieje - konta, które mają go wymagać (vpn_user),
# mają z definicji zero sieci (reguła w ich szablonie odmawia wszystkiego poza tym interfejsem) -
# to jest poprawne, "domknięte" zachowanie, nie błąd.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.moje.vpn;
in
{
  options.moje.vpn = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Włącz tunel WireGuard (ProtonVPN) - wymaga wypełnienia pól poniżej i klucza w sops.";
    };
    serverPublicKey = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "PublicKey z sekcji [Peer] pliku .conf od ProtonVPN.";
    };
    endpoint = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Endpoint (host:port) z sekcji [Peer] pliku .conf.";
    };
    internalAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Address (z /maską) z sekcji [Interface] pliku .conf, np. 10.2.0.2/32.";
    };
    dns = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "DNS z sekcji [Interface] pliku .conf, jeśli podany - używany TYLKO przez konta podłączone do tego tunelu.";
    };
    interface = lib.mkOption {
      type = lib.types.str;
      default = "wgVpn";
      readOnly = true;
      description = "Nazwa interfejsu - dla reguł nftables/ip w szablonach kont.";
    };
    table = lib.mkOption {
      type = lib.types.int;
      default = 80;
      readOnly = true;
      description = "Numer własnej tabeli routingu tunelu (osobnej od głównej) - szablony kont dopisują tu wpisy ip rule dla swojego UID-u.";
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets."vpn/private-key" = { };

    networking.wireguard.interfaces.${cfg.interface} = {
      ips = [ cfg.internalAddress ];
      privateKeyFile = config.sops.secrets."vpn/private-key".path;
      # Bez tego wg-quick sam dopisałby trasę 0.0.0.0/0 do GŁÓWNEJ tabeli routingu - czyli
      # dokładnie to, czego unikamy (VPN dla całego systemu). Trasy do tunelu trzymamy WYŁĄCZNIE
      # we własnej tabeli (moje.vpn.table) - stąd ręcznie w postSetup/postShutdown niżej.
      allowedIPsAsRoutes = false;
      postSetup = ''
        ${pkgs.iproute2}/bin/ip route replace default dev ${cfg.interface} table ${toString cfg.table}
      '';
      postShutdown = ''
        ${pkgs.iproute2}/bin/ip route del default dev ${cfg.interface} table ${toString cfg.table} || true
      '';
      peers = [
        {
          publicKey = cfg.serverPublicKey;
          endpoint = cfg.endpoint;
          allowedIPs = [
            "0.0.0.0/0"
            "::/0"
          ];
          persistentKeepalive = 25;
        }
      ];
    };
  };
}
