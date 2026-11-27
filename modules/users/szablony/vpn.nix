# Szablon "vpn": Firefox na osobnym koncie, które ma sieć WYŁĄCZNIE przez tunel WireGuard
# (modules/network/vpn-tunnel.nix) - prawdziwy "kill switch": jeśli tunel nie żyje (albo nie
# jest jeszcze skonfigurowany - patrz vpn-tunnel.nix), to konto ma ZERO sieci, nie cichy powrót
# do zwykłego internetu. Wołany z konta.nix, raz per instancja (dziś tylko vpn_user).
#  1. izolacja: ten sam wzorzec co browse_user - osobne UID, bez wheel, bez dostępu do
#     shared/projects/paperwork/plików Jacka,
#  2. sieć: wszystko albo nic - reguła nftables (precedence) odrzuca KAŻDY pakiet tego UID, który
#     NIE idzie przez interfejs tunelu; osobny wpis `ip rule`, "zawsze" (nie przełącznik jak
#     tor_user) kieruje ruch tego UID-u do WŁASNEJ tabeli routingu tunelu,
#  3. folder pobierania - WŁASNY, OSOBNY od browse_user (i od tor_user) - decyzja użytkownika:
#     nie mieszać zwykłego przeglądania z tym przez VPN.
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
  dom = "/home/${nazwa}";
  profil = "${dom}/profil-firefox";
  grupaPobierania = "${nazwa}-downloads";
  uid = toString config.users.users.${nazwa}.uid;
  interfejs = config.moje.vpn.interfejs;
  tabela = toString config.moje.vpn.tabela;

  ustawienia = {
    "dom.security.https_only_mode" = true;
    "browser.contentblocking.category" = "strict";
    "network.IDN_show_punycode" = true;
    "browser.download.useDownloadDir" = true;
    "browser.download.folderList" = 2;
    "browser.download.dir" = folderPobierania;
    "browser.startup.homepage" = "about:blank";
    "datareporting.policy.dataSubmissionEnabled" = false;
  };
  userJs = pkgs.writeText "${nazwa}-user.js" (
    lib.concatStrings (
      lib.mapAttrsToList (n: v: "user_pref(${builtins.toJSON n}, ${builtins.toJSON v});\n") ustawienia
    )
  );

  skrot = pkgs.makeDesktopItem {
    name = "${nazwa}-firefox";
    desktopName = "Firefox przez VPN (${nazwa})";
    comment = "Przeglądarka, która ma sieć TYLKO przez tunel WireGuard";
    exec = "${pkgs.ego}/bin/ego --machinectl --user=${nazwa} firefox --new-instance --profile ${profil}";
    icon = "firefox";
    categories = [ "Network" ];
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
      "d ${profil} 0700 ${nazwa} users -"
      "L+ ${profil}/user.js - - - - ${userJs}"
      "d ${folderPobierania} 2770 ${nazwa} ${grupaPobierania} -"
      "a+ ${folderPobierania} - - - - default:group:${grupaPobierania}:rwx,group:${grupaPobierania}:rwx"
    ] ++ lib.optional (skrotJacek != null && rodzic != null) "L /home/${rodzic}/${skrotJacek} - - - - ${folderPobierania}";

    environment.systemPackages = [ skrot ];

    # Kill switch: zablokuj WSZYSTKO dla tego UID, co nie idzie przez interfejs tunelu. Działa
    # NIEZALEŻNIE od tego, czy moje.vpn.enable jest dziś true czy false - gdy tunel nie istnieje,
    # ta reguła i tak odrzuca wszystko (nie ma czym "przejść"), czyli bezpieczny stan domyślny.
    networking.nftables.tables."${nazwa}-kill-switch" = {
      family = "inet";
      content = ''
        chain output {
          type filter hook output priority filter; policy accept;
          meta skuid ${uid} oifname != "${interfejs}" limit rate 5/minute log prefix "${nazwa}-kill-switch: "
          meta skuid ${uid} oifname != "${interfejs}" reject
        }
      '';
    };

    # Ruch tego UID-u ZAWSZE kierowany do tabeli tunelu (w odróżnieniu od tor_user, który ma to
    # jako przełącznik) - usługa, nie activationScript (ta sama lekcja co dostepRodzicowDoPoduserow
    # w konta.nix: ip rule musi istnieć niezależnie od tego, co jeszcze nie wstało przy starcie).
    systemd.services."${nazwa}-routing" = {
      description = "Kieruj ruch konta ${nazwa} do tabeli tunelu VPN (moje.vpn.tabela)";
      after = [ "network-pre.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.iproute2}/bin/ip rule add uidrange ${uid}-${uid} lookup ${tabela} priority 100";
        ExecStop = "${pkgs.iproute2}/bin/ip rule del uidrange ${uid}-${uid} lookup ${tabela} priority 100";
      };
    };

    services.opensnitch.rules = lib.mkIf config.moje.opensnitch.enable {
      "026-${nazwa}-firefox" = {
        name = "026-${nazwa}-firefox";
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
              data = "${pkgs.firefox-unwrapped}/lib/firefox/firefox";
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
