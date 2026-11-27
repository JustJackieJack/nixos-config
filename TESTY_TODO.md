# Testy – stan (2026-11-27)

system i pulpit PRZECHODZĄ (system: 42 grupy, patrz historia niżej).
dyski NIE PRZECHODZI - patrz punkt 12 w "Błędy znalezione" niżej (awaria bootctl, nie dotyczy
usunięcia LUKS - szczegóły tam). Uruchamiać po każdej zmianie modułów (każdy ~10–15 min, po kolei):

| Zestaw | Polecenie | Co sprawdza |
|---|---|---|
| system | `nix build .#checks.x86_64-linux.vm -L` | 42 grupy: usługi, użytkownicy, hidepid, polkit/ego, sudo-rs, foldery wspólne, parentAccess (game_user/zeroroot), claude-code tylko przez claude-session/-home, claude-view/-edit/-copy/-revoke (z atakami), claude-share (wszystkie konta jako źródło), request_command, kde-sync, szablon gry (druga instancja), Paperwork + secure-give/-revoke, zapora (też IPv6), zeroroot bez sieci, OpenSnitch (ścieżki, reguły, awaria demona), secure_user, dev_user (+ wspólny ssh-agent), browse_user, vpn_user/tor_user (przygotowane, bez pliku .wg), sops, restic (kopia + ODTWORZENIE), NAS, ClamAV, hardening, eskalacja, tryb awaryjny (przełączenie), restart |
| pulpit | `nix build .#checks.x86_64-linux.pulpit -L` | Plasma Wayland, okno OpenSnitch, strażnik w sesji, menu, ego (okno + dźwięk jako game_user), piaskownica zeroroot |
| dyski | `nix build .#checks.x86_64-linux.dyski -L` | disko (GPT, btrfs, ext4), instalacja, rozruch, podwoluminy, wspólne wolne miejsce, snapper, scrub, wpis awaryjny |

Gdy DNS w homelabie nie działa: dodać `--option substitute false` (o ile paczki są już lokalnie).

## Nie da się sprawdzić w maszynie wirtualnej (ręcznie po instalacji)
- NVIDIA (sterownik, Wayland), Secure Boot (lanzaboote + klucze w BIOS-ie),
- gamescope (wymaga prawdziwej karty – w VM brak VK_EXT_physical_device_drm): `zeroroot-run kitty`,
- Steam/Heroic z gier (pobieranie), okno hasła przy „Bank i urzędy (secure_user)”,
- vulnix (pobiera bazę CVE z internetu), drukarka.

## Błędy znalezione dzięki testom (wszystkie poprawione)
1. daj-claude (dziś: claude-view/-edit) odsłaniał claude pliki 644 w domu Jacka (np. token gh) → bind mount, dom zawsze 700.
2. OpenSnitch: reguła nix (dowiązanie), avahi (dowiązanie), restic (opakowanie) – nigdy by nie pasowały.
3. OpenSnitch: brak reguły mount.cifs – udział NAS nie montowałby się.
4. NAS i /mnt/games otwarte dla grupy users (= wszystkie konta, w tym zeroroot).
5. Wygasanie dostępu claude do minuty za późno (AccuracySec).
6. Reguła „Firefox zawsze” omijałaby listę domen secure_user.
7. OpenSnitch po awarii wstawał po 30 s (ruch bez kontroli) → 2 s.
8. /var/lib/sops-nix z prawami 0755 → 0700.
9. Puste punkty montowania po restarcie zdradzały nazwy udostępnionych plików → czyszczenie przy rozruchu.
10. Refaktor kont/szablonów (2026-11-27): po rozbiciu `users.nix`/`zeroroot.nix`/`secure.nix`/
    `dev_user/` na centralny rejestr `modules/users/konta.nix` + cztery szablony
    `modules/users/szablony/{gry,dev,zerotrust,bank}.nix`, zgubione przy przepisywaniu i złapane
    przez test: `claude` wypadł z `hiddenUsers`, `extraGroups` dla `claude`/`game_user`/`zeroroot`
    (shared/proc/systemd-journal, video/render), cały blok `systemd.tmpfiles.rules` dla
    `/home/shared/...`, `users.mutableUsers`, `autoSubUidGidRange` dla Jacka, pole `description`.
    Jedna celowa (nie błąd) zmiana zachowania: `sudo -u <konto>` jest teraz symetryczne dla
    każdego konta z `parent` (dawniej tylko `claude` miało to oprócz ego) - test zaktualizowany,
    nie jest to nowe uprawnienie (Jacek i tak miał pełny dostęp przez ego).
11. Zmiana nazwy `wspolne`→`shared` (2026-11-27) + izolacja grup wymiany/dokumentów per-instancja
    szablonów (`<nazwa>-exchange`, `<nazwa>-documents` zamiast jednej, globalnie współdzielonej
    grupy) + hybryda dla `secure_user` (stały `/home/Paperwork` + czasowe `secure-give`/`-revoke`).
    Przy tej okazji złapany **prawdziwy, dawny błąd uprawnień** w `claude-share.sh`
    (`prepare_target_dir`): folder docelowy udostępnienia miał grupę `shared` (`2750`), co
    przypadkowo dawało KAŻDEMU członkowi tej grupy (czyli też `claude`) dostęp do tego, co było
    udostępnione komukolwiek innemu (np. nowo dodanemu `secure_user`), niezależnie od ACL mającego
    to ograniczać do jednego, konkretnego odbiorcy. Istniał od zawsych (`claude`/`game_user`/
    `zeroroot` byli jedynymi celami do teraz, więc nikt nigdy nie sprawdził "czy claude widzi coś
    NIE-dla-claude") - ujawniony dopiero przez nowy test dla `secure_user`. Naprawione: katalog bez
    żadnych uprawnień grupowych (`0700`), dostęp wyłącznie przez jawne wpisy ACL (Jacek - potrzebne
    do `claude-revoke` - i konkretny odbiorca).

12. Usunięcie LUKS z `hosts/justjackpc/disko.nix` (2026-11-27, decyzja użytkownika - nie chce
    szyfrowania dysku): partycja `luks` spłaszczona do zwykłej `root` z btrfs wprost (bez warstwy
    LUKS2), usunięte `boot.initrd.systemd.enable`-owa uwaga o FIDO2 (sama opcja ZOSTAJE - to
    niezależny, nowoczesny domyślny stage 1 initrd, i tak obowiązkowy od NixOS 26.11+). Przy
    weryfikacji testem `dyski` złapany, w kolejności:
    - **Prawdziwy, dawno istniejący błąd, niezależny od LUKS**: `tests/dyski.nix` (`makeDiskoTest`
      z disko) nie ma haczyka na `specialArgs` (inaczej niż `pkgs.testers.runNixOSTest` w
      `vm.nix`/`pulpit.nix`), a `../modules` (przez `apps/games.nix`, `pkgsUnstable`) wymaga
      argumentu modułu `inputs` - test nigdy nie ewaluował się do końca (ani PRZED usunięciem
      LUKS - sprawdzone na commicie `cb555e9`), więc nigdy nie był faktycznie zielony, mimo że
      ten plik wyglądał na gotowy. Naprawione: `_module.args.inputs = inputs;` w
      `extraSystemConfig`.
    - Po tej naprawie test doszedł dalej niż kiedykolwiek (partycjonowanie, formatowanie, montowanie,
      podwoluminy btrfs - wszystko OK bez LUKS), ale **`bootctl --esp-path=/boot --graceful
      install` pada z exit 1** w `nixos-enter --root /mnt -- switch-to-configuration boot`, bez
      czytelnego powodu w logu (tylko nieszkodliwe ostrzeżenie "No machine ID set"). Niezależne od
      usunięcia LUKS - nigdy wcześniej nie było szansy to zobaczyć (test padał wcześniej, w
      ewaluacji). **Jeszcze nie naprawione** - wymaga dalszego dochodzenia (osobno od tej zmiany).
13. Nowy szablon `browse.nix` (2026-11-27, decyzja użytkownika): osobne konto `browse_user` dla
    głównej przeglądarki - ochrona przed atakiem "zaufana strona padła ofiarą supply-chain"
    (złośliwy JS z normalnie-zaufanej domeny, np. przez skompromitowany skrypt reklamowy -
    rozmowa wywołana realnym przykładem: niedawny atak dotykający IKEA/BBC/inne). Izolacja
    identyczna co do zasady jak `dev_user`/`game_user` (osobne UID, bez `wheel`, bez dostępu do
    `shared`/`projects`/`paperwork`/plików Jacka), plus: pełny dostęp do sieci przez własną
    regułę OpenSnitch kluczowaną po UID (nie tylko ścieżce binarki - inaczej omijałaby listę
    domen `secure_user`, ten sam plik binarny Firefoksa), i stały, dwukierunkowy folder
    pobierania (`<nazwa>-downloads`, ten sam wzorzec co Paperwork) ze skrótem w domu Jacka -
    Firefox domyślnie zapisuje tam WSZYSTKO, zero ręcznego "oddawania" plików, a w drugą stronę
    Jacek wrzuca tam plik, który chce wysłać przez stronę. Celowo NIE ma listy domen (jak
    `bank.nix`) - to ma być zwykła, codzienna przeglądarka, nie coś z ceremonią. Test: VM
    zielony przy pierwszej próbie poza jednym złapanym błędem WE WŁASNYM teście (asercja
    zakładała błędnie, że grupa pierwotna konta nazywa się jak konto - w rzeczywistości to
    zawsze "users" dla `isNormalUser`, tak jak już wcześniej zauważone dla `claude`).

14. Przegląd bezpieczeństwa całego systemu (2026-11-27) wykrył dwie rzeczy do poprawy, obie
    naprawione:
    - `access-mcp-game_user`/`access-mcp-zeroroot` (porty 8766/8767 w `mcp-server.nix`) były nie
      tylko martwe (nic nigdy nie rejestrowało tych portów w `.claude.json` tych kont - żaden
      agent Claude nie działa jako `game_user`/`zeroroot`), ale dla `game_user` to była REALNA
      dziura: OpenSnitch bezwarunkowo zezwala na CAŁY ruch do localhosta (reguła
      `005-localhost`, żeby uniknąć pytań o DNS), więc dowolny proces na koncie `game_user` (gra
      ze Steama, mod, wtyczka Heroica) mógł połączyć się z `127.0.0.1:8766` i wywołać
      `request_access` samemu - wyskakujące okienko `kdialog` w sesji Jacka wyglądałoby jak
      prośba od zaufanego `claude`, a w rzeczywistości szłoby od niezaufanego programu. `zeroroot`
      był bezpieczny tylko przypadkiem (nftables blokuje go nawet z localhosta). Naprawione:
      usunięcie obu wpisów, zostaje tylko `claude`.
    - Firefox Jacka zmieniony z "zawsze zezwól" (reguła OpenSnitch `020-firefox`) na twardą
      blokadę (`020-firefox-blokada-jacka`, `precedence=true`, `action=reject`) + ukryty skrót w
      menu (`hide-firefox`, ten sam wzorzec co Chromium/Steam/Heroic/VSCode) - decyzja
      użytkownika: Firefox Jacka ma "nie istnieć", jedyna przeglądarka to teraz `browse_user`.
      Pakiet i globalne polityki (`programs.firefox.policies`) zostają włączone - potrzebują ich
      `browse_user`/`secure_user`.
15. `request_access` (MCP, `access-mcp.py`) uogólniony na wszystkie konta, nie tylko Jacka
    (2026-11-27, decyzja użytkownika: "wszystkie, lecz jest napisane do jakiego konta chcesz się
    dostać"): nowy parametr `source_user` (domyślnie `Jacek`, walidowany przeciw
    `moje.claude.shareSourceAccounts` - nowej, odczytywalnej z `sharing.nix` liście), okienko
    `kdialog` zawsze jawnie nazywa, CZYJE pliki są proszone - Jacek nigdy nie zatwierdza
    "nieoznaczonej" ścieżki. `sourceAccounts` w `sharing.nix` rozszerzony o `secure_user`
    (+ `/home/secure-documents`), `dev_user`, `browse_user` - każde z własnym `firefox-profile`/
    `.ssh` na liście chronionych podścieżek (ta sama zasada co `.ssh`/`.mozilla` Jacka - bycie
    dozwolonym źródłem nie znaczy "bez wyjątków", tylko "bez domyślnego całkowitego zakazu").
16. `parentAccess` włączony dla `game_user` (ścieżka `/mnt/games`, skrót `~/Games`) i `zeroroot`
    (`/home/zeroroot`, skrót `~/Zeroroot`) - 2026-11-27, decyzja użytkownika: potrzebuje stałego,
    wygodnego dostępu do plików tych kont bez `sudo`/`ego` przy każdej operacji. Mechanizm
    sam istniał od refaktoru (punkt 10/13), ale nigdy nie był użyty - po włączeniu złapane TRZY
    prawdziwe błędy, w kolejności:
    - **Zawieszenie całego rozruchu** (nie tylko fail testu): ACL robiony w
      `activationScript` (jak ClaudeFiles) na `/mnt/games` - ta ścieżka nie jest domem konta,
      powstaje z reguły `systemd.tmpfiles`, która jeszcze nie zadziałała na etapie
      activationScripts (te uruchamiają się PRZED zwykłymi jednostkami systemd) - `setfacl`
      dostawał "No such file or directory" i zawieszał `switch-to-configuration` w całości (ten
      sam błąd, już raz opisany w `admin-access.nix`/ClaudeFiles, teraz złapany na nowo w innym
      miejscu). Pierwsza próba naprawy (`install -d` w tym samym activationScript) usunęła
      zawieszenie, ale ujawniła drugi błąd poniżej.
    - **ACL "działał", ale nic nie dawał**: `gry.nix` ma WŁASNĄ regułę `systemd.tmpfiles` na TĘ
      SAMĄ ścieżkę (`d /mnt/games 0700 game_user users -`), która uruchamia się PO
      activationScripts. `chmod` na ścieżce z już ustawionym ACL przelicza MASKĘ ACL z nowych
      bitów grupy (tu: 0700 → maska 000) - wpis `u:Jacek:rwX` wciąż ISTNIAŁ (widoczny w
      `getfacl`), ale efektywnie nic nie dawał (maska obcina uprawnienia nazwanego użytkownika).
      Jacek dostawał "Permission denied" mimo poprawnie wygenerowanego wpisu. Naprawione: cały
      mechanizm przepisany z `activationScript` na zwykłą usługę systemd (`oneshot`,
      `After=systemd-tmpfiles-setup.service`) - nasz `setfacl` jest teraz zawsze PO wszystkich
      regułach tmpfiles, nie przed.
    - **Jednostronny ACL**: domyślny ACL dawał dostęp tylko rodzicowi do NOWYCH plików - plik,
      który Jacek sam dogra do `/mnt/games`, byłby NIEWIDOCZNY dla `game_user` (właściciel
      nowego pliku to jego twórca, nie katalog). Naprawione: domyślny ACL teraz w obie strony
      (`u:${rodzic}:rwX,u:${nazwa}:rwX`).
    - Przy tej okazji też skorygowana jedna STARA asercja testu (`użytkownicy, grupy, foldery`):
      `stat -c %a /mnt/games` już nie będzie dokładnie "700" po dodaniu ACL - nibl grupy w
      `st_mode` odzwierciedla maskę ACL, nie realne prawa grupy "users" - to oczekiwana, poprawna
      zmiana, nie regresja.
17. Nowe konta `vpn_user`/`tor_user` (2026-11-27, decyzja użytkownika) - przygotowane pod
    DODANIE tunelu WireGuard (ProtonVPN), którego plik `.conf` jeszcze nie istnieje. Nowy plik
    `modules/network/vpn-tunnel.nix`: jeden tunel, własna tabela routingu (`moje.vpn.tabela`,
    NIE główna - inaczej VPN objąłby cały system, nie tylko wybrane konta), cały blok (sops,
    `networking.wireguard.interfaces`) za `moje.vpn.enable` (domyślnie `false`) - bezpieczne do
    wdrożenia już teraz, zero ryzyka dla obecnego systemu, zanim dojdzie prawdziwy plik. Dwa
    nowe szablony:
    - `szablony/vpn.nix` (`vpn_user`) - Firefox z kill switchem (nftables, `precedence`-podobna
      reguła odrzuca KAŻDY pakiet tego UID poza interfejsem tunelu) + WŁASNA usługa systemd
      (nie activationScript - ta sama lekcja co punkt 16) dopisująca `ip rule`, zawsze.
    - `szablony/tor.nix` (`tor_user`) - Tor Browser, OpenSnitch zezwala WYŁĄCZNIE prawdziwej
      binarce `tor` (ścieżka `.../TorBrowser/Tor/tor` w pakiecie, nie launcher) + przełącznik
      `tor-vpn-on`/`tor-vpn-off` (root, bezhasłowo dla rodzica) - VPN pod Torem jest opcją, nie
      wymogiem, bo sam Tor już daje anonimowość; gdy włączony, a tunel akurat nie żyje - pakiet
      dostaje "Network unreachable" (pusta tabela), nie cichy powrót do zwykłego internetu, bez
      żadnego dodatkowego kodu na to - to jest właściwość samego mechanizmu `ip rule`.
    - Oba konta: własne, osobne foldery pobierania (`vpn_user-downloads`/`tor_user-downloads`,
      skróty `~/VpnDownloads`/`~/TorDownloads`) - świadomie NIE te same co `browse_user`.
    - Test zielony przy pierwszej próbie - `moje.vpn.enable=false` w teście (jak na realnym
      hoście dziś) sprawdza właśnie stan "przygotowane, jeszcze nieaktywne": brak jednostki
      `wireguard-wgVpn`, brak odszyfrowanego sekretu, `vpn_user` bez sieci (kill switch działa
      mimo nieistniejącego tunelu), przełącznik `tor_user` poprawnie dopisuje/usuwa `ip rule`.
18. `pkgs.claude-code` usunięty z globalnej `environment.systemPackages` (2026-11-27, decyzja
    użytkownika) - był realną dziurą: goły `claude` działał dla KAŻDEGO konta, też jako Jacek,
    czyli pełne obejście izolacji (Claude Code odpalony jako Jacek dostałby jego pełne
    uprawnienia do plików - dokładnie to, przed czym ma chronić całe to konto). `claude-session`/
    `claude-home` działają bez zmian - wołają binarkę po pełnej ścieżce `/nix/store`, nie przez
    PATH.
19. Nazwy wewnętrzne w kodzie Nix (`nazwa`→`name`, `rodzic`→`parent`, `dom`→`homeDir`,
    `profil`→`profileDir`, `ustawienia`→`settings`, `skrot`→`desktopItem`, `konta`→`accounts`,
    `szablony`→`templates`, `dostepRodzica`→`parentAccess` i kilkanaście innych) - przebudowane
    na angielski w `konta.nix`, wszystkich `szablony/*.nix`, `kde-sync.nix`, `vpn-tunnel.nix`,
    `hardening.nix`, `monitoring.nix`, `opensnitch.nix` (2026-11-27/28, decyzja użytkownika po
    audycie nazewnictwa - te pliki były jedyną niekonsekwencją wobec `users/claude/*`, które od
    wcześniejszej sesji już miały angielskie nazwy wewnętrzne). Przy tej okazji też: konto/komendy
    `straznik`→`guardian` (prawdziwa nazwa konta/usługi, nie tylko zmienna Nix - była
    niekonsekwentna wobec reszty angielskich nazw kont), `profil-firefox`→`firefox-profile`
    (katalog na dysku, nie tylko zmienna), `"030-…-domeny"`/`"040-…-domeny"`→`"…-domains"` (nazwy
    reguł OpenSnitch), `nix-store-weryfikacja`→`nix-store-verification`, audit keys
    `jako-root`/`moduly`→`as-root`/`modules`, sops `vpn/klucz-prywatny`→`vpn/private-key`. Nix sam
    wyłapał każde przeoczone odwołanie (błąd "undefined variable" przy buildzie) - jedyne dwa
    realne przeoczenia znalezione tą metodą: wywołanie `szablony/gry.nix` wprost w `tests/vm.nix`
    (`{ nazwa = "dziecko-games"; }`) i `pc.wait_for_unit("dostepRodzicowDoPoduserow.service")` -
    oba naprawione. Test zielony (42/42) bez żadnej innej poprawki.

**Stan**: refaktor `konta.nix`/szablonów + zmiana nazwy `shared` + hybryda `secure_user` +
`browse_user` + usunięcie Firefoksa Jacka + czyszczenie i rozszerzenie access-mcp +
`parentAccess` dla `game_user`/`zeroroot` + `vpn_user`/`tor_user` (przygotowane pod WireGuard) +
blokada bezpośredniego `claude` - zakończone i w pełni zielone (42/42 podtestów, w tym dowód
reużywalności szablonu „gry” na drugiej instancji `dziecko-games`). Usunięcie LUKS - config
poprawny i buduje się, test `dyski` odkrył nowy (niezależny) problem z bootloaderem w testowej
maszynie, patrz punkt 12. Plan: `/home/Jacek/.claude/plans/ethereal-fluttering-dragon.md`.
**Nic z tej sesji nie jest jeszcze scommitowane** (cała dzisiejsza praca - `dev_user`,
`request_command`, `kde-sync`, SDDM `hiddenUsers`, refaktor kont/szablonów, zmiana nazwy `shared`,
izolacja grup, Paperwork/secure-give - leży jako niezacommitowane zmiany na szczycie commita
`cb555e9`).

## Jeszcze otwarte (odłożone wcześniej w tej sesji, nie zapomnieć)
- Nazewnictwo kont (`dev_user`→`dev_jacek` itp.) - rozmowa, decyzja **nigdy nie zapadła ostatecznie**
  (użytkownik zatrzymał to na "tylko rozmowa"), obecny refaktor zachował dzisiejsze nazwy.
- `dev_user`: Etap 2 (pierwszy realny projekt z `devcontainer.json`, forwarding klucza SSH do
  GitHuba) i Etap 3 (wąski klucz do serwera domowego, pełna polityka sieci) - jeszcze nie zaczęte.
- Ręczne czynności dla `dev_user` (nie da się w Nixie): klucz SSH (najlepiej FIDO2/YubiKey),
  instalacja rozszerzenia VS Code Dev Containers.
- `vpn_user`/`tor_user`: tunel WireGuard przygotowany, ale WYŁĄCZONY (`moje.vpn.enable = false`)
  - czeka na plik `.conf` z panelu ProtonVPN (ręczne ściągnięcie przez Jacka, nie da się
    zadeklarować w Nixie). Instrukcja dodania: nagłówek `modules/network/vpn-tunnel.nix`.
