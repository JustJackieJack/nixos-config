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
  name,
  parent ? null,
  downloadDir ? "/home/${name}-downloads",
  parentShortcut ? null,
  ...
}:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  homeDir = "/home/${name}";
  profileDir = "${homeDir}/firefox-profile";
  downloadGroup = "${name}-downloads";
  uid = toString config.users.users.${name}.uid;
  tunnelInterface = config.moje.vpn.interface;
  tunnelTable = toString config.moje.vpn.table;

  settings = {
    "dom.security.https_only_mode" = true;
    "browser.contentblocking.category" = "strict";
    "network.IDN_show_punycode" = true;
    "browser.download.useDownloadDir" = true;
    "browser.download.folderList" = 2;
    "browser.download.dir" = downloadDir;
    "browser.startup.homepage" = "about:blank";
    "datareporting.policy.dataSubmissionEnabled" = false;
  };
  userJs = pkgs.writeText "${name}-user.js" (
    lib.concatStrings (
      lib.mapAttrsToList (n: v: "user_pref(${builtins.toJSON n}, ${builtins.toJSON v});\n") settings
    )
  );

  desktopItem = pkgs.makeDesktopItem {
    name = "${name}-firefox";
    desktopName = "Firefox przez VPN (${name})";
    comment = "Przeglądarka, która ma sieć TYLKO przez tunel WireGuard";
    exec = "${pkgs.ego}/bin/ego --machinectl --user=${name} firefox --new-instance --profile ${profileDir}";
    icon = "firefox";
    categories = [ "Network" ];
  };
in
{
  config = {
    users.groups = {
      ${downloadGroup} = { };
    };
    users.users = {
      ${name}.extraGroups = [ downloadGroup ];
    } // lib.optionalAttrs (parent != null) {
      ${parent}.extraGroups = [ downloadGroup ];
    };

    systemd.tmpfiles.rules = [
      "d ${profileDir} 0700 ${name} users -"
      "L+ ${profileDir}/user.js - - - - ${userJs}"
      "d ${downloadDir} 2770 ${name} ${downloadGroup} -"
      "a+ ${downloadDir} - - - - default:group:${downloadGroup}:rwx,group:${downloadGroup}:rwx"
    ] ++ lib.optional (parentShortcut != null && parent != null) "L /home/${parent}/${parentShortcut} - - - - ${downloadDir}";

    environment.systemPackages = [ desktopItem ];

    # Kill switch: zablokuj WSZYSTKO dla tego UID, co nie idzie przez interfejs tunelu. Działa
    # NIEZALEŻNIE od tego, czy moje.vpn.enable jest dziś true czy false - gdy tunel nie istnieje,
    # ta reguła i tak odrzuca wszystko (nie ma czym "przejść"), czyli bezpieczny stan domyślny.
    networking.nftables.tables."${name}-kill-switch" = {
      family = "inet";
      content = ''
        chain output {
          type filter hook output priority filter; policy accept;
          meta skuid ${uid} oifname != "${tunnelInterface}" limit rate 5/minute log prefix "${name}-kill-switch: "
          meta skuid ${uid} oifname != "${tunnelInterface}" reject
        }
      '';
    };

    # Ruch tego UID-u ZAWSZE kierowany do tabeli tunelu (w odróżnieniu od tor_user, który ma to
    # jako przełącznik) - usługa, nie activationScript (ta sama lekcja co
    # parentAccessForSubAccounts w konta.nix: ip rule musi istnieć niezależnie od tego, co jeszcze
    # nie wstało przy starcie).
    systemd.services."${name}-routing" = {
      description = "Kieruj ruch konta ${name} do tabeli tunelu VPN (moje.vpn.table)";
      after = [ "network-pre.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.iproute2}/bin/ip rule add uidrange ${uid}-${uid} lookup ${tunnelTable} priority 100";
        ExecStop = "${pkgs.iproute2}/bin/ip rule del uidrange ${uid}-${uid} lookup ${tunnelTable} priority 100";
      };
    };

    services.opensnitch.rules = lib.mkIf config.moje.opensnitch.enable {
      "026-${name}-firefox" = {
        name = "026-${name}-firefox";
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

    services.clamav.daemon.settings.OnAccessIncludePath = [ downloadDir ];
  };
}
