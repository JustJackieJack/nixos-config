# Szablon "dev": kodowanie (miniprojekty, uczelnia, poprawki do repo) na osobnym, izolowanym
# koncie - rootless Podman + VS Code Dev Containers na nim (patrz CLAUDE.md w repo dla pełnej
# architektury). Wołany z konta.nix, raz per instancja (dziś tylko dev_user).
#
# moje.devUser.domeny: WSPÓLNA dla wszystkich przyszłych instancji tego szablonu (nie
# per-instancja) - świadome uproszczenie "do minimum"; druga instancja na razie dzieliłaby tę
# samą listę dozwolonych domen.
#
# KLUCZE SSH: to konto NIGDY nie trzyma własnego klucza. Zamiast tego dostaje dostęp do DODATKOWEGO
# ssh-agenta w sesji `parent` (np. Jacka) - ten sam wzorzec co request_access/secure-give: konto o
# niskim zaufaniu nigdy nie trzyma sekretu, tylko prosi, zaufana strona potwierdza KAŻDE użycie
# (klucz plikowy: ssh-add -c → okienko za każdym razem; klucz na YubiKeyu: dotyk za każdym razem -
# to wymusza sam protokół FIDO2). Mechanizm po stronie tego konta to `IdentityAgent` w
# `~/.ssh/config`, NIE zmienna SSH_AUTH_SOCK - ssh/git czytają tę ścieżkę z pliku niezależnie od
# tego, czy zmienna środowiskowa przetrwałaby sudo -i / ego --machinectl (realna niepewność, którą
# to obchodzi).
#
# DWA agenty + przekaźnik, nie jeden: `ssh-agent` sam odmawia obsługi klienta, którego UID różni
# się od UID, który go uruchomił - NIEZALEŻNIE od uprawnień na gnieździe (celowe zabezpieczenie w
# OpenSSH, złapane w teście VM: "uid mismatch: peer euid ... != uid ..."). Dlatego:
#   1. prawdziwy ssh-agent Jacka, na WŁASNYM, prywatnym gnieździe (%t = jego $XDG_RUNTIME_DIR,
#      domyślnie 0600 - nikt poza Jackiem go nie dotyka),
#   2. `systemd-socket-proxyd` (gotowe narzędzie z systemd, nic własnego) - też jako Jacek, słucha
#      na gnieździe WIDOCZNYM dla tego konta (grupa), i dla każdego połączenia robi WŁASNE, nowe
#      połączenie do agenta z punktu 1 - jako Jacek, więc przechodzi kontrolę UID. To konto nigdy
#      nie dotyka prawdziwego gniazda z punktu 1.
#
# Jednorazowe czynności RĘCZNE po rebuildzie (nie da się tego zadeklarować w Nixie):
#   - załadować WŁASNE, już istniejące klucze Jacka do tego agenta (nie generować nowych):
#     <name>-ssh-add -c -t 8h ~/.ssh/klucz_pliku   (plikowy - "-c": okienko przy każdym użyciu)
#     <name>-ssh-add ~/.ssh/klucz_na_yubikeyu       (YubiKey - dotyk przy każdym użyciu i tak wymagany)
#   - pierwsze odpalenie "VS Code (<name>)" i instalacja rozszerzenia Dev Containers (rozszerzeń
#     VS Code nie da się deklarować w Nixie bez home-managera, którego nie ma w tym flake).
{
  name,
  parent ? null,
  ...
}:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  uid = config.users.users.${name}.uid;
  agentGroup = "${name}-ssh-agent";
  # Katalog, nie goły plik prosto w /run: systemd --user Jacka (uid != 0) nie może stworzyć
  # pliku/gniazda prosto w /run (root:root 755) - potrzebny wcześniej katalog, w którym Jacek jest
  # właścicielem (tmpfiles.rules niżej, tworzony przy starcie systemu).
  agentSocket = "/run/${agentGroup}/agent.sock"; # publiczne - tu łączy się to konto (przez proxy)
  # Prywatne gniazdo prawdziwego agenta - %t to specyfikator systemd ($XDG_RUNTIME_DIR rodzica),
  # używany w jednostkach; $XDG_RUNTIME_DIR to ta sama wartość jako normalna zmienna powłoki, do
  # użycia w zwykłym skrypcie bash (sshAdd niżej).
  realAgentSpecifier = "%t/${agentGroup}-real.sock";
  realAgentInBash = ''"$XDG_RUNTIME_DIR"/${agentGroup}-real.sock'';

  devHome = pkgs.writeShellApplication {
    name = "${name}-home";
    text = ''exec sudo -u ${name} -i -- "$@"'';
  };

  sshAdd = pkgs.writeShellApplication {
    name = "${name}-ssh-add";
    text = ''exec env SSH_AUTH_SOCK=${realAgentInBash} ${pkgs.openssh}/bin/ssh-add "$@"'';
  };

  vscodeDev = pkgs.makeDesktopItem {
    name = "vscode-${name}";
    desktopName = "VS Code (${name})";
    comment = "Kodowanie na izolowanym koncie ${name}";
    exec = "${pkgs.ego}/bin/ego --machinectl --user=${name} code";
    icon = "vscode";
    categories = [ "Development" ];
  };
  # VS Code jest TYLKO dla tego konta - chowamy zwykły skrót (odpaliłby jako Jacek).
  hideVscode = lib.hiPrio (
    pkgs.runCommand "hide-vscode-${name}" { } ''
      mkdir -p $out/share/applications
      printf '[Desktop Entry]\nType=Application\nName=Visual Studio Code\nNoDisplay=true\nHidden=true\n' \
        > $out/share/applications/code.desktop
    ''
  );

  domainPattern =
    "^(.*\\.)?("
    + lib.concatMapStringsSep "|" (lib.replaceStrings [ "." ] [ "\\." ]) config.moje.devUser.domeny
    + ")$";

  sshAgentConf = pkgs.writeText "${name}-ssh-agent.conf" ''
    Host *
      IdentityAgent ${agentSocket}
  '';
in
{
  options.moje.devUser.domeny = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = "Domeny, z którymi konta dev łączą się bez pytania (z poddomenami). Inne = pytanie OpenSnitch.";
  };

  config = {
    # Rootless Podman - ustawione tutaj (nie w konta.nix), bo to potrzeba specyficzna dla tego
    # szablonu, nie każdego konta. Dostęp do grupy agenta (jeśli jest parent) łączymy w to samo
    # `users.users`, żeby nie zderzyć się z drugim wpisem tej samej ścieżki w tym pliku.
    users.users = {
      ${name} = {
        autoSubUidGidRange = true;
        extraGroups = lib.optional (parent != null) agentGroup;
      };
    } // lib.optionalAttrs (parent != null) { ${parent}.extraGroups = [ agentGroup ]; };

    moje.devUser.domeny = [
      "github.com"
      "api.github.com"
      "raw.githubusercontent.com"
      "objects.githubusercontent.com"
      "registry.npmjs.org"
      "pypi.org"
      "files.pythonhosted.org"
      "crates.io"
      "static.crates.io"
      "index.crates.io"
      "proxy.golang.org"
      "sum.golang.org"
    ];

    environment.systemPackages = [
      devHome
      vscodeDev
      hideVscode
    ] ++ lib.optional (parent != null) sshAdd;

    # Współdzielony ssh-agent rodzica, dostępny tej jednej instancji (i samemu rodzicowi) przez
    # dedykowaną grupę - zero kluczy w tym koncie, patrz nagłówek pliku.
    users.groups = lib.mkIf (parent != null) { ${agentGroup} = { }; };

    # Katalog pod gniazdo proxy - musi istnieć PRZED startem jednostki .socket (ta nie może
    # stworzyć go sama, patrz komentarz przy agentSocket wyżej). /run jest tmpfs - odtwarzane
    # przy każdym starcie systemu, stąd typ "d" (nie "D"/"z") wystarcza.
    systemd.tmpfiles.rules = lib.optional (parent != null) "d /run/${agentGroup} 0750 ${parent} ${agentGroup} -";

    # Gniazdo proxy (jednostka .socket) - systemd sam tworzy sam PLIK gniazda przy aktywacji, z
    # zadanymi tu uprawnieniami (SocketMode/SocketGroup) - katalog musi już istnieć (tmpfiles.rules
    # wyżej). Nie trzeba docinania uprawnień po fakcie (to właśnie był problem z gołym ssh-agent:
    # tworzy własne gniazdo jako 0600, bez bitów grupy, i robi to asynchronicznie względem
    # ExecStartPost - złapane w teście).
    systemd.user.sockets = lib.mkIf (parent != null) {
      "${agentGroup}" = {
        description = "Gniazdo proxy do ssh-agenta Jacka, widoczne dla konta ${name} - patrz modules/users/szablony/dev.nix";
        wantedBy = [ "sockets.target" ];
        unitConfig.ConditionUser = parent;
        socketConfig = {
          ListenStream = agentSocket;
          SocketMode = "0660";
          SocketUser = parent;
          SocketGroup = agentGroup;
        };
      };
    };

    systemd.user.services = lib.mkIf (parent != null) {
      # Prawdziwy agent - trzyma faktyczne klucze, na prywatnym gnieździe, nikt poza Jackiem go
      # nie dotyka (to konto nawet nie wie, że ono istnieje).
      "${agentGroup}-real" = {
        description = "Prawdziwy ssh-agent Jacka (trzyma faktyczne klucze) - patrz modules/users/szablony/dev.nix";
        wantedBy = [ "graphical-session.target" ];
        partOf = [ "graphical-session.target" ];
        unitConfig.ConditionUser = parent;
        serviceConfig = {
          ExecStart = "${pkgs.openssh}/bin/ssh-agent -D -a ${realAgentSpecifier}";
          Restart = "on-failure";
          RestartSec = 2;
        };
      };
      # Przekaźnik: aktywowany przez gniazdo widoczne dla tego konta (jednostka .socket wyżej, ta
      # sama nazwa - systemd paruje je automatycznie), dla każdego połączenia łączy się JAKO JACEK
      # z prawdziwym agentem - stąd przechodzi jego kontrolę UID, której to konto by nie przeszło.
      "${agentGroup}" = {
        description = "Przekaźnik do prawdziwego ssh-agenta Jacka dla konta ${name} (ssh-agent odmawia obsługi klienta z innym UID niż ten, co go uruchomił) - patrz modules/users/szablony/dev.nix";
        after = [ "${agentGroup}-real.service" ];
        requires = [ "${agentGroup}-real.service" ];
        unitConfig.ConditionUser = parent;
        serviceConfig.ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd --exit-idle-time=10min ${realAgentSpecifier}";
      };
    };

    # ~/.ssh/config tego konta wskazuje na współdzielony agent - fragment w config.d jest w pełni
    # zarządzany (bezpiecznie nadpisywany co boot), ale główny ~/.ssh/config NIE jest nadpisywany
    # (tylko dopisujemy brakującą linię Include, jeśli jej nie ma) - żeby nie zgubić ręcznych
    # dopisków (ten sam problem, który już raz złapaliśmy przy CLAUDE.md).
    system.activationScripts."devSshAgent-${name}" = lib.mkIf (parent != null) {
      deps = [ "users" ];
      text = ''
        install -d -m 0700 -o ${name} -g users -- "/home/${name}/.ssh" \
          || { echo "devSshAgent-${name}: install -d .ssh failed" >&2; exit 1; }
        install -d -m 0700 -o ${name} -g users -- "/home/${name}/.ssh/config.d" \
          || { echo "devSshAgent-${name}: install -d config.d failed" >&2; exit 1; }
        install -m 0600 -o ${name} -g users -- "${sshAgentConf}" "/home/${name}/.ssh/config.d/ssh-agent.conf" \
          || { echo "devSshAgent-${name}: install ssh-agent.conf failed" >&2; exit 1; }

        cfg="/home/${name}/.ssh/config"
        if [ ! -f "$cfg" ]; then
          printf 'Include config.d/*.conf\n' > "$cfg" \
            || { echo "devSshAgent-${name}: create $cfg failed" >&2; exit 1; }
          chown ${name} -- "$cfg" || { echo "devSshAgent-${name}: chown $cfg failed" >&2; exit 1; }
          chmod 0600 -- "$cfg" || { echo "devSshAgent-${name}: chmod $cfg failed" >&2; exit 1; }
        elif ! grep -qxF 'Include config.d/*.conf' "$cfg"; then
          tmp="$(mktemp)" || { echo "devSshAgent-${name}: mktemp failed" >&2; exit 1; }
          { printf 'Include config.d/*.conf\n'; cat -- "$cfg"; } > "$tmp" \
            || { echo "devSshAgent-${name}: prepend Include failed" >&2; exit 1; }
          cat -- "$tmp" > "$cfg" || { echo "devSshAgent-${name}: write $cfg failed" >&2; exit 1; }
          rm -f -- "$tmp"
        fi
      '';
    };

    services.opensnitch.rules = lib.mkIf config.moje.opensnitch.enable {
      "040-${name}-domains" = {
        name = "040-${name}-domains";
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
              data = domainPattern;
            }
          ];
        };
      };
    };
  };
}
