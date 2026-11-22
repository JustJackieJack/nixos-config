# Użytkownik claude: Claude Code działa jako osobne konto.
# Ochrona polega na tym, że claude NIE ma dostępu do sekretów Jacka (klucze SSH, GPG, KWallet,
# Bitwarden, przeglądarka). Sieć ma pełną (opensnitch.nix).
#
# Polecenia dla Jacka:
#   claude-sesja [argumenty]          – uruchamia Claude Code jako claude w bieżącym katalogu
#   daj-claude [-w] [-t 2h] ŚCIEŻKA…  – tymczasowy dostęp do pliku/katalogu z /home/Jacek, sam wygasa.
#                                       claude widzi go pod /home/wspolne/Udostepnione/<nazwa>_<czas>
#   zabierz-claude [ŚCIEŻKA…]         – zabiera dostęp od razu (bez ścieżki: wszystko)
#   pokaz-claude ŚCIEŻKA…             – kopia do /home/wspolne/Dla_Claude (claude widzi kopię, nie oryginał)
#   Chromium (claude) w menu          – przeglądarka dla Claude in Chrome
#
# Dlaczego montowanie, a nie samo ACL: dom Jacka ma 700 i to on chroni pliki 644 (większość).
# Gdyby claude dostał „przejście” (x) przez /home/Jacek, mógłby czytać każdy plik 644 w domu
# (np. ~/.config/gh/hosts.yml) – wykrył to test w maszynie wirtualnej (tests/vm.nix).
# Dlatego udostępniony obiekt jest podmontowany (bind mount) w folderze wspólnym, a dom
# zostaje zamknięty bez wyjątków. ACL na samym obiekcie ustawia Jacek (nie root).
{ lib, pkgs, ... }:
let
  udostepnione = "/home/wspolne/Udostepnione";

  claudeSesja = pkgs.writeShellApplication {
    name = "claude-sesja";
    text = ''
      # Claude startuje w bieżącym katalogu – musi to być miejsce, do którego ma dostęp
      # (/home/wspolne/...).
      exec sudo -u claude -- ${pkgs.claude-code}/bin/claude "$@"
    '';
  };

  # Pomocnik uruchamiany jako root (sudo bez hasła tylko dla Jacka i tylko ten program).
  # Robi WYŁĄCZNIE montowanie/odmontowanie; nie zmienia uprawnień plików.
  claudeMontuj = pkgs.writeShellApplication {
    name = "claude-montuj";
    runtimeInputs = with pkgs; [
      coreutils
      util-linux
      systemd
    ];
    text = ''
      baza="${udostepnione}"
      etap="/run/claude-montuj" # prywatne miejsce na sprawdzenie przed pokazaniem claude
      jacek_uid=1000

      odmontuj() {
        local cel="$1"
        case "$cel" in
          "$baza"/*/* | *..*) echo "zła ścieżka: $cel" >&2; return 1 ;;
          "$baza"/?*) ;;
          *) echo "zła ścieżka: $cel" >&2; return 1 ;;
        esac
        umount -- "$cel" 2>/dev/null || true
        if [ -d "$cel" ]; then rmdir -- "$cel"; elif [ -e "$cel" ]; then rm -f -- "$cel"; fi
      }

      case "''${1:-}" in
        dodaj)
          [ "$#" -eq 4 ] || { echo "użycie: claude-montuj dodaj ro|rw ŹRÓDŁO CZAS" >&2; exit 2; }
          tryb="$2"
          zrodlo="$3"
          czas="$4"
          case "$tryb" in ro | rw) ;; *) echo "zły tryb: $tryb" >&2; exit 2 ;; esac
          systemd-analyze timespan "$czas" > /dev/null 2>&1 || { echo "zły czas: $czas" >&2; exit 2; }
          case "$zrodlo" in /home/Jacek/?*) ;; *) echo "tylko /home/Jacek" >&2; exit 2 ;; esac

          if ! mountpoint -q "$etap"; then
            install -d -m 0700 "$etap"
            mount -t tmpfs -o mode=0700,size=1m tmpfs "$etap"
            mount --make-private "$etap"
          fi

          id="$(date +%Y%m%d-%H%M%S)-$$"
          tmp="$etap/$id"
          if [ -d "$zrodlo" ]; then typ=d; mkdir -- "$tmp"; elif [ -f "$zrodlo" ]; then typ=f; : > "$tmp"; else
            echo "tylko zwykły plik albo katalog" >&2; exit 2
          fi
          opcje="remount,bind,nosuid,nodev"
          [ "$tryb" = ro ] && opcje="$opcje,ro"
          mount --bind -- "$zrodlo" "$tmp"
          mount -o "$opcje" -- "$tmp"

          # Sprawdzamy to, co FAKTYCZNIE się zamontowało (ścieżkę mogła podmienić np. podłożona
          # dowiązanie): właściciel = Jacek, ten sam typ, położenie w domu Jacka.
          ok=1
          [ "$(stat -c %u -- "$tmp")" = "$jacek_uid" ] || ok=0
          if [ "$typ" = d ]; then [ -d "$tmp" ] || ok=0; else [ -f "$tmp" ] || ok=0; fi
          korzen="$(findmnt -n -o FSROOT -M "$tmp")"
          case "$korzen" in */Jacek/*) ;; *) ok=0 ;; esac
          if [ "$ok" != 1 ]; then
            umount -- "$tmp"
            rm -rf -- "$tmp"
            echo "odmowa: zamontowany obiekt nie należy do Jacka" >&2
            exit 1
          fi

          nazwa="$(basename -- "$zrodlo" | tr -c 'A-Za-z0-9._\n-' '_')"
          cel="$baza/''${nazwa}_$id"
          install -d -m 0750 -o root -g wspolne "$baza"
          if [ "$typ" = d ]; then mkdir -- "$cel"; else : > "$cel"; fi
          mount --move -- "$tmp" "$cel"
          if [ "$typ" = d ]; then rmdir -- "$tmp"; else rm -f -- "$tmp"; fi

          systemd-run --quiet --unit="claude-zabierz-$id" --on-active="$czas" --timer-property=AccuracySec=1s \
            "$0" zabierz "$cel"
          echo "$cel"
          ;;
        zabierz)
          if [ "$#" -eq 2 ]; then
            odmontuj "$2"
          else
            for cel in "$baza"/*; do
              [ -e "$cel" ] && odmontuj "$cel"
            done
          fi
          ;;
        *)
          echo "użycie: claude-montuj dodaj ro|rw ŹRÓDŁO CZAS | zabierz [CEL]" >&2
          exit 2
          ;;
      esac
    '';
  };
  montuj = "${claudeMontuj}/bin/claude-montuj";

  dajClaude = pkgs.writeShellApplication {
    name = "daj-claude";
    runtimeInputs = with pkgs; [
      acl
      coreutils
      systemd
    ];
    text = ''
      tryb="rX"
      montowanie="ro"
      czas="2h"
      chronione=(
        .ssh .gnupg .local/share/kwalletd .local/share/keyrings
        .mozilla .thunderbird .config/Bitwarden .config/discord .config/gh .docker
        .config/remmina .local/share/remmina .config/sops .smbcredentials
        .config/chromium .config/Code/User/globalStorage homelab-ai
      )
      uzycie() {
        echo "użycie: daj-claude [-w] [-t CZAS] ŚCIEŻKA…   (-w zapis, CZAS np. 30min, 2h, 1d; domyślnie 2h, tylko odczyt)" >&2
        exit 1
      }
      while getopts "wt:" opcja; do
        case "$opcja" in
          w) tryb="rwX"; montowanie="rw" ;;
          t) czas="$OPTARG" ;;
          *) uzycie ;;
        esac
      done
      shift $((OPTIND - 1))
      [ "$#" -ge 1 ] || uzycie
      # Najpierw sprawdź czas – inaczej dostęp zostałby nadany, a wygaszenie by się nie zaplanowało.
      systemd-analyze timespan "$czas" > /dev/null 2>&1 || { echo "Zły czas: $czas (np. 30min, 2h, 1d)" >&2; exit 1; }

      for sciezka in "$@"; do
        p=$(realpath -e -- "$sciezka")
        case "$p" in
          /home/Jacek/*) ;;
          *) echo "Odmowa: tylko pliki w /home/Jacek (podano: $p)" >&2; exit 1 ;;
        esac
        # Sekrety: odmowa, gdy ścieżka jest W ŚRODKU chronionego miejsca
        # albo gdy chronione miejsce jest w środku ścieżki (np. daj-claude ~/.config).
        for c in "''${chronione[@]}"; do
          c="/home/Jacek/$c"
          case "$p" in
            "$c" | "$c"/* | "$c"-*) echo "Odmowa: $p to sekrety ($c)" >&2; exit 1 ;;
          esac
          case "$c" in
            "$p"/*) echo "Odmowa: $p zawiera sekrety ($c) – udostępnij węższą ścieżkę" >&2; exit 1 ;;
          esac
        done

        # Uprawnienia na samym obiekcie (jako Jacek). Dom i katalogi nadrzędne bez zmian.
        setfacl -R -P -m "u:claude:$tryb" -- "$p"
        if ! cel=$(sudo -n ${montuj} dodaj "$montowanie" "$p" "$czas"); then
          setfacl -R -P -x u:claude -- "$p"
          echo "Nie udało się udostępnić $p" >&2
          exit 1
        fi
        systemd-run --user --quiet --unit="zabierz-claude-$(date +%s%N)" --on-active="$czas" --timer-property=AccuracySec=1s \
          "$(command -v setfacl)" -R -P -x u:claude -- "$p"
        echo "claude: $tryb → $cel (oryginał: $p, wygasa za $czas)"
      done
    '';
  };

  zabierzClaude = pkgs.writeShellApplication {
    name = "zabierz-claude";
    runtimeInputs = with pkgs; [
      acl
      coreutils
    ];
    text = ''
      if [ "$#" -eq 0 ]; then
        echo "Zabieram claude WSZYSTKIE dostępy (może chwilę potrwać)…"
        sudo -n ${montuj} zabierz
        setfacl -R -P -x u:claude -- /home/Jacek 2>/dev/null || true
        exit 0
      fi
      for sciezka in "$@"; do
        p=$(realpath -e -- "$sciezka")
        # odmontuj każde udostępnienie tego obiektu (ten sam plik/katalog = to samo urządzenie+i-węzeł)
        for cel in ${udostepnione}/*; do
          [ -e "$cel" ] || continue
          if [ "$(stat -c %d:%i -- "$cel")" = "$(stat -c %d:%i -- "$p")" ]; then
            sudo -n ${montuj} zabierz "$cel"
          fi
        done
        setfacl -R -P -x u:claude -- "$p"
      done
    '';
  };

  pokazClaude = pkgs.writeShellApplication {
    name = "pokaz-claude";
    runtimeInputs = with pkgs; [ coreutils ];
    text = ''
      [ "$#" -ge 1 ] || { echo "użycie: pokaz-claude ŚCIEŻKA…" >&2; exit 1; }
      cel="/home/wspolne/Dla_Claude"
      for sciezka in "$@"; do
        nazwa="$(basename -- "$sciezka")_$(date +%Y-%m-%d_%H%M%S)"
        cp -r --reflink=auto -- "$sciezka" "$cel/$nazwa"
        chmod -R g+rwX -- "$cel/$nazwa"
        echo "claude widzi kopię: $cel/$nazwa"
      done
    '';
  };

  chromiumClaude = pkgs.makeDesktopItem {
    name = "chromium-claude";
    desktopName = "Chromium (claude)";
    comment = "Przeglądarka użytkownika claude – Claude in Chrome";
    exec = "${pkgs.ego}/bin/ego --machinectl --user=claude chromium";
    icon = "chromium";
    categories = [ "Network" ];
  };
  # Chromium jest TYLKO dla claude – zwykły skrót (uruchamiający jako Jacek) chowamy.
  ukryjChromium = lib.hiPrio (
    pkgs.runCommand "ukryj-chromium" { } ''
      mkdir -p $out/share/applications
      printf '[Desktop Entry]\nType=Application\nName=Chromium\nNoDisplay=true\nHidden=true\n' \
        > $out/share/applications/chromium-browser.desktop
    ''
  );
in
{
  environment.systemPackages = [
    pkgs.claude-code
    pkgs.chromium
    ukryjChromium
    claudeSesja
    claudeMontuj
    dajClaude
    zabierzClaude
    pokazClaude
    chromiumClaude
  ];

  systemd.tmpfiles.rules = [ "d ${udostepnione} 0750 root wspolne -" ];

  security.sudo-rs.extraRules = [
    # Jacek może uruchamiać polecenia jako claude bez hasła (i tylko jako claude).
    {
      users = [ "Jacek" ];
      runAs = "claude";
      commands = [
        {
          command = "ALL";
          options = [ "NOPASSWD" ];
        }
      ];
    }
    # …oraz pomocnika montowania jako root – tylko ten jeden program.
    {
      users = [ "Jacek" ];
      runAs = "root";
      commands = [
        {
          command = montuj;
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];
}
