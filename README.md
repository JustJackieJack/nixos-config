# nixos-config

Konfiguracja NixOS dla komputerów Jacka (flake). Teraz: `justjackpc`, w przyszłości laptop.

```
flake.nix                  wejścia: nixpkgs 26.05, disko, lanzaboote v1.2.0, sops-nix
hosts/justjackpc/          ten komputer: nazwa, sprzęt, układ dysków (disko)
modules/                   wspólne moduły (każdy plik = jeden temat, opis na górze pliku)
secrets/                   sekrety sops (zaszyfrowane), patrz .sops.yaml
```

| Moduł | Co robi |
|---|---|
| `opcje.nix` | przełączniki `moje.*` (secureBoot, hardening, hidepid, opensnitch, sekrety) |
| `baza.nix` | język (EN + klawiatura/formaty PL), Nix, rozruch, zram, tmpfs, scrub, smartd |
| `secure-boot.nix` | lanzaboote + sbctl |
| `nvidia.nix` | RTX 2070, otwarte moduły |
| `pulpit.nix` | Plasma 6 (Wayland), PipeWire, drukarka, czcionki, Firefox, GnuPG, YubiKey |
| `siec.nix` | NetworkManager (stały MAC), resolved, nftables, avahi, bez SSH |
| `hardening.nix` | sysctl, parametry jądra, blokada modułów, sudo-rs, dbus-broker, hidepid |
| `opensnitch.nix` | zapora aplikacyjna + okno pytań w sesji Jacka |
| `uzytkownicy.nix` | Jacek, claude, game_user, zeroroot, foldery wspólne, reguła polkit dla ego |
| `claude.nix` | Claude Code jako `claude`, `daj-claude` / `zabierz-claude` / `pokaz-claude`, Chromium (claude) |
| `gry.nix` | Steam, Heroic (jako game_user), Proton-GE, gamescope, GameMode, Prism, Wine |
| `zeroroot.nix` | kwarantanna: bez sieci, gamescope + bubblewrap |
| `monitoring.nix` | ClamAV, auditd, Lynis, `nix store verify`, vulnix, strażnik plików startowych i miejsca |
| `kopie.nix` | snapper (/home), restic → NAS, udział Modele_3D (dwa ostatnie po dodaniu sekretów) |
| `pakiety.nix` | aplikacje wybrane przy migracji (lista `APLIKACJE.md` z folderu migracji) |
| `awaryjny.nix` | pozycja „awaryjny” w menu rozruchu: bez hardeningu i bez OpenSnitch |

Sprawdzenie bez instalowania:
- `nix build .#checks.x86_64-linux.justjackpc` – buduje cały system,
- `nix build .#checks.x86_64-linux.vm -L` – **test w maszynie wirtualnej** (`tests/vm.nix`): użytkownicy, hidepid,
  polkit/machinectl (ego), sudo-rs, daj-claude, foldery wspólne, zapora, zeroroot bez sieci, reguły OpenSnitch,
  hardening, strażnik. Wymaga KVM; trwa kilka minut.

---

## Instalacja (kolejność ma znaczenie)

**Przed:** kopie z `Dane ostateczne.md`, eksport z Brave (zakładki, hasła → Bitwarden), wypchnięte repo git.
`disko` **kasuje** Samsunga 980 PRO i Lexara (savy z Protona, Koikatsu, ISO przepadną – zgodnie z decyzją).

1. BIOS (MSI Z370): Secure Boot **wyłączony** na czas instalacji, tryb UEFI, hasło do BIOS-u.
2. Uruchom instalator NixOS (minimal ISO 26.05), połącz z siecią.
3. Skopiuj to repo na pendrive / `git clone` z Forgejo/GitHuba.
4. W `modules/opcje.nix` **na pierwszy raz** ustaw `secureBoot.enable` na `false`
   (albo w `hosts/justjackpc/default.nix`: `moje.secureBoot.enable = false;`).
5. Dyski (pyta o hasło LUKS = **klucz awaryjny**, od razu zapisz w Bitwardenie):
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
- Obsidian i projekty → `/home/wspolne/Obsydian`, `/home/wspolne/Projekty` (w domu Jacka są do nich skróty).
- Claude: `~/.claude`, `~/.claude.json`, `homelab-ai/` → do `/home/claude/`, potem
  `sudo chown -R claude:users /home/claude` (pamięć, ustawienia, MCP, klucze audytora homelabu są tylko u claude).
- Prism `Serwer_Main` → `~/.local/share/PrismLauncher/instances/` (Prism z nix, nie z flatpaka).

### YubiKey do LUKS (po pierwszym uruchomieniu)
```
sudo systemd-cryptenroll /dev/disk/by-partlabel/disk-system-luks --fido2-device=auto --fido2-with-client-pin=yes
# to samo dla drugiego YubiKeya (podłącz tylko jeden naraz)
sudo systemd-cryptenroll /dev/disk/by-partlabel/disk-system-luks    # lista: password + 2× fido2
```
Hasło (klucz awaryjny) zostaje jako zapas. **Nigdy nie resetuj FIDO2 na YubiKeyu** – kasuje też klucze SSH `sk`.

### Secure Boot
1. `sudo sbctl create-keys`
2. Przywróć `secureBoot.enable = true`, `sudo nixos-rebuild switch --flake .#justjackpc`
3. `sudo sbctl verify` – wszystko podpisane oprócz plików `kernel-*` (tak ma być).
4. BIOS: Secure Boot → włącz, tryb **Custom**, „Reset to Setup Mode” / usunięcie kluczy (NIE „Clear All” bez Setup Mode).
5. Po uruchomieniu: `sudo sbctl enroll-keys --microsoft` (klucze Microsoftu zostają – firmware karty).
6. Restart, `bootctl status` → `Secure Boot: enabled (user)`.

### Sekrety (sops) – włączają restic i udział NAS
1. `sudo mkdir -p /var/lib/sops-nix && sudo nix shell nixpkgs#age -c age-keygen -o /var/lib/sops-nix/key.txt && sudo chmod 600 /var/lib/sops-nix/key.txt`
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
| OpenSnitch | Firefox bez pytań; Steam pyta; okno pytań ustawić: **Default action: deny, Duration: once, timeout 30–60 s** (Ustawienia → UI) | tryb „awaryjny” w menu rozruchu |
| OpenSnitch + ProtonVPN | aplikacja to Python → zapyta raz, odpowiedz „always” | – |
| OpenSnitch + Jacek | `nix flake update`, `restic` jako Jacek zapytają (reguły systemowe są tylko dla roota) – „always” | – |
| zeroroot | `zeroroot-uruchom kitty` → okno gamescope; w środku `curl example.com` = błąd, `ls /run/user` = pusto, brak dźwięku | `journalctl -k \| grep zeroroot` |
| daj-claude | `daj-claude ~/Documents/plik.txt` → claude widzi go w `/home/wspolne/Udostepnione/`; po czasie znika (sprawdzone w teście VM) | `zabierz-claude` |
| Remmina → Win7 | `win7-rdp.sh` z `openssl-legacy.cnf` | `OPENSSL_CONF` w skrypcie |
| Drukarka | System Settings → Printers → Add → `socket://192.168.50.157:9100`, sterownik gutenprint (DCP-T500W) lub „IPP Everywhere”, jeśli wykryje | – |
| Prism (mody) | `build.sh` w modach: ścieżki `~/.var/app/org.prismlauncher…` → `~/.local/share/PrismLauncher` | – |

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
