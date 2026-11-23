# secure_user – osobne konto z utwardzonym Firefoksem do banku i urzędów.
#
#  1. osobne konto (1004): Jacek, claude, gry i zeroroot nie widzą jego plików ani procesów,
#  2. uruchamiane przez ego z menu („Bank i urzędy”), ale – inaczej niż gry – WYMAGA HASŁA Jacka
#     (polkit, okienko KDE): program złośliwy na koncie Jacka nie otworzy tej sesji po cichu,
#  3. Firefox z utwardzonym profilem (user.js tylko tutaj – zwykły Firefox Jacka bez zmian):
#     tylko HTTPS, ścisła ochrona przed śledzeniem, punycode (fałszywe domeny widać), bez rozszerzeń,
#     bez zapisywania haseł (Bitwarden), bez WebRTC i WebGL, historia czyszczona przy zamknięciu,
#  4. OpenSnitch: bez pytania tylko domeny z listy (moje.secure.domeny); każda inna strona = pytanie,
#  5. YubiKey (FIDO2/WebAuthn) dostępny dla tego konta (reguła udev),
#  6. dokumenty (wyciągi, PDF) w /home/secure-dokumenty – wspólne tylko z Jackiem, kopia restic.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  uid = 1004;
  dom = "/home/secure_user";
  profil = "${dom}/profil-firefox";
  dokumenty = "/home/secure-dokumenty";

  # Nazwy ustawień sprawdzone z arkenfox user.js (v144). Celowo pominięte (psują banki):
  # resistFingerprinting, wymuszanie bezpiecznej renegocjacji TLS, czyszczenie ciasteczek
  # (bank pamięta „zaufane urządzenie”).
  ustawienia = {
    # tylko HTTPS
    "dom.security.https_only_mode" = true;
    "dom.security.https_only_mode_send_http_background_request" = false;
    # ochrona przed śledzeniem i fałszywymi domenami
    "browser.contentblocking.category" = "strict";
    "network.IDN_show_punycode" = true;
    "network.http.referer.XOriginTrimmingPolicy" = 2;
    # hasła i formularze – nic nie zapisujemy (hasła w Bitwardenie)
    "signon.rememberSignons" = false;
    "signon.autofillForms" = false;
    "signon.formlessCapture.enabled" = false;
    "browser.formfill.enable" = false;
    "extensions.formautofill.addresses.enabled" = false;
    "extensions.formautofill.creditCards.enabled" = false;
    # bez rozszerzeń
    "xpinstall.enabled" = false;
    "extensions.postDownloadThirdPartyPrompt" = false;
    # mniejsza powierzchnia ataku
    "media.peerconnection.enabled" = false; # WebRTC (uwaga: wideoweryfikacja w banku go wymaga)
    "webgl.disabled" = true;
    "pdfjs.enableScripting" = false;
    # bez połączeń „na zapas” i podpowiedzi wysyłających to, co piszesz
    "network.prefetch-next" = false;
    "network.dns.disablePrefetch" = true;
    "network.dns.disablePrefetchFromHTTPS" = true;
    "network.predictor.enabled" = false;
    "browser.urlbar.speculativeConnect.enabled" = false;
    "browser.places.speculativeConnect.enabled" = false;
    "browser.search.suggest.enabled" = false;
    "browser.urlbar.suggest.searches" = false;
    # przy zamknięciu: pamięć podręczna, historia, formularze – tak; ciasteczka – nie
    "privacy.sanitize.sanitizeOnShutdown" = true;
    "privacy.clearOnShutdown_v2.cache" = true;
    "privacy.clearOnShutdown_v2.browsingHistoryAndDownloads" = true;
    "privacy.clearOnShutdown_v2.formdata" = true;
    "privacy.clearOnShutdown_v2.cookiesAndStorage" = false;
    "privacy.clearOnShutdown_v2.siteSettings" = false;
    # pobrane pliki od razu do folderu wspólnego z Jackiem
    "browser.download.useDownloadDir" = true;
    "browser.download.folderList" = 2;
    "browser.download.dir" = dokumenty;
    # start bez treści z internetu
    "browser.startup.homepage" = "about:blank";
    "browser.newtabpage.enabled" = false;
    "browser.aboutwelcome.enabled" = false;
    "datareporting.policy.dataSubmissionEnabled" = false;
  };
  userJs = pkgs.writeText "secure-user.js" (
    lib.concatStrings (
      lib.mapAttrsToList (n: v: "user_pref(${builtins.toJSON n}, ${builtins.toJSON v});\n") ustawienia
    )
  );

  # ^(.*\.)?(gov\.pl|zus\.pl|…)$ – domena z listy albo jej poddomena
  wzorzecDomen =
    "^(.*\\.)?("
    + lib.concatMapStringsSep "|" (lib.replaceStrings [ "." ] [ "\\." ]) config.moje.secure.domeny
    + ")$";

  skrot = pkgs.makeDesktopItem {
    name = "secure-user-firefox";
    desktopName = "Bank i urzędy (secure_user)";
    comment = "Utwardzony Firefox na osobnym koncie – tylko bank i urzędy";
    exec = "${pkgs.ego}/bin/ego --machinectl --user=secure_user firefox --new-instance --profile ${profil}";
    icon = "firefox";
    categories = [ "Network" ];
  };
in
{
  options.moje.secure.domeny = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [
      # urzędy
      "gov.pl" # login.gov.pl, mObywatel, ePUAP, podatki.gov.pl (e-Urząd Skarbowy), pacjent.gov.pl…
      "zus.pl" # PUE/eZUS
      # sam Firefox (aktualizacje list bezpieczeństwa, certyfikaty)
      "mozilla.org"
      "mozilla.net"
      "mozilla.com"
      "safebrowsing.googleapis.com"
      # TODO: domeny Twojego banku (np. "mbank.pl", "pkobp.pl", "ipko.pl") – dopisz w hosts/justjackpc
    ];
    description = "Domeny, z którymi secure_user łączy się bez pytania (z poddomenami). Inne = pytanie OpenSnitch.";
  };

  config = {
    users.groups = {
      secure-dokumenty.gid = 2003; # Jacek + secure_user
      secure-fido.gid = 2004; # dostęp do kluczy FIDO2 (YubiKey) dla secure_user
    };
    users.users.secure_user = {
      isNormalUser = true;
      inherit uid;
      description = "Bank i urzędy";
      hashedPassword = "!";
      extraGroups = [
        "secure-dokumenty"
        "secure-fido"
      ];
    };
    users.users.Jacek.extraGroups = [ "secure-dokumenty" ];

    # ego/machinectl do secure_user: Jacek, ale z hasłem (zapamiętane na kilka minut)
    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (action.id == "org.freedesktop.machine1.host-shell" &&
            subject.user == "Jacek" && action.lookup("user") == "secure_user") {
          return polkit.Result.AUTH_SELF_KEEP;
        }
      });
    '';

    # YubiKey dla przeglądarki secure_user (Jacek ma go i tak przez uaccess aktywnej sesji)
    services.udev.extraRules = ''
      SUBSYSTEM=="hidraw", ENV{ID_FIDO_TOKEN}=="1", GROUP="secure-fido", MODE="0660"
    '';

    systemd.tmpfiles.rules = [
      "d ${profil} 0700 secure_user users -"
      "L+ ${profil}/user.js - - - - ${userJs}"
      "d ${dokumenty} 2770 secure_user secure-dokumenty -"
      "a+ ${dokumenty} - - - - default:group:secure-dokumenty:rwx,group:secure-dokumenty:rwx"
      "L /home/Jacek/Dokumenty_bank - - - - ${dokumenty}"
    ];

    environment.systemPackages = [ skrot ];

    # OpenSnitch: domeny z listy bez pytania; reszta – pytanie (brak pasującej reguły)
    services.opensnitch.rules = lib.mkIf config.moje.opensnitch.enable {
      "030-secure-domeny" = {
        name = "030-secure-domeny";
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
              data = toString uid;
            }
            {
              type = "regexp";
              operand = "dest.host";
              sensitive = false;
              data = wzorzecDomen;
            }
          ];
        };
      };
    };

    # dokumenty: skan przy zapisie (pobrane pliki) i kopia na NAS
    services.clamav.daemon.settings.OnAccessIncludePath = [ dokumenty ];
  };
}
