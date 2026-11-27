# OpenSnitch – zapora aplikacyjna (ruch WYCHODZĄCY per program).
# Zasada: Firefox, claude i usługi systemowe zawsze; reszta (Steam, gry, Discord…) pyta przy
# pierwszym połączeniu. Brak odpowiedzi = odmowa jednorazowa (ustawienie w oknie OpenSnitch,
# bo timeout i domyślna akcja okna są w konfiguracji UI, nie demona – patrz README).
#
# Reguły używają DOKŁADNYCH ścieżek ze sklepu Nix (${pkgs.x}), więc po aktualizacji paczki
# reguła zmienia się razem z nią – bez ponownego pytania. Ścieżka musi być plikiem docelowym,
# nie dowiązaniem ani opakowaniem .X-wrapped (OpenSnitch porównuje prawdziwą ścieżkę procesu)
# – pilnuje tego tests/vm.nix.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  allowPath = name: path: {
    name = name;
    enabled = true;
    action = "allow";
    duration = "always";
    operator = {
      type = "simple";
      sensitive = false;
      operand = "process.path";
      data = path;
    };
  };
  # To samo, ale tylko gdy program działa jako root (demon). Dla narzędzi, które może uruchomić
  # każdy (nix, restic): inaczej np. game_user mógłby użyć „nix” do pobrania czegokolwiek bez pytania.
  allowForUid = name: path: uidStr: {
    name = name;
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
          data = path;
        }
        {
          type = "simple";
          operand = "user.id";
          sensitive = false;
          data = uidStr;
        }
      ];
    };
  };
  allowForRoot = name: path: allowForUid name path "0";
  # Blokada (nie pytanie oknem) dla konkretnej ścieżki+UID - precedence, sprawdzane przed resztą
  # reguł, jak blokada zeroroot niżej. Dla Firefoksa Jacka: "ma nie istnieć" ma być twarde, nie
  # "pytanie, które można kliknąć zawsze zezwól" - inaczej to żadna różnica wobec stanu przed
  # izolacją w browse_user.
  blockForUid = name: path: uidStr: {
    name = name;
    enabled = true;
    precedence = true;
    action = "reject";
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
          data = path;
        }
        {
          type = "simple";
          operand = "user.id";
          sensitive = false;
          data = uidStr;
        }
      ];
    };
  };
  uid = u: toString config.users.users.${u}.uid;
  nixCli = config.nix.package.nix-cli or config.nix.package;
in
lib.mkIf config.moje.opensnitch.enable {
  services.opensnitch = {
    enable = true;
    settings = {
      # Gdy okno OpenSnitch nie działa (np. przed zalogowaniem) – odmawiaj.
      DefaultAction = "deny";
      DefaultDuration = "once";
      # Połączenia bez przypisanego procesu (np. ruch jądra WireGuard) przepuszczamy.
      InterceptUnknown = false;
      ProcMonitorMethod = "ebpf";
      Firewall = "nftables";
    };

    rules =
      lib.optionalAttrs (config.moje.nas.montowania != { }) {
        # Montowanie udziału NAS: połączenie robi jądro, ale OpenSnitch przypisuje je procesowi
        # mount.cifs (root) – bez tej reguły udział by się nie zamontował (wykrył test VM).
        "109-mount-cifs" = allowForRoot "109-mount-cifs" "${lib.getBin pkgs.cifs-utils}/bin/mount.cifs";
      }
      // {
        # --- najpierw blokady (precedence = sprawdzane przed resztą) ---
        "000-zeroroot-blokada" = {
          name = "000-zeroroot-blokada";
          enabled = true;
          precedence = true;
          action = "reject";
          duration = "always";
          operator = {
            type = "simple";
            sensitive = false;
            operand = "user.id";
            data = uid "zeroroot";
          };
        };

        # --- użytkownik claude: pełna sieć (ochrona = brak dostępu do sekretów Jacka) ---
        "010-claude" = {
          name = "010-claude";
          enabled = true;
          action = "allow";
          duration = "always";
          operator = {
            type = "simple";
            sensitive = false;
            operand = "user.id";
            data = uid "claude";
          };
        };

        # --- ruch lokalny (localhost): bez tego KAŻDY program pytałby już o zapytanie DNS
        #     do systemd-resolved (127.0.0.53). Właściwe zapytania na zewnątrz robi resolved (reguła 100).
        #     zeroroot i tak jest zablokowany regułą 000 (precedence) i w nftables. ---
        "005-localhost-v4" = {
          name = "005-localhost-v4";
          enabled = true;
          action = "allow";
          duration = "always";
          operator = {
            type = "network";
            sensitive = false;
            operand = "dest.network";
            data = "127.0.0.0/8";
          };
        };
        "005-localhost-v6" = {
          name = "005-localhost-v6";
          enabled = true;
          action = "allow";
          duration = "always";
          operator = {
            type = "simple";
            sensitive = false;
            operand = "dest.ip";
            data = "::1";
          };
        };

        # --- przeglądarka główna ---
        # Firefox JACKA (UID 1000) ma być zablokowany, nie "pytanie, które można kliknąć zawsze
        # zezwól" - główna przeglądarka to teraz browse_user (ma WŁASNĄ regułę "zawsze zezwól",
        # browse.nix), secure_user ma swoją listę domen (bank.nix) - Firefox Jacka wprost nie ma
        # już żadnego uzasadnionego przypadku użycia, stąd blokada, nie reguła "allow".
        "020-firefox-blokada-jacka" = blockForUid "020-firefox-blokada-jacka" "${pkgs.firefox-unwrapped}/lib/firefox/firefox" (
          uid "Jacek"
        );

        # --- usługi systemowe ---
        "100-resolved" =
          allowPath "100-resolved" "${config.systemd.package}/lib/systemd/systemd-resolved";
        "101-timesyncd" =
          allowPath "101-timesyncd" "${config.systemd.package}/lib/systemd/systemd-timesyncd";
        "102-networkmanager" =
          allowPath "102-networkmanager" "${config.networking.networkmanager.package}/bin/NetworkManager";
        # Nix ≥ 2.34: nix.package to opakowanie, a bin/nix w nim to dowiązanie do nix-cli. OpenSnitch
        # widzi PRAWDZIWĄ ścieżkę procesu, więc wskazujemy nix-cli (wykrył to test w maszynie wirtualnej).
        "103-nix-daemon" = allowForRoot "103-nix-daemon" "${nixCli}/bin/nix";
        "104-freshclam" = allowPath "104-freshclam" "${config.services.clamav.package}/bin/freshclam";
        # bin/restic w nixpkgs to opakowanie (makeBinaryWrapper) – proces to bin/.restic-wrapped
        # (wykrył test VM: bez tego codzienna kopia na NAS byłaby blokowana)
        "105-restic" = allowForRoot "105-restic" "${pkgs.restic}/bin/.restic-wrapped";
        "106-cups-socket" =
          allowPath "106-cups-socket" "${config.services.printing.package}/lib/cups/backend/socket";
        "107-cups-ipp" =
          allowPath "107-cups-ipp" "${config.services.printing.package}/lib/cups/backend/ipp";

        # avahi: wykrywanie drukarki (mDNS) – działa też przed zalogowaniem, gdy nie ma okna pytań.
        # (sbin/avahi-daemon to dowiązanie do bin/ – reguła musi wskazywać plik docelowy)
        "108-avahi" = allowPath "108-avahi" "${config.services.avahi.package}/bin/avahi-daemon";

        # --- zadania strażnika (vulnix pobiera bazę CVE) ---
        "110-guardian" = {
          name = "110-guardian";
          enabled = true;
          action = "allow";
          duration = "always";
          operator = {
            type = "simple";
            sensitive = false;
            operand = "user.id";
            data = uid "guardian";
          };
        };
      };
  };

  # Gdy demon padnie, kolejka nftables ma „bypass” – ruch przechodzi BEZ kontroli, dopóki demon
  # nie wstanie. Upstream wznawia po 30 s; skracamy do 2 s (sprawdza tests/vm.nix).
  systemd.services.opensnitchd.serviceConfig.RestartSec = lib.mkForce 2;

  # Okno OpenSnitch (pytania) – uruchamiane w sesji Jacka. Odbiera pytania o WSZYSTKICH
  # użytkowników (także game_user), więc grę zatwierdza się z pulpitu Jacka.
  environment.systemPackages = [ pkgs.opensnitch-ui ];
  systemd.user.services.opensnitch-ui = {
    description = "OpenSnitch – okno pytań";
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    unitConfig.ConditionUser = "Jacek";
    serviceConfig = {
      ExecStart = "${pkgs.opensnitch-ui}/bin/opensnitch-ui";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };
}
