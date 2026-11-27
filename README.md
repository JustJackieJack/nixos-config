# nixos-config

Konfiguracja NixOS dla komputerów Jacka (flake). Teraz: `justjackpc`, w przyszłości laptop.

```
flake.nix                  wejścia: nixpkgs 26.05, disko, lanzaboote v1.2.0, sops-nix
hosts/justjackpc/          ten komputer: nazwa, sprzęt, układ dysków (disko)
modules/                   wspólne moduły, w podfolderach wg kategorii (każdy plik = jeden temat, opis na górze pliku)
secrets/                   sekrety sops (zaszyfrowane), patrz .sops.yaml
```

Podział `modules/` na podfoldery (`system/`, `security/`, `users/`, `desktop/`, `apps/`, `network/`) wzorowany
na tym, jak grupuje swoje moduły sam nixpkgs (`nixos/modules/{services,security,hardware,...}`) –
patrz [NixOS Wiki: NixOS modules](https://wiki.nixos.org/wiki/NixOS_modules). Układ katalogów flake nie ma
jednego oficjalnego standardu (patrz [dyskusja na Discourse](https://discourse.nixos.org/t/how-do-you-structure-your-nixos-configs/65851)) –
to świadomy wybór, nie wymóg.

| Moduł | Co robi |
|---|---|
| `system/options.nix` | przełączniki `moje.*` (secureBoot, hardening, hidepid, opensnitch, sekrety) |
| `system/base.nix` | język (EN + klawiatura/formaty PL), Nix, rozruch, zram, tmpfs, scrub, smartd |
| `security/secure-boot.nix` | lanzaboote + sbctl |
| `desktop/nvidia.nix` | RTX 2070, otwarte moduły |
| `desktop/desktop.nix` | Plasma 6 (Wayland), PipeWire, drukarka, czcionki, Firefox, GnuPG, YubiKey |
| `network/network.nix` | NetworkManager (stały MAC), resolved, nftables, avahi, bez SSH |
| `network/vpn-tunnel.nix` | tunel WireGuard (ProtonVPN) dla `vpn_user`/`tor_user` - `moje.vpn.enable` (domyślnie false, czeka na plik `.conf`), osobna tabela routingu |
| `security/hardening.nix` | sysctl, parametry jądra, blokada modułów, sudo-rs, dbus-broker, hidepid |
| `security/opensnitch.nix` | zapora aplikacyjna + okno pytań w sesji Jacka |
| `users/konta.nix` | centralny rejestr kont (Jacek, claude, game_user, zeroroot, secure_user, dev_user, browse_user, vpn_user, tor_user): UID, hasło/widoczność na ekranie logowania, reguła polkit/sudo-rs dla ego, `/home/shared` (foldery Jacek↔claude), flaga `parentAccess` |
| `users/szablony/{gry,dev,zerotrust,bank,browse,vpn,tor}.nix` | wielokrotnie używalne szablony kont (funkcje `{ name, parent, ... }:`) wołane z `konta.nix` - każdy generuje własną, izolowaną grupę wymiany/dokumentów per instancja |
| `users/claude/` | Claude Code jako `claude`, `claude-view` / `claude-edit` / `claude-copy` / `claude-revoke`, `access-mcp` (`request_access` + `request_command`), Chromium (claude) |
| `apps/games.nix` | Steam, Heroic (globalne pakiety/włączenia; konto per instancja w `szablony/gry.nix`), Proton-GE, gamescope, GameMode, Prism, Wine |
| `users/kde-sync.nix` | `kde-sync export`/`apply <konto>` - migawka "wyglądu" KDE (panele, kolory, czcionki) do przeniesienia między kontami lub po reinstalacji |
| `security/monitoring.nix` | ClamAV, auditd, Lynis, `nix store verify`, vulnix, strażnik plików startowych i miejsca |
| `system/backups.nix` | snapper (/home), restic → NAS, udział Modele_3D (dwa ostatnie po dodaniu sekretów) |
| `apps/packages.nix` | aplikacje wybrane przy migracji (lista `APLIKACJE.md` z folderu migracji) |
| `system/emergency.nix` | pozycja „awaryjny” w menu rozruchu: bez hardeningu i bez OpenSnitch |

Sprawdzenie bez instalowania (szczegóły i lista ręcznych testów: `TESTY_TODO.md`):
- `nix build .#checks.x86_64-linux.justjackpc` – buduje cały system,
- `nix build .#checks.x86_64-linux.vm -L` – test systemu w maszynie wirtualnej (35 grup),
- `nix build .#checks.x86_64-linux.pulpit -L` – test pulpitu (Plasma, OpenSnitch, ego, zeroroot),
- `nix build .#checks.x86_64-linux.dyski -L` – instalacja na układzie disko, btrfs, snapper.

---

## Instalacja (kolejność ma znaczenie)

**Przed:** kopie z `Dane ostateczne.md`, eksport z Brave (zakładki, hasła → Bitwarden), wypchnięte repo git.
`disko` **kasuje** Samsunga 980 PRO i Lexara (savy z Protona, Koikatsu, ISO przepadną – zgodnie z decyzją).

1. BIOS (MSI Z370): Secure Boot **wyłączony** na czas instalacji, tryb UEFI, hasło do BIOS-u.
2. Uruchom instalator NixOS (minimal ISO 26.05), połącz z siecią.
3. Skopiuj to repo na pendrive / `git clone` z Forgejo/GitHuba.
4. W `modules/system/options.nix` **na pierwszy raz** ustaw `secureBoot.enable` na `false`
   (albo w `hosts/justjackpc/default.nix`: `moje.secureBoot.enable = false;`).
5. Dyski:
   ```
   sudo nix --experimental-features "nix-command flakes" run github:nix-community/disko -- \
     --mode destroy,format,mount ./hosts/justjackpc/disko.nix
   ```
6. Porównaj sprzęt: `nixos-generate-config --no-filesystems --root /mnt --show-hardware-config`
   z `hosts/justjackpc/hardware.nix` (zwykle wystarczy to, co jest).
7. `sudo nixos-install --flake .#justjackpc` → ustaw hasło roota. Potem:
   `sudo nixos-enter --root /mnt -c 'passwd Jacek'`.
8. Restart, logowanie, sprawdzenie, że Plasma i NVIDIA działają (`nvidia-smi`).
9. BIOS: **wyłącz rozruch z USB** (zostaje tylko dysk systemowy) – razem z hasłem do BIOS-u i Secure Boot
   to ochrona przed uruchomieniem obcego systemu.

### Dane po instalacji (z kopii wg `Dane ostateczne.md`)
- Obsidian i projekty → `/home/shared/Obsidian`, `/home/shared/Projects` (w domu Jacka są do nich skróty).
- Claude: `~/.claude`, `~/.claude.json`, `homelab-ai/` → do `/home/claude/`, potem
  `sudo chown -R claude:users /home/claude` (pamięć, ustawienia, MCP, klucze audytora homelabu są tylko u claude).
- Prism `Serwer_Main` → `~/.local/share/PrismLauncher/instances/` (Prism z nix, nie z flatpaka).

### Secure Boot
1. `sudo sbctl create-keys`
2. Przywróć `secureBoot.enable = true`, `sudo nixos-rebuild switch --flake .#justjackpc`
3. `sudo sbctl verify` – wszystko podpisane oprócz plików `kernel-*` (tak ma być).
4. BIOS: Secure Boot → włącz, tryb **Custom**, „Reset to Setup Mode” / usunięcie kluczy (NIE „Clear All” bez Setup Mode).
5. Po uruchomieniu: `sudo sbctl enroll-keys --microsoft` (klucze Microsoftu zostają – firmware karty).
6. Restart, `bootctl status` → `Secure Boot: enabled (user)`.

### Sekrety (sops) – włączają restic i udział NAS
1. `sudo install -d -m 0700 /var/lib/sops-nix && sudo nix shell nixpkgs#age -c age-keygen -o /var/lib/sops-nix/key.txt && sudo chmod 600 /var/lib/sops-nix/key.txt`
   → klucz publiczny do `.sops.yaml`, prywatny do Bitwardena.
2. Klucze admina z YubiKeyów: `age-plugin-yubikey` (najpierw zmień domyślny PIN/PUK PIV).
3. `nix develop` → `sops secrets/justjackpc.yaml`, wpisy: `restic/repo`, `restic/haslo`, `nas/modele`
   (ten ostatni: zawartość jak dawne `~/.smbcredentials-modele`).
   Repozytorium `sftp:` wymaga klucza SSH **roota** do NAS (restic działa jako root); `rest:` – tylko hasło w adresie.
4. `git add secrets/justjackpc.yaml` (flake widzi tylko pliki dodane do gita) → `nixos-rebuild switch`.

---

## Po instalacji – do przetestowania
| Co | Jak sprawdzić | Gdy nie działa |
|---|---|---|
| hidepid | `ps aux` jako Jacek widzi wszystko; KDE, polkit (montowanie, sieć) działają | `moje.hardening.hidepid = false` |
| ego / game_user | menu → „Steam (game_user)” startuje, jest dźwięk | `journalctl --user -b`, reguła polkit |
| Steam: biblioteka | Steam → Storage → dodaj `/mnt/games/SteamLibrary` | właściciel `/mnt/games` = game_user |
| Heroic: biblioteka | Settings → Default installation path: `/mnt/games/Heroic` (prefiksy Wine też tam) | jw. |
| OpenSnitch | Steam pyta; okno pytań ustawić: **Default action: deny, Duration: once, timeout 30–60 s** (Ustawienia → UI) | tryb „awaryjny” w menu rozruchu |
| OpenSnitch + ProtonVPN | aplikacja to Python → zapyta raz, odpowiedz „always” | – |
| OpenSnitch + Jacek | `nix flake update`, `restic` jako Jacek zapytają (reguły systemowe są tylko dla roota) – „always” | – |
| zeroroot | `zeroroot-run kitty` → okno gamescope; w środku `curl example.com` = błąd, `ls /run/user` = pusto, brak dźwięku | `journalctl -k \| grep zeroroot` |
| claude-view | `claude-view ~/Documents/plik.txt` → claude widzi oryginał (tylko odczyt) w `/home/shared/Views/claude/`; po czasie znika (sprawdzone w teście VM) | `claude-revoke`, `claude-edit` (zapis), `claude-copy` (trwała kopia) |
| Remmina → Win7 | `win7-rdp.sh` z `openssl-legacy.cnf` | `OPENSSL_CONF` w skrypcie |
| Drukarka | System Settings → Printers → Add → `socket://192.168.50.157:9100`, sterownik gutenprint (DCP-T500W) lub „IPP Everywhere”, jeśli wykryje | – |
| Bank i urzędy | menu → „Bank i urzędy (secure_user)” → okienko hasła → Firefox. Dopisz domeny banku w `moje.secure.domeny` (host), inne strony OpenSnitch zgłosi pytaniem. YubiKey jako klucz logowania w banku/login.gov.pl | `journalctl --user -b`, reguła polkit |
| Prism (mody) | `build.sh` w modach: ścieżki `~/.var/app/org.prismlauncher…` → `~/.local/share/PrismLauncher` | – |
| Główna przeglądarka (browse_user) | menu → „Firefox (browse_user)” - bez hasła, pełna sieć. Firefox Jacka NIE istnieje (zablokowany w OpenSnitch, skrót ukryty) - to jedyna przeglądarka do zwykłego surfowania. Pobrane pliki lądują w `~/BrowserDownloads` (to samo widzi `browse_user`) | `journalctl --user -b`, reguła OpenSnitch `025-browse_user-firefox` |
| dev_user (kodowanie) | menu → „VS Code (dev_user)” - bez hasła, rootless Podman. Klucze SSH ŁADUJE Jacek: `dev_user-ssh-add -c -t 8h ~/.ssh/klucz_pliku` (plikowy) albo `dev_user-ssh-add ~/.ssh/klucz_na_yubikeyu` (YubiKey) - `dev_user` nigdy nie ma własnego klucza, tylko dostęp do agenta Jacka przez przekaźnik | `journalctl --user -b dev_user-ssh-agent dev_user-ssh-agent-real` |
| vpn_user/tor_user (VPN/Tor) | DZIŚ WYŁĄCZONE (`moje.vpn.enable = false`) - instrukcja dodania pliku `.conf` z ProtonVPN: nagłówek `modules/network/vpn-tunnel.nix`. Po włączeniu: menu → „Firefox przez VPN (vpn_user)” (zawsze VPN, kill switch) i „Tor Browser (tor_user)” (`sudo tor-vpn-on`/`sudo tor-vpn-off` - VPN pod Torem opcjonalny) | `systemctl status wireguard-wgVpn`, `ip rule list` |

## SSH (zamiast SSH Pilot)
SSH Pilot nie jest w nixpkgs. Zamienniki:
- **Konsole → SSH Manager** (wtyczka Konsole: Plugins → Show SSH Manager): drzewo połączeń z folderami,
  import z `~/.ssh/config` jednym przyciskiem. Grupy z SSH Pilot (MGMT, DNS, Apps, Monitor, DMZ) odtwarzasz jako foldery.
- **sshs** w terminalu (kitty): lista hostów z `~/.ssh/config`, wyszukiwanie, Enter = połącz.
Oba czytają `~/.ssh/config` (28 hostów, port 2137, klucze YubiKey) – nic nie trzeba przepisywać.
Przy okazji popraw w configu host `SearXNG-12005`: `User 10.0.120.5` to błąd.

## Codzienna praca
```
nix flake update                     # nowe wersje paczek (co tydzień / dwa)
sudo nixos-rebuild switch --flake .#justjackpc
nvd diff /run/booted-system /run/current-system   # co się zmieniło
nix fmt                              # formatowanie
```
Zła aktualizacja → w menu rozruchu poprzednia generacja (15 ostatnich).
