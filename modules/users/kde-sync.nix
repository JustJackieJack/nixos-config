# kde-sync: kopiowanie "wyglądu" KDE (panele, kolory, czcionki) między kontami.
#   kde-sync export         - z /home/Jacek do trwałej migawki /home/shared/KdeLook
#   kde-sync apply <konto>  - z migawki do /home/<konto> (w tym "apply Jacek" - czyli to też
#                             działa jako backup/restore WŁASNYCH ustawień Jacka)
#
# Celowo krótka, jawna lista plików/katalogów (ELEMENTY poniżej) - to jest "wygląd", nie pełna
# kopia konta. Pełne .config/.local ciągnęłoby też historię (MRU, aktywności, itp.), której nie
# chcemy przenosić między kontami.
#
# Root-owned helper (wzorzec identyczny jak claude-share w modules/users/claude/sharing.nix):
# Jacek ma do niego bezwarunkowe sudo (jeden dokładny /nix/store-path), cała walidacja (czy
# TARGET jest na liście) dzieje się w środku, po stronie roota.
#
# Zmiany widoczne w sesji, która już działa (np. już otwarte "VS Code (dev_user)"), zwykle
# wymagają ponownego zalogowania - KDE czyta te pliki przy starcie Plasmy, kde-sync tylko
# kopiuje pliki, nie przeładowuje żywej sesji.
{ lib, pkgs, ... }:
let
  snapshotDir = "/home/shared/KdeLook";
  targets = [
    "Jacek"
    "claude"
    "game_user"
    "zeroroot"
    "secure_user"
    "dev_user"
  ];

  elementy = [
    ".config/kdeglobals"
    ".config/kwinrc"
    ".config/plasmarc"
    ".config/plasma-org.kde.plasma.desktop-appletsrc" # układ paneli/widgetów
    ".config/kcminputrc"
    ".config/kglobalshortcutsrc"
    ".config/dolphinrc"
    ".local/share/color-schemes"
    ".local/share/plasma"
    ".local/share/aurorae"
  ];

  bashElementy = lib.concatStringsSep " " (map lib.escapeShellArg elementy);
  bashTargets = lib.concatStringsSep "|" targets;

  kdeSync = pkgs.writeShellApplication {
    name = "kde-sync";
    runtimeInputs = with pkgs; [
      coreutils
      rsync
    ];
    text = ''
      elementy=(${bashElementy})

      kopiuj() {
        # kopiuj ZRODLO_BAZA CEL_BAZA - synchronizuje każdy element z listy, zachowując
        # strukturę ścieżki (działa jednolicie dla plików i katalogów).
        src_base="$1" dst_base="$2"
        for e in "''${elementy[@]}"; do
          src="$src_base/$e"
          [ -e "$src" ] || continue
          dst="$dst_base/$e"
          mkdir -p "$(dirname -- "$dst")"
          rsync -a --delete -- "$src" "$(dirname -- "$dst")/"
        done
      }

      case "''${1:-}" in
        export)
          kopiuj /home/Jacek "${snapshotDir}"
          chown -R root:shared -- "${snapshotDir}"
          echo "zapisano migawkę wyglądu KDE z /home/Jacek do ${snapshotDir}" >&2
          ;;
        apply)
          target="''${2:-}"
          case "$target" in
            ${bashTargets}) ;;
            *) echo "niedozwolone konto: $target (dozwolone: ${lib.concatStringsSep ", " targets})" >&2; exit 1 ;;
          esac
          kopiuj "${snapshotDir}" "/home/$target"
          for e in "''${elementy[@]}"; do
            [ -e "/home/$target/$e" ] || continue
            chown -R "$target":users -- "/home/$target/$e"
          done
          echo "wgrano migawkę wyglądu KDE do /home/$target (może wymagać ponownego zalogowania)" >&2
          ;;
        *)
          echo "użycie: kde-sync export | kde-sync apply <${lib.concatStringsSep "|" targets}>" >&2
          exit 1
          ;;
      esac
    '';
  };
in
{
  config = {
    environment.systemPackages = [ kdeSync ];

    systemd.tmpfiles.rules = [
      # Trwała migawka, NIE czyszczona przy starcie (w odróżnieniu od Shared/ w sharing.nix) -
      # to ma działać też jako backup/restore, nie tylko jednorazowy transfer.
      "d ${snapshotDir} 2750 root shared -"
    ];

    security.sudo-rs.extraRules = [
      {
        users = [ "Jacek" ];
        runAs = "root";
        commands = [
          {
            command = "${kdeSync}/bin/kde-sync";
            options = [ "NOPASSWD" ];
          }
        ];
      }
    ];
  };
}
