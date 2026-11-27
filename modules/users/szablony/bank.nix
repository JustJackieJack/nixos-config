# Szablon "bank": osobne konto z utwardzonym Firefoksem do banku i urzędów. Wołany z konta.nix,
# raz per instancja (dziś tylko secure_user).
#  1. izolacja: inne konta (w tym Jacek) nie widzą jego plików ani procesów,
#  2. uruchamiane przez ego z menu, ale - inaczej niż szablony gry/dev/zerotrust - WYMAGA HASŁA
#     (polkit, okienko KDE): program złośliwy na koncie Jacka nie otworzy tej sesji po cichu. Stąd
#     to konto NIE ma pola `parent` w konta.nix - generowana tam bezhasłowa reguła by to łamała -
#     własna, hasło-wymagająca reguła polkit jest tutaj, niezależna od tamtego mechanizmu.
#  3. Firefox z utwardzonym profilem (user.js tylko tutaj),
#  4. OpenSnitch: bez pytania tylko domeny z listy (moje.secure.domeny); każda inna strona = pytanie,
#  5. YubiKey (FIDO2/WebAuthn) dostępny dla tego konta (reguła udev),
#  6. dokumenty - współdzielone tylko z Jackiem, kopia restic.
#
# moje.secure.domeny i grupa secure-fido (sprzęt, nie dane) zostają WSPÓLNE dla wszystkich
# przyszłych instancji tego szablonu - świadome uproszczenie "do minimum". Grupa DOKUMENTÓW jest
# już per-instancja (<name>-documents, konto + opcjonalny `parent`) - dwie różne instancje nie
# widzą nawzajem swoich dokumentów.
# documents: domyślnie katalog pochodny od nazwy konta, ale istniejąca instancja (secure_user)
# podaje w konta.nix dzisiejszą, niezależną od nazwy ścieżkę (/home/secure-documents), bo ta
# ścieżka jest też zahardkodowana w modules/system/backups.nix - zmiana wymagałaby zmiany tam też.
{
  name,
  parent ? null,
  documents ? "/home/${name}-documents",
  # wygodny skrót w domu rodzica do folderu dokumentów - opcjonalny, działa tylko gdy `parent`
  # podany (istniejąca instancja, secure_user, podaje oba w konta.nix).
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

  settings = {
    "dom.security.https_only_mode" = true;
    "dom.security.https_only_mode_send_http_background_request" = false;
    "browser.contentblocking.category" = "strict";
    "network.IDN_show_punycode" = true;
    "network.http.referer.XOriginTrimmingPolicy" = 2;
    "signon.rememberSignons" = false;
    "signon.autofillForms" = false;
    "signon.formlessCapture.enabled" = false;
    "browser.formfill.enable" = false;
    "extensions.formautofill.addresses.enabled" = false;
    "extensions.formautofill.creditCards.enabled" = false;
    "xpinstall.enabled" = false;
    "extensions.postDownloadThirdPartyPrompt" = false;
    "media.peerconnection.enabled" = false;
    "webgl.disabled" = true;
    "pdfjs.enableScripting" = false;
    "network.prefetch-next" = false;
    "network.dns.disablePrefetch" = true;
    "network.dns.disablePrefetchFromHTTPS" = true;
    "network.predictor.enabled" = false;
    "browser.urlbar.speculativeConnect.enabled" = false;
    "browser.places.speculativeConnect.enabled" = false;
    "browser.search.suggest.enabled" = false;
    "browser.urlbar.suggest.searches" = false;
    "privacy.sanitize.sanitizeOnShutdown" = true;
    "privacy.clearOnShutdown_v2.cache" = true;
    "privacy.clearOnShutdown_v2.browsingHistoryAndDownloads" = true;
    "privacy.clearOnShutdown_v2.formdata" = true;
    "privacy.clearOnShutdown_v2.cookiesAndStorage" = false;
    "privacy.clearOnShutdown_v2.siteSettings" = false;
    "browser.download.useDownloadDir" = true;
    "browser.download.folderList" = 2;
    "browser.download.dir" = documents;
    "browser.startup.homepage" = "about:blank";
    "browser.newtabpage.enabled" = false;
    "browser.aboutwelcome.enabled" = false;
    "datareporting.policy.dataSubmissionEnabled" = false;
  };
  userJs = pkgs.writeText "${name}-user.js" (
    lib.concatStrings (
      lib.mapAttrsToList (n: v: "user_pref(${builtins.toJSON n}, ${builtins.toJSON v});\n") settings
    )
  );

  domainPattern =
    "^(.*\\.)?("
    + lib.concatMapStringsSep "|" (lib.replaceStrings [ "." ] [ "\\." ]) config.moje.secure.domeny
    + ")$";

  desktopItem = pkgs.makeDesktopItem {
    name = "${name}-firefox";
    desktopName = "Bank i urzędy (${name})";
    comment = "Utwardzony Firefox na osobnym koncie - tylko bank i urzędy";
    exec = "${pkgs.ego}/bin/ego --machinectl --user=${name} firefox --new-instance --profile ${profileDir}";
    icon = "firefox";
    categories = [ "Network" ];
  };
in
{
  options.moje.secure.domeny = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = "Domeny, z którymi konta bank łączą się bez pytania (z poddomenami). Inne = pytanie OpenSnitch.";
  };

  config = {
    moje.secure.domeny = [
      "gov.pl"
      "zus.pl"
      "mozilla.org"
      "mozilla.net"
      "mozilla.com"
      "safebrowsing.googleapis.com"
    ];

    users.groups = {
      "${name}-documents" = { };
      secure-fido.gid = 2003;
    };
    users.users = {
      ${name}.extraGroups = [
        "${name}-documents"
        "secure-fido"
      ];
    } // lib.optionalAttrs (parent != null) {
      ${parent}.extraGroups = [ "${name}-documents" ];
    };

    # ego/machinectl do tego konta: Jacek, ale z hasłem (zapamiętane na kilka minut) - jedyne
    # miejsce, gdzie ten dostęp jest regulowany (konta.nix nie generuje tu nic, patrz nagłówek).
    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (action.id == "org.freedesktop.machine1.host-shell" &&
            subject.user == "Jacek" && action.lookup("user") == "${name}") {
          return polkit.Result.AUTH_SELF_KEEP;
        }
      });
    '';

    services.udev.extraRules = ''
      SUBSYSTEM=="hidraw", ENV{ID_FIDO_TOKEN}=="1", GROUP="secure-fido", MODE="0660"
    '';

    systemd.tmpfiles.rules = [
      "d ${profileDir} 0700 ${name} users -"
      "L+ ${profileDir}/user.js - - - - ${userJs}"
      "d ${documents} 2770 ${name} ${name}-documents -"
      "a+ ${documents} - - - - default:group:${name}-documents:rwx,group:${name}-documents:rwx"
    ] ++ lib.optional (parentShortcut != null && parent != null) "L /home/${parent}/${parentShortcut} - - - - ${documents}";

    environment.systemPackages = [ desktopItem ];

    services.opensnitch.rules = lib.mkIf config.moje.opensnitch.enable {
      "030-${name}-domains" = {
        name = "030-${name}-domains";
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
              operand = "user.id";
              sensitive = false;
              data = toString config.users.users.${name}.uid;
            }
            {
              type = "regexp";
              operand = "dest.host";
              sensitive = false;
              data = domainPattern;
            }
          ];
        };
      };
    };

    services.clamav.daemon.settings.OnAccessIncludePath = [ documents ];
  };
}
