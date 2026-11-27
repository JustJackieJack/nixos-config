# Szablon "tor": Tor Browser na osobnym koncie, z OPCJONALNYM dodatkowym tunelem WireGuard
# (modules/network/vpn-tunnel.nix) - w odróżnieniu od szablonu "vpn" (zawsze, kill switch), tutaj
# VPN jest przełącznikiem (tor-vpn-on/-off), bo Tor sam w sobie już daje anonimowość - VPN pod
# Torem to dodatkowa warstwa, nie wymóg. Wołany z konta.nix, raz per instancja (dziś tylko
# tor_user).
#  1. izolacja: ten sam wzorzec co browse_user/vpn_user,
#  2. sieć: TYLKO sam proces `tor` (ten w środku paczki Tor Browser, nie żaden inny program na
#     tym koncie) ma zawsze dostęp - reguła OpenSnitch po ścieżce + UID, jak przy innych
#     przeglądarkach. Bez przełącznika to konto używa zwykłego internetu (Tor sam robi swoje) -
#     WŁĄCZENIE przełącznika dopisuje wpis `ip rule`, kierując ruch tego UID-u do tabeli tunelu
#     (ta sama tabela co vpn_user - jeden tunel, wiele kranów). Jeśli włączone, a tunel akurat nie
#     żyje: pakiet dostaje "Network unreachable" (pusta tabela), NIE cichy powrót do zwykłego
#     internetu - to jest bezpieczny efekt SAMEGO mechanizmu `ip rule`, nic dodatkowego nie trzeba
#     dopisywać.
#  3. folder pobierania - WŁASNY, OSOBNY od browse_user/vpn_user (decyzja użytkownika).
{
  nazwa,
  rodzic ? null,
  folderPobierania ? "/home/${nazwa}-downloads",
  skrotJacek ? null,
  ...
}:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  grupaPobierania = "${nazwa}-downloads";
  uid = toString config.users.users.${nazwa}.uid;
  tabela = toString config.moje.vpn.tabela;
  # Prawdziwy proces, który dotyka sieci - NIE launcher (bin/tor-browser to tylko wrapper,
  # ten sam wymóg co wszędzie indziej w tym repo: OpenSnitch porównuje prawdziwą ścieżkę procesu).
  torBin = "${pkgs.tor-browser}/share/tor-browser/TorBrowser/Tor/tor";

  skrot = pkgs.makeDesktopItem {
    name = "${nazwa}-tor-browser";
    desktopName = "Tor Browser (${nazwa})";
    comment = "Przeglądarka Tor na osobnym, izolowanym koncie";
    exec = "${pkgs.ego}/bin/ego --machinectl --user=${nazwa} tor-browser";
    icon = "torbrowser";
    categories = [ "Network" ];
  };

  torVpnWlacz = pkgs.writeShellApplication {
    name = "tor-vpn-on";
    runtimeInputs = [ pkgs.iproute2 ];
    text = ''
      ip rule add uidrange ${uid}-${uid} lookup ${tabela} priority 90 \
        || { echo "tor-vpn-on: ip rule add failed (już włączone?)" >&2; exit 1; }
      echo "tor_user: ruch teraz kierowany przez tunel VPN (tabela ${tabela})" >&2
    '';
  };
  torVpnWylacz = pkgs.writeShellApplication {
    name = "tor-vpn-off";
    runtimeInputs = [ pkgs.iproute2 ];
    text = ''
      ip rule del uidrange ${uid}-${uid} lookup ${tabela} priority 90 \
        || { echo "tor-vpn-off: ip rule del failed (już wyłączone?)" >&2; exit 1; }
      echo "tor_user: z powrotem na zwykłym internecie" >&2
    '';
  };
in
{
  config = {
    users.groups = {
      ${grupaPobierania} = { };
    };
    users.users = {
      ${nazwa}.extraGroups = [ grupaPobierania ];
    } // lib.optionalAttrs (rodzic != null) {
      ${rodzic}.extraGroups = [ grupaPobierania ];
    };

    systemd.tmpfiles.rules = [
      "d ${folderPobierania} 2770 ${nazwa} ${grupaPobierania} -"
      "a+ ${folderPobierania} - - - - default:group:${grupaPobierania}:rwx,group:${grupaPobierania}:rwx"
    ] ++ lib.optional (skrotJacek != null && rodzic != null) "L /home/${rodzic}/${skrotJacek} - - - - ${folderPobierania}";

    environment.systemPackages = [
      skrot
      torVpnWlacz
      torVpnWylacz
    ];

    # Przełącznik wymaga roota (ip rule) - bezhasłowo dla rodzica, tylko te dwa dokładne programy
    # (ten sam wzorzec co kde-sync/claude-share: jeden /nix/store-path, cała logika w środku).
    security.sudo-rs.extraRules = lib.optional (rodzic != null) {
      users = [ rodzic ];
      runAs = "root";
      commands = [
        {
          command = "${torVpnWlacz}/bin/tor-vpn-on";
          options = [ "NOPASSWD" ];
        }
        {
          command = "${torVpnWylacz}/bin/tor-vpn-off";
          options = [ "NOPASSWD" ];
        }
      ];
    };

    services.opensnitch.rules = lib.mkIf config.moje.opensnitch.enable {
      "027-${nazwa}-tor" = {
        name = "027-${nazwa}-tor";
        enabled = true;
        action = "allow";
        duration = "always";
        operator = {
          type = "list";
          operand = "list";
          sensitive = false;
          data = "";
          list = [
            {
              type = "simple";
              operand = "process.path";
              sensitive = false;
              data = torBin;
            }
            {
              type = "simple";
              operand = "user.id";
              sensitive = false;
              data = uid;
            }
          ];
        };
      };
    };

    services.clamav.daemon.settings.OnAccessIncludePath = [ folderPobierania ];
  };
}
