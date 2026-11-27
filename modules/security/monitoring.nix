# Monitoring bezpieczeństwa:
#   ClamAV (skan przy dostępie: Downloads, zeroroot), auditd, Lynis (co miesiąc),
#   nix store verify (co tydzień: czy nikt nie zmienił plików w /nix/store),
#   vulnix (co tydzień: znane CVE w zainstalowanych paczkach),
#   strażnik plików startowych i miejsca na dysku (powiadomienia na pulpicie Jacka).
# Wyniki: journalctl -u <usługa>. claude (audytor) czyta dziennik.
{ config, pkgs, ... }:
let
  plikiStartowe = pkgs.writeShellApplication {
    name = "straznik-pliki-startowe";
    runtimeInputs = with pkgs; [
      coreutils
      findutils
      diffutils
      libnotify
      util-linux
    ];
    text = ''
      stan="$HOME/.local/state/straznik"
      mkdir -p "$stan"
      sciezki=(
        "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile"
        "$HOME/.config/autostart" "$HOME/.config/systemd/user"
        "$HOME/.config/environment.d" "$HOME/.config/plasma-workspace/env"
        "$HOME/.config/plasma-workspace/shutdown" "$HOME/.ssh/authorized_keys"
        "$HOME/.ssh/config" "$HOME/.ssh/rc"
      )
      nowe="$stan/sumy.nowe"
      : > "$nowe"
      for s in "''${sciezki[@]}"; do
        [ -e "$s" ] && find "$s" -type f -exec sha256sum {} + >> "$nowe"
      done
      sort -o "$nowe" "$nowe"
      if [ -f "$stan/sumy" ] && ! cmp -s "$stan/sumy" "$nowe"; then
        # diff zwraca 1, gdy są różnice – przy pipefail to nie jest błąd skryptu
        zmiany=$({ diff "$stan/sumy" "$nowe" || true; } | grep -E '^[<>]' | awk '{print $1, $3}' | sort -u -k2 | head -20 || true)
        logger -p user.warning -t straznik "Zmiana w plikach startowych: $zmiany"
        notify-send -u critical -a Strażnik "Zmiana w plikach startowych" "$zmiany" || true
      fi
      mv "$nowe" "$stan/sumy"
    '';
  };

  miejsceNaDysku = pkgs.writeShellApplication {
    name = "straznik-miejsce";
    runtimeInputs = with pkgs; [
      coreutils
      libnotify
      util-linux
    ];
    text = ''
      for punkt in / /mnt/games; do
        [ -d "$punkt" ] || continue
        zajete=$(df --output=pcent "$punkt" | tail -1 | tr -dc '0-9')
        if [ "$zajete" -ge 85 ]; then
          logger -p user.warning -t straznik "$punkt zajęte w $zajete%"
          notify-send -u critical -a Strażnik "Mało miejsca" "$punkt zajęte w $zajete%" || true
        fi
      done
    '';
  };

  uslugaJacka = opis: program: {
    description = opis;
    unitConfig.ConditionUser = "Jacek";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${program}/bin/${program.name}";
    };
  };
  timerJacka = kiedy: {
    wantedBy = [ "timers.target" ];
    unitConfig.ConditionUser = "Jacek";
    timerConfig = {
      OnCalendar = kiedy;
      Persistent = true;
    };
  };
in
{
  # --- ClamAV ---
  services.clamav = {
    daemon.enable = true;
    updater.enable = true;
    clamonacc.enable = true;
    daemon.settings = {
      OnAccessIncludePath = [
        "/home/Jacek/Downloads"
        "/srv/zeroroot-exchange"
        "/home/zeroroot"
      ];
      OnAccessExcludeUname = "clamav";
      # Tylko wykrywanie i wpis w dzienniku (blokowanie dostępu potrafi zawiesić programy).
      OnAccessPrevention = false;
    };
  };

  # --- auditd: kto i co zmienia w ważnych miejscach ---
  security.auditd.enable = true;
  security.audit = {
    enable = true;
    rules = [
      # polecenia wykonywane jako root przez zalogowanych użytkowników
      "-a always,exit -F arch=b64 -S execve -F euid=0 -F auid>=1000 -F auid!=unset -k jako-root"
      # ładowanie / usuwanie modułów jądra
      "-a always,exit -F arch=b64 -S init_module,finit_module,delete_module -k moduly"
      # klucze Secure Boot i sops
      "-w /var/lib/sbctl -p wa -k secureboot"
      "-w /var/lib/sops-nix -p wa -k sops"
    ];
  };

  # --- konto dla zadań okresowych (stały UID → reguła w OpenSnitch) ---
  users.users.straznik = {
    isSystemUser = true;
    uid = 399;
    group = "straznik";
  };
  users.groups.straznik.gid = 399;

  systemd.services = {
    nix-store-weryfikacja = {
      description = "Sprawdzenie integralności /nix/store";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${config.nix.package}/bin/nix store verify --all --no-trust";
        Nice = 19;
        IOSchedulingClass = "idle";
      };
    };
    vulnix = {
      description = "Znane podatności (CVE) w paczkach systemu";
      path = [ config.nix.package ]; # vulnix woła nix-store / nix
      serviceConfig = {
        Type = "oneshot";
        User = "straznik";
        StateDirectory = "vulnix";
        Environment = "HOME=/var/lib/vulnix";
        ExecStart = "${pkgs.vulnix}/bin/vulnix --system";
        SuccessExitStatus = "0 1 2"; # vulnix kończy się 2, gdy znajdzie podatności
        Nice = 19;
      };
    };
    lynis = {
      description = "Audyt bezpieczeństwa Lynis";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.lynis}/bin/lynis audit system --cronjob --quiet";
        Nice = 19;
      };
    };
  };

  systemd.timers = {
    nix-store-weryfikacja = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "weekly";
        Persistent = true;
        RandomizedDelaySec = "2h";
      };
    };
    vulnix = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "weekly";
        Persistent = true;
        RandomizedDelaySec = "2h";
      };
    };
    lynis = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "monthly";
        Persistent = true;
      };
    };
  };

  # --- strażnik w sesji Jacka (powiadomienia KDE) ---
  systemd.user.services = {
    straznik-pliki-startowe = uslugaJacka "Strażnik: pliki startowe" plikiStartowe;
    straznik-miejsce = uslugaJacka "Strażnik: miejsce na dysku" miejsceNaDysku;
  };
  systemd.user.timers = {
    straznik-pliki-startowe = timerJacka "hourly";
    straznik-miejsce = timerJacka "hourly";
  };

  environment.systemPackages = with pkgs; [
    lynis
    vulnix
    clamtk
  ];
}
