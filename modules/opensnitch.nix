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
  zezwalajSciezke = nazwa: sciezka: {
    name = nazwa;
    enabled = true;
    action = "allow";
    duration = "always";
    operator = {
      type = "simple";
      sensitive = false;
      operand = "process.path";
      data = sciezka;
    };
  };
  # To samo, ale tylko gdy program działa jako root (demon). Dla narzędzi, które może uruchomić
  # każdy (nix, restic): inaczej np. game_user mógłby użyć „nix” do pobrania czegokolwiek bez pytania.
  zezwalajRootowi = nazwa: sciezka: {
    name = nazwa;
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
          data = sciezka;
        }
        {
          type = "simple";
          operand = "user.id";
          sensitive = false;
          data = "0";
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
        "109-mount-cifs" = zezwalajRootowi "109-mount-cifs" "${lib.getBin pkgs.cifs-utils}/bin/mount.cifs";
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
        "020-firefox" = zezwalajSciezke "020-firefox" "${pkgs.firefox-unwrapped}/lib/firefox/firefox";

        # --- usługi systemowe ---
        "100-resolved" =
          zezwalajSciezke "100-resolved" "${config.systemd.package}/lib/systemd/systemd-resolved";
        "101-timesyncd" =
          zezwalajSciezke "101-timesyncd" "${config.systemd.package}/lib/systemd/systemd-timesyncd";
        "102-networkmanager" =
          zezwalajSciezke "102-networkmanager" "${config.networking.networkmanager.package}/bin/NetworkManager";
        # Nix ≥ 2.34: nix.package to opakowanie, a bin/nix w nim to dowiązanie do nix-cli. OpenSnitch
        # widzi PRAWDZIWĄ ścieżkę procesu, więc wskazujemy nix-cli (wykrył to test w maszynie wirtualnej).
        "103-nix-daemon" = zezwalajRootowi "103-nix-daemon" "${nixCli}/bin/nix";
        "104-freshclam" = zezwalajSciezke "104-freshclam" "${config.services.clamav.package}/bin/freshclam";
        # bin/restic w nixpkgs to opakowanie (makeBinaryWrapper) – proces to bin/.restic-wrapped
        # (wykrył test VM: bez tego codzienna kopia na NAS byłaby blokowana)
        "105-restic" = zezwalajRootowi "105-restic" "${pkgs.restic}/bin/.restic-wrapped";
        "106-cups-socket" =
          zezwalajSciezke "106-cups-socket" "${config.services.printing.package}/lib/cups/backend/socket";
        "107-cups-ipp" =
          zezwalajSciezke "107-cups-ipp" "${config.services.printing.package}/lib/cups/backend/ipp";

        # avahi: wykrywanie drukarki (mDNS) – działa też przed zalogowaniem, gdy nie ma okna pytań.
        # (sbin/avahi-daemon to dowiązanie do bin/ – reguła musi wskazywać plik docelowy)
        "108-avahi" = zezwalajSciezke "108-avahi" "${config.services.avahi.package}/bin/avahi-daemon";

        # --- zadania strażnika (vulnix pobiera bazę CVE) ---
        "110-straznik" = {
          name = "110-straznik";
          enabled = true;
          action = "allow";
          duration = "always";
          operator = {
            type = "simple";
            sensitive = false;
            operand = "user.id";
            data = uid "straznik";
          };
        };
      };
  };

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
