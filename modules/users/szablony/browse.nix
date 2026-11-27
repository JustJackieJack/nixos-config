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
  name,
  parent ? null,
  downloadDir ? "/home/${name}-downloads",
  # wygodny skrót w domu rodzica do folderu pobierania - opcjonalny, działa tylko gdy `parent`
  # podany (tak jak parentShortcut w bank.nix).
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

  # Lżejsze niż bank.nix - to ma być zwykła, codzienna przeglądarka. DisableTelemetry/
  # DisableFirefoxStudies/DisablePocket już globalnie w desktop.nix (programs.firefox.policies).
  settings = {
    "dom.security.https_only_mode" = true;
    "browser.contentblocking.category" = "strict"; # wbudowana ochrona przed trackerami/3rd-party
    "network.IDN_show_punycode" = true; # przeciw phishingowi przez homoglify w domenach
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
    desktopName = "Firefox (${name})";
    comment = "Główna przeglądarka na osobnym, izolowanym koncie";
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

    # Pełny dostęp do sieci dla TEGO konta (jak "020-firefox-blokada-jacka" w opensnitch.nix dla
    # porównania) - bez tego każda nowa strona pytałaby okienkiem OpenSnitch, co dla głównej
    # przeglądarki byłoby nie do zniesienia. Klucz po UID + ścieżce (nie tylko ścieżce) - inaczej
    # reguła omijałaby też listę domen secure_user (ten sam plik binarny Firefoksa, inne konto).
    services.opensnitch.rules = lib.mkIf config.moje.opensnitch.enable {
      "025-${name}-firefox" = {
        name = "025-${name}-firefox";
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
              data = toString config.users.users.${name}.uid;
            }
          ];
        };
      };
    };

    services.clamav.daemon.settings.OnAccessIncludePath = [ downloadDir ];
  };
}
