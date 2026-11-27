# Jeden tunel WireGuard (ProtonVPN), dzielony przez konta, które go potrzebują - `vpn_user`
# (zawsze, patrz szablony/vpn.nix) i `tor_user` (opcjonalnie, przełącznik tor-vpn-on/-off, patrz
# szablony/tor.nix). Ten plik NIE wie, które konta go używają - tylko udostępnia sam tunel +
# WŁASNĄ tabelę routingu (`moje.vpn.tabela`), z której te szablony same dopisują/usuwają wpisy
# `ip rule` dla swojego UID-u. Jeden tunel, wiele niezależnych "kranów" - bez tego trzeba by
# osobnego połączenia WireGuard na każde konto.
#
# PRZYGOTOWANE POD DODANIE, DZIŚ WYŁĄCZONE (`moje.vpn.enable = false` domyślnie) - Jacek nie ma
# jeszcze pliku .conf z panelu ProtonVPN. Gdy go dostanie:
#   1. `sops secrets/justjackpc.yaml` → dopisać klucz `vpn.klucz-prywatny` (sama wartość
#      PrivateKey z pliku .conf),
#   2. w hosts/justjackpc/default.nix ustawić:
#      moje.vpn = {
#        enable = true;
#        publicznyKluczSerwera = "..."; # PublicKey z sekcji [Peer]
#        puntKonca = "1.2.3.4:51820";   # Endpoint z sekcji [Peer]
#        adresWewnetrzny = "10.2.0.2/32"; # Address z sekcji [Interface]
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
    publicznyKluczSerwera = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "PublicKey z sekcji [Peer] pliku .conf od ProtonVPN.";
    };
    punktKonca = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Endpoint (host:port) z sekcji [Peer] pliku .conf.";
    };
    adresWewnetrzny = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Address (z /maską) z sekcji [Interface] pliku .conf, np. 10.2.0.2/32.";
    };
    dns = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "DNS z sekcji [Interface] pliku .conf, jeśli podany - używany TYLKO przez konta podłączone do tego tunelu.";
    };
    interfejs = lib.mkOption {
      type = lib.types.str;
      default = "wgVpn";
      readOnly = true;
      description = "Nazwa interfejsu - dla reguł nftables/ip w szablonach kont.";
    };
    tabela = lib.mkOption {
      type = lib.types.int;
      default = 80;
      readOnly = true;
      description = "Numer własnej tabeli routingu tunelu (osobnej od głównej) - szablony kont dopisują tu wpisy ip rule dla swojego UID-u.";
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets."vpn/klucz-prywatny" = { };

    networking.wireguard.interfaces.${cfg.interfejs} = {
      ips = [ cfg.adresWewnetrzny ];
      privateKeyFile = config.sops.secrets."vpn/klucz-prywatny".path;
      # Bez tego wg-quick sam dopisałby trasę 0.0.0.0/0 do GŁÓWNEJ tabeli routingu - czyli
      # dokładnie to, czego unikamy (VPN dla całego systemu). Trasy do tunelu trzymamy WYŁĄCZNIE
      # we własnej tabeli (moje.vpn.tabela) - stąd ręcznie w postSetup/postShutdown niżej.
      allowedIPsAsRoutes = false;
      postSetup = ''
        ${pkgs.iproute2}/bin/ip route replace default dev ${cfg.interfejs} table ${toString cfg.tabela}
      '';
      postShutdown = ''
        ${pkgs.iproute2}/bin/ip route del default dev ${cfg.interfejs} table ${toString cfg.tabela} || true
      '';
      peers = [
        {
          publicKey = cfg.publicznyKluczSerwera;
          endpoint = cfg.punktKonca;
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
