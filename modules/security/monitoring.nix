# Monitoring bezpieczeństwa:
#   ClamAV (skan przy dostępie: Downloads, zeroroot), auditd, Lynis (co miesiąc),
#   nix store verify (co tydzień: czy nikt nie zmienił plików w /nix/store),
#   vulnix (co tydzień: znane CVE w zainstalowanych paczkach),
#   guardian plików startowych i miejsca na dysku (powiadomienia na pulpicie Jacka).
# Wyniki: journalctl -u <usługa>. claude (audytor) czyta dziennik.
{ config, pkgs, ... }:
let
  startupFilesWatcher = pkgs.writeShellApplication {
    name = "guardian-startup-files";
    runtimeInputs = with pkgs; [
      coreutils
      findutils
      diffutils
      libnotify
      util-linux
    ];
    text = ''
      state="$HOME/.local/state/guardian"
      mkdir -p "$state"
      paths=(
        "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile"
        "$HOME/.config/autostart" "$HOME/.config/systemd/user"
        "$HOME/.config/environment.d" "$HOME/.config/plasma-workspace/env"
        "$HOME/.config/plasma-workspace/shutdown" "$HOME/.ssh/authorized_keys"
        "$HOME/.ssh/config" "$HOME/.ssh/rc"
      )
      new="$state/sumy.nowe"
      : > "$new"
      for s in "''${paths[@]}"; do
        [ -e "$s" ] && find "$s" -type f -exec sha256sum {} + >> "$new"
      done
      sort -o "$new" "$new"
      if [ -f "$state/sumy" ] && ! cmp -s "$state/sumy" "$new"; then
        # diff zwraca 1, gdy są różnice – przy pipefail to nie jest błąd skryptu
        changes=$({ diff "$state/sumy" "$new" || true; } | grep -E '^[<>]' | awk '{print $1, $3}' | sort -u -k2 | head -20 || true)
        logger -p user.warning -t guardian "Zmiana w plikach startowych: $changes"
        notify-send -u critical -a Strażnik "Zmiana w plikach startowych" "$changes" || true
      fi
      mv "$new" "$state/sumy"
    '';
  };

  diskSpaceWatcher = pkgs.writeShellApplication {
    name = "guardian-disk-space";
    runtimeInputs = with pkgs; [
      coreutils
      libnotify
      util-linux
    ];
    text = ''
      for mountpoint in / /mnt/games; do
        [ -d "$mountpoint" ] || continue
        used=$(df --output=pcent "$mountpoint" | tail -1 | tr -dc '0-9')
        if [ "$used" -ge 85 ]; then
          logger -p user.warning -t guardian "$mountpoint zajęte w $used%"
          notify-send -u critical -a Strażnik "Mało miejsca" "$mountpoint zajęte w $used%" || true
        fi
      done
    '';
  };

  jacekService = description: program: {
    inherit description;
    unitConfig.ConditionUser = "Jacek";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${program}/bin/${program.name}";
    };
  };
  jacekTimer = schedule: {
    wantedBy = [ "timers.target" ];
    unitConfig.ConditionUser = "Jacek";
    timerConfig = {
      OnCalendar = schedule;
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
      "-a always,exit -F arch=b64 -S execve -F euid=0 -F auid>=1000 -F auid!=unset -k as-root"
      # ładowanie / usuwanie modułów jądra
      "-a always,exit -F arch=b64 -S init_module,finit_module,delete_module -k modules"
      # klucze Secure Boot i sops
      "-w /var/lib/sbctl -p wa -k secureboot"
      "-w /var/lib/sops-nix -p wa -k sops"
    ];
  };

  # --- konto dla zadań okresowych (stały UID → reguła w OpenSnitch) ---
  users.users.guardian = {
    isSystemUser = true;
    uid = 399;
    group = "guardian";
  };
  users.groups.guardian.gid = 399;

  systemd.services = {
    nix-store-verification = {
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
        User = "guardian";
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
    nix-store-verification = {
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

  # --- guardian w sesji Jacka (powiadomienia KDE) ---
  systemd.user.services = {
    guardian-startup-files = jacekService "Strażnik: pliki startowe" startupFilesWatcher;
    guardian-disk-space = jacekService "Strażnik: miejsce na dysku" diskSpaceWatcher;
  };
  systemd.user.timers = {
    guardian-startup-files = jacekTimer "hourly";
    guardian-disk-space = jacekTimer "hourly";
  };

  environment.systemPackages = with pkgs; [
    lynis
    vulnix
    clamtk
  ];
}
