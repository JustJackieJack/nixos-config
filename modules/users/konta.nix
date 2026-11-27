# Centralny rejestr kont: kto jest "główny" (root=true, prawdziwy człowiek, własne hasło,
# widoczny na ekranie logowania) a kto "poduser"/piaskownica (szablon=..., zablokowane hasło,
# ukryty na ekranie logowania, wchodzi się tylko przez ego/sudo rodzica). Z tej listy generowane
# JEDNOLICIE dla każdego wpisu: konto systemowe, biała lista polkit (ego --machinectl bez hasła od
# rodzica), reguła sudo-rs (rodzic -> konto, bez hasła) i wpis w hiddenUsers - cztery rzeczy, które
# wcześniej były ręcznie duplikowane w 2-3 plikach na każde nowe konto.
#
# Pole `rodzic` (gdy ustawione) jest też automatycznie przekazywane do szablonu danego konta - te
# szablony, którym na tym zależy (zerotrust, bank), dodają `rodzic` do swojej grupy wymiany/
# dokumentów, żeby mógł tam zaglądać bez przełączania tożsamości. Dla `secure_user`, które celowo
# NIE ma `rodzic` w rejestrze (patrz niżej), ta sama wartość jest podawana ręcznie przez
# `szablonArgs.rodzic`.
#
# Żeby dodać nową piaskownicę dla innego, prawdziwego użytkownika (np. "dziecko-games" dla konta
# "Dziecko", kiedyś): jeden nowy wpis na liście `konta` niżej, nic więcej.
#
# `dostepRodzica = true;` na wpisie daje `rodzic` PEŁNY (rekurencyjny + domyślny ACL) dostęp do
# katalogu tego konta, z własnej sesji rodzica, bez przełączania tożsamości - ten sam mechanizm
# co ClaudeFiles, tylko dla całego katalogu, nie wybranych plików. Domyślnie wyłączone - włącz
# jawnie tam, gdzie potrzebne. Dwa opcjonalne dodatki:
#   - `dostepRodzicaSciezka` - który katalog dostaje ACL, jeśli nie `/home/<nazwa>` (np.
#     game_user trzyma biblioteki gier na `/mnt/games`, nie we własnym domu - patrz niżej).
#   - `dostepRodzicaSkrot` - nazwa dowiązania w domu rodzica (np. "Gry" → `/home/Jacek/Gry`),
#     żeby nie trzeba było pamiętać surowej ścieżki.
#
# Kto NIE jest tu w pełni objęty:
#   - `claude` (pole `szablon` nieustawione) - ma własny, bardziej złożony mechanizm w
#     modules/users/claude/ (MCP, claude-share, ClaudeFiles), inny rodzaj reużywalności.
#   - `secure_user` (pole `rodzic` CELOWO nieustawione) - wymaga HASŁA do wejścia (polkit
#     AUTH_SELF_KEEP), więc nie może dostać automatycznej bezhasłowej reguły, jaką ten plik
#     generuje dla każdego wpisu z `rodzic`; jego własna, hasło-wymagająca reguła polkit jest w
#     modules/users/szablony/bank.nix, niezależna od mechanizmu tutaj.
{ lib, pkgs, ... }:
let
  konta = [
    {
      nazwa = "Jacek";
      uid = 1000;
      opis = "Jacek";
      root = true;
      grupy = [
        "networkmanager"
        "wireshark"
        "proc" # widzi wszystkie procesy przy hidepid
        "shared" # Jacek + claude
        "projects" # Jacek + claude + dev_user
        "paperwork" # Jacek + secure_user ("/home/Paperwork")
      ];
    }
    {
      nazwa = "claude";
      uid = 1001;
      opis = "Claude (asystent)";
      rodzic = "Jacek";
    }
    {
      nazwa = "game_user";
      uid = 1002;
      opis = "Gry (Steam, Heroic)";
      rodzic = "Jacek";
      szablon = "gry";
      szablonArgs = {
        biblioteka = "/mnt/games"; # partycja fizyczna, nie coś wywodzącego się z nazwy konta
      };
      # Łatwy, stały dostęp Jacka do bibliotek gier (modyfikacja save'ów, modów) - bez sudo/ego,
      # od razu w swojej sesji. Ścieżka to "biblioteka" wyżej, nie /home/game_user (tam nic
      # istotnego nie ma - cała biblioteka jest na /mnt/games).
      dostepRodzica = true;
      dostepRodzicaSciezka = "/mnt/games";
      dostepRodzicaSkrot = "Gry";
    }
    {
      nazwa = "zeroroot";
      uid = 1003;
      opis = "Kwarantanna (podejrzane programy)";
      rodzic = "Jacek";
      szablon = "zerotrust";
      # Łatwy, stały dostęp Jacka do CAŁEGO domu zeroroota (nie tylko wąskiego folderu wymiany
      # /srv/zeroroot-exchange) - dużo operacji na plikach podczas pracy z podejrzanymi programami.
      dostepRodzica = true;
      dostepRodzicaSkrot = "Zeroroot";
    }
    {
      nazwa = "secure_user";
      uid = 1004;
      opis = "Bank i urzędy";
      # bez `rodzic` - patrz komentarz na górze pliku
      szablon = "bank";
      szablonArgs = {
        dokumenty = "/home/secure-documents"; # zahardkodowane też w modules/system/backups.nix
        skrotJacek = "BankDocuments";
        rodzic = "Jacek"; # tylko dla grupy dokumentów - NIE daje bezhasłowego wejścia (patrz wyżej)
      };
      grupy = [ "paperwork" ]; # dostęp do stałego, dwukierunkowego "/home/Paperwork"
    }
    {
      nazwa = "dev_user";
      uid = 1005;
      opis = "Kodowanie (projekty, uczelnia)";
      rodzic = "Jacek";
      szablon = "dev";
      grupy = [ "projects" ]; # dostęp do /home/shared/Projects
    }
    {
      nazwa = "browse_user";
      uid = 1006;
      opis = "Główna przeglądarka (izolowana)";
      rodzic = "Jacek";
      szablon = "browse";
      szablonArgs = {
        skrotJacek = "BrowserDownloads";
      };
    }
    {
      nazwa = "vpn_user";
      uid = 1007;
      opis = "Przeglądarka tylko przez VPN";
      rodzic = "Jacek";
      szablon = "vpn";
      szablonArgs = {
        skrotJacek = "VpnDownloads";
      };
    }
    {
      nazwa = "tor_user";
      uid = 1008;
      opis = "Tor Browser (VPN opcjonalny)";
      rodzic = "Jacek";
      szablon = "tor";
      szablonArgs = {
        skrotJacek = "TorDownloads";
      };
    }
  ];

  szablony = {
    gry = import ./szablony/gry.nix;
    dev = import ./szablony/dev.nix;
    zerotrust = import ./szablony/zerotrust.nix;
    bank = import ./szablony/bank.nix;
    browse = import ./szablony/browse.nix;
    vpn = import ./szablony/vpn.nix;
    tor = import ./szablony/tor.nix;
  };

  # zablokowane hasło + ukryte: każde konto, które ma `rodzic` ALBO `szablon` (nie musi mieć
  # obu - claude ma tylko `rodzic`, secure_user celowo tylko `szablon`). Jedyne konto bez żadnego
  # z nich to Jacek - prawdziwy człowiek, widoczny, z własnym hasłem.
  jestPiaskownica = k: (k.szablon or null) != null || (k.rodzic or null) != null;
  maSzablon = k: (k.szablon or null) != null; # trzeba zaimportować odpowiedni modules/users/szablony/*.nix
  maRodzica = k: (k.rodzic or null) != null; # dostaje automatyczną, bezhasłową regułę wejścia
  maDostepRodzica = k: (k.dostepRodzica or false) && maRodzica k;

  kontaZRodzicem = builtins.filter maRodzica konta;
  kontaZDostepem = builtins.filter maDostepRodzica konta;
in
{
  users.mutableUsers = true;

  users.groups = {
    proc.gid = 2000; # widzi wszystkie procesy przy hidepid
    shared.gid = 2001; # Jacek + claude
    projects.gid = 2002; # Jacek + claude + dev_user ("/home/shared/Projects")
    paperwork.gid = 2004; # Jacek + secure_user ("/home/Paperwork")
  };

  users.users = lib.listToAttrs (
    map (k: {
      name = k.nazwa;
      value = {
        isNormalUser = true;
        uid = k.uid;
        description = k.opis or k.nazwa;
        hashedPassword = lib.mkIf (jestPiaskownica k) "!";
        extraGroups = (lib.optional (k.root or false) "wheel") ++ (k.grupy or [ ]);
        # podman bez roota - Jacek, niezależnie od żadnego szablonu (dev.nix ustawia to samo dla
        # swoich instancji, ale Jacek nie przechodzi przez żaden szablon).
        autoSubUidGidRange = lib.mkIf (k.nazwa == "Jacek") true;
      };
    }) konta
  );

  # ego/machinectl bez hasła: TYLKO dla par (rodzic, konto) z listy. Tryb sudo ego ma flagę -H,
  # której sudo-rs nie ma - stąd zawsze --machinectl, nigdy sudo-mode (patrz pliki szablonów).
  security.polkit.extraConfig = ''
    polkit.addRule(function(action, subject) {
      if (action.id == "org.freedesktop.machine1.host-shell" &&
          ${
            lib.concatMapStringsSep " ||\n          " (
              k: ''(subject.user == "${k.rodzic}" && action.lookup("user") == "${k.nazwa}")''
            ) kontaZRodzicem
          }) {
        return polkit.Result.YES;
      }
    });
  '';

  security.sudo-rs.extraRules = map (k: {
    users = [ k.rodzic ];
    runAs = k.nazwa;
    commands = [
      {
        command = "ALL";
        options = [ "NOPASSWD" ];
      }
    ];
  }) kontaZRodzicem;

  services.displayManager.hiddenUsers = map (k: k.nazwa) (builtins.filter jestPiaskownica konta);

  systemd.tmpfiles.rules = [
    # Foldery wspólne Jacek ↔ claude (setgid + domyślne ACL: nowe pliki od razu dostępne dla obu).
    "d /home/shared 0750 root shared -"
    "d /home/shared/Obsidian 2770 Jacek shared -"
    "d /home/shared/Projects 2770 Jacek projects -" # dev_user dostaje dostęp przez grupę "projects"
    "d /home/shared/ForClaude 2770 Jacek shared -" # stare kopie z pokaz-claude (zob. Copies w users/claude/sharing.nix)
    "a+ /home/shared/Obsidian - - - - default:group:shared:rwx,group:shared:rwx"
    "a+ /home/shared/Projects - - - - default:group:projects:rwx,group:projects:rwx"
    "a+ /home/shared/ForClaude - - - - default:group:shared:rwx,group:shared:rwx"
    # Skróty w domu Jacka („L” bez „+”: nie nadpisuje, jeśli coś już tam jest).
    "L /home/Jacek/Obsidian - - - - /home/shared/Obsidian"
    "L /home/Jacek/Projects - - - - /home/shared/Projects"
    "d /home/Jacek/Downloads 0700 Jacek users -" # musi istnieć dla ClamAV (clamonacc)

    # Stały, dwukierunkowy folder Jacek ↔ secure_user (bank/urzędy) - POZA /home/shared celowo:
    # /home/shared samo w sobie jest 0750 dla grupy "shared" (Jacek+claude), a secure_user do niej
    # nie należy i nie powinien - gdyby Paperwork leżał W ŚRODKU /home/shared, trzeba by dodać
    # secure_user do grupy "shared" żeby w ogóle tam wejść, co dałoby mu dostęp też do
    # Obsidian/ForClaude/ClaudeFiles. Jako osobny katalog pod /home, ma własną, wąską grupę.
    "d /home/Paperwork 2770 Jacek paperwork -"
    "a+ /home/Paperwork - - - - default:group:paperwork:rwx,group:paperwork:rwx"

    # Dom game_usera to osobny podwolumin (hosts/justjackpc/disko.nix) - nadaj właściciela po
    # zamontowaniu. Specyficzne dla TEJ instancji szablonu "gry" na TYM hoście, nie coś, co
    # dotyczy każdej przyszłej instancji - stąd tutaj, nie w szablony/gry.nix.
    "d /home/game_user 0700 game_user users -"
  ]
  # Skróty w domu rodzica do kont z dostepRodzica (opcjonalne, patrz dostepRodzicaSkrot w
  # nagłówku) - "L" bez "+": nie nadpisuje, jeśli coś już tam jest.
  ++ map (
    k:
    "L /home/${k.rodzic}/${k.dostepRodzicaSkrot} - - - - ${k.dostepRodzicaSciezka or "/home/${k.nazwa}"}"
  ) (builtins.filter (k: (k.dostepRodzicaSkrot or null) != null) kontaZDostepem);

  # Pełny dostęp rodzica do całego katalogu podusera (opt-in, patrz `dostepRodzica` w nagłówku
  # pliku) - rekurencyjny ACL + domyślny ACL (nowe pliki dziedziczą automatycznie).
  #
  # To jest systemd ONESHOT, NIE activationScript (inaczej niż ClaudeFiles/admin-access.nix) -
  # celowo, i to jest ważne: activationScripts uruchamiają się PRZED zwykłymi jednostkami
  # systemd, w tym PRZED systemd-tmpfiles-setup.service. Gdyby ten sam ACL był ustawiany w
  # activationScript, a potem jakaś reguła systemd.tmpfiles (jak "d /mnt/games 0700 game_user
  # users -" w gry.nix) jeszcze raz zrobiła chmod na TĘ SAMĄ ścieżkę PO naszym setfacl - to
  # chmod na ścieżce z ACL przelicza MASKĘ ACL na nowo z bitów grupy w nowym mode (tu: 0700 →
  # maska 000), więc wpis "u:Jacek:rwX" wciąż by ISTNIAŁ, ale efektywnie nic by nie dawał
  # (maska obcina uprawnienia nazwanego użytkownika) - złapane realnie w teście VM, nie teoria:
  # Jacek dostawał "Permission denied" mimo poprawnie wygenerowanego wpisu ACL. Uruchamiając to
  # PO systemd-tmpfiles-setup.service, nasz setfacl jest zawsze OSTATNIM słowem.
  systemd.services.dostepRodzicowDoPoduserow = {
    description = "Dostęp rodzica (ACL) do kont z dostepRodzica=true w konta.nix";
    after = [
      "systemd-tmpfiles-setup.service"
      "local-fs.target"
    ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "dostep-rodzicow-do-poduserow" (
        lib.concatMapStringsSep "\n" (
          k:
          let
            sciezka = k.dostepRodzicaSciezka or "/home/${k.nazwa}";
          in
          ''
            ${pkgs.acl}/bin/setfacl -R -m "u:${k.rodzic}:rwX" -- "${sciezka}" \
              || { echo "dostepRodzicowDoPoduserow: setfacl (${k.nazwa}) failed" >&2; exit 1; }
            # Domyślny ACL w DWIE strony: nie tylko rodzic widzi nowe pliki, też odwrotnie - jeśli
            # rodzic sam coś tam dogra (np. ręcznie dorzuci plik instalacyjny gry), żeby ${k.nazwa}
            # (właściciel katalogu) mógł to przeczytać/zmodyfikować - inaczej plik Jacka byłby
            # widoczny tylko dla niego, bo właścicielem nowego pliku jest jego twórca, nie katalog.
            ${pkgs.acl}/bin/setfacl -d -m "u:${k.rodzic}:rwX,u:${k.nazwa}:rwX" -- "${sciezka}" \
              || { echo "dostepRodzicowDoPoduserow: default setfacl (${k.nazwa}) failed" >&2; exit 1; }
          ''
        ) kontaZDostepem
      );
    };
  };

  imports = lib.concatMap (
    k:
    lib.optional (maSzablon k) (
      szablony.${k.szablon} (
        { nazwa = k.nazwa; rodzic = k.rodzic or null; } // (k.szablonArgs or { })
      )
    )
  ) konta;
}
