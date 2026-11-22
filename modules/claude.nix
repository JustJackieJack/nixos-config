# Użytkownik claude: Claude Code działa jako osobne konto.
# Ochrona polega na tym, że claude NIE ma dostępu do sekretów Jacka (klucze SSH, GPG, KWallet,
# Bitwarden, przeglądarka). Sieć ma pełną (opensnitch.nix).
#
# Polecenia dla Jacka:
#   claude-sesja [argumenty]     – uruchamia Claude Code jako claude w bieżącym katalogu
#   daj-claude [-w] [-t 2h] ŚCIEŻKA…  – tymczasowy dostęp (ACL) do plików w /home/Jacek, sam wygasa
#                                  (na katalogach nadrzędnych zostaje samo „przejście” x – bez listowania;
#                                  zabierz-claude bez argumentów czyści wszystko)
#   zabierz-claude [ŚCIEŻKA…]    – zabiera dostęp od razu (bez ścieżki: wszystko w /home/Jacek)
#   pokaz-claude ŚCIEŻKA…        – kopia do /home/wspolne/Dla_Claude (claude widzi kopię, nie oryginał)
#   Chromium (claude) w menu     – przeglądarka dla Claude in Chrome
{ lib, pkgs, ... }:
let
  claudeSesja = pkgs.writeShellApplication {
    name = "claude-sesja";
    text = ''
      # Claude startuje w bieżącym katalogu – musi to być miejsce, do którego ma dostęp
      # (/home/wspolne/... albo coś udostępnione przez daj-claude).
      exec sudo -u claude -- ${pkgs.claude-code}/bin/claude "$@"
    '';
  };

  dajClaude = pkgs.writeShellApplication {
    name = "daj-claude";
    runtimeInputs = with pkgs; [
      acl
      coreutils
      systemd
    ];
    text = ''
      tryb="rX"
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
          w) tryb="rwX" ;;
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

        setfacl -R -P -m "u:claude:$tryb" -- "$p"

        # Katalogi nadrzędne: tylko przejście (x), bez listowania zawartości.
        d=$(dirname -- "$p")
        while [ "$d" != "/home" ]; do
          setfacl -m "u:claude:x" -- "$d"
          d=$(dirname -- "$d")
        done

        systemd-run --user --quiet --unit="zabierz-claude-$(date +%s%N)" --on-active="$czas" \
          "$(command -v setfacl)" -R -P -x u:claude -- "$p"
        echo "claude: $tryb → $p (wygasa za $czas)"
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
        echo "Zabieram claude WSZYSTKIE dostępy w /home/Jacek (może chwilę potrwać)…"
        setfacl -R -P -x u:claude -- /home/Jacek 2>/dev/null || true
        exit 0
      fi
      for sciezka in "$@"; do
        setfacl -R -P -x u:claude -- "$(realpath -e -- "$sciezka")"
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
    dajClaude
    zabierzClaude
    pokazClaude
    chromiumClaude
  ];

  # Jacek może uruchamiać polecenia jako claude bez hasła (i tylko jako claude).
  security.sudo-rs.extraRules = [
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
  ];
}
