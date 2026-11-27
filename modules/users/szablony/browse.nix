# Szablon "browse": główna przeglądarka (Firefox) na osobnym, izolowanym koncie - obrona przed
# atakiem typu "zaufana strona padła ofiarą supply-chain" (złośliwy JS z normalnie-zaufanej
# domeny, np. przez skompromitowany skrypt reklamowy/analityczny). Wołany z konta.nix, raz per
# instancja (dziś tylko browse_user).
#  1. izolacja: inne konta (w tym Jacek) nie widzą jego plików/procesów - jeśli przeglądarka
#     zostanie skompromitowana (np. ucieczka z sandboxa Firefoksa), atakujący dostaje dostęp
#     TYLKO do tego konta - nie do SSH/GPG/dokumentów/sudo Jacka. Różnica wobec samego bubblewrap
#     (ta sama sesja, ten sam UID): wiele kanałów bocznych (ssh-agent, gpg-agent, D-Bus sesji,
#     Wayland, wheel/sudo) jest związanych z UID, nie z namespace - inny UID blokuje je z definicji,
#     bubblewrap trzeba by konfigurować tak, żeby domknąć każdy z nich osobno.
#  2. uruchamiane przez ego z menu BEZ hasła (jak gry/dev/zerotrust) - to ma być codzienna, zwykła
#     przeglądarka, nie coś wymagającego ceremonii jak bank.nix (tam hasło jest celowe - dane
#     bankowe). Lżejsze też ustawienia Firefoksa niż w bank.nix - to nie ma być niewygodne.
#  3. sieć: pełny dostęp (OpenSnitch "zawsze zezwól", jak Firefox Jacka) - to normalna przeglądarka
#     do dowolnych stron, w przeciwieństwie do bank.nix tu NIE MA listy dozwolonych domen,
#  4. folder pobierania - stały, dwukierunkowy z rodzicem (ten sam wzorzec co Paperwork): Firefox
#     zapisuje tam WSZYSTKIE pobrane pliki, rodzic widzi je od razu bez żadnego "oddawania"; w tę
#     samą stronę - rodzic wrzuca tam plik, który chce wysłać przez stronę (okienko wyboru plików
#     w Firefoksie domyślnie otwiera się w katalogu pobierania).
{
  nazwa,
  rodzic ? null,
  folderPobierania ? "/home/${nazwa}-downloads",
  # wygodny skrót w domu rodzica do folderu pobierania - opcjonalny, działa tylko gdy `rodzic`
  # podany (tak jak skrotJacek w bank.nix).
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

  # Lżejsze niż bank.nix - to ma być zwykła, codzienna przeglądarka. DisableTelemetry/
  # DisableFirefoxStudies/DisablePocket już globalnie w desktop.nix (programs.firefox.policies).
  ustawienia = {
    "dom.security.https_only_mode" = true;
    "browser.contentblocking.category" = "strict"; # wbudowana ochrona przed trackerami/3rd-party
    "network.IDN_show_punycode" = true; # przeciw phishingowi przez homoglify w domenach
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
    desktopName = "Firefox (${nazwa})";
    comment = "Główna przeglądarka na osobnym, izolowanym koncie";
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

    # Pełny dostęp do sieci dla TEGO konta (jak "020-firefox" dla Jacka w opensnitch.nix) - bez
    # tego każda nowa strona pytałaby okienkiem OpenSnitch, co dla głównej przeglądarki byłoby
    # nie do zniesienia. Klucz po UID + ścieżce (nie tylko ścieżce) - inaczej reguła omijałaby
    # też listę domen secure_user (ten sam plik binarny Firefoksa, inne konto).
    services.opensnitch.rules = lib.mkIf config.moje.opensnitch.enable {
      "025-${nazwa}-firefox" = {
        name = "025-${nazwa}-firefox";
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
              data = toString config.users.users.${nazwa}.uid;
            }
          ];
        };
      };
    };

    services.clamav.daemon.settings.OnAccessIncludePath = [ folderPobierania ];
  };
}
