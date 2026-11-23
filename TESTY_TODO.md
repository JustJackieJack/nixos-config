# Testy – stan (2026-11-23)

Wszystkie trzy zestawy PRZECHODZĄ. Uruchamiać po każdej zmianie modułów (każdy ~10–15 min, po kolei):

| Zestaw | Polecenie | Co sprawdza |
|---|---|---|
| system | `nix build .#checks.x86_64-linux.vm -L` | 28 grup: usługi, użytkownicy, hidepid, polkit/ego, sudo-rs, foldery wspólne, daj-claude (z atakami), zapora (też IPv6), zeroroot bez sieci, OpenSnitch (ścieżki, reguły, awaria demona), secure_user, sops, restic (kopia + ODTWORZENIE), NAS, ClamAV, hardening, eskalacja, tryb awaryjny (przełączenie), restart |
| pulpit | `nix build .#checks.x86_64-linux.pulpit -L` | Plasma Wayland, okno OpenSnitch, strażnik w sesji, menu, ego (okno + dźwięk jako game_user), piaskownica zeroroot |
| dyski | `nix build .#checks.x86_64-linux.dyski -L` | disko (GPT, LUKS2, btrfs, ext4), instalacja, rozruch z odblokowaniem LUKS kluczem FIDO2 BEZ hasła, podwoluminy, wspólne wolne miejsce, snapper, scrub, wpis awaryjny |

Gdy DNS w homelabie nie działa: dodać `--option substitute false` (o ile paczki są już lokalnie).

## Nie da się sprawdzić w maszynie wirtualnej (ręcznie po instalacji)
- NVIDIA (sterownik, Wayland), Secure Boot (lanzaboote + klucze w BIOS-ie),
- prawdziwy YubiKey z PIN-em (test używa wirtualnego Canokey bez PIN-u),
- gamescope (wymaga prawdziwej karty – w VM brak VK_EXT_physical_device_drm): `zeroroot-uruchom kitty`,
- Steam/Heroic z gier (pobieranie), okno hasła przy „Bank i urzędy (secure_user)”,
- vulnix (pobiera bazę CVE z internetu), drukarka.

## Błędy znalezione dzięki testom (wszystkie poprawione)
1. daj-claude odsłaniał claude pliki 644 w domu Jacka (np. token gh) → bind mount, dom zawsze 700.
2. OpenSnitch: reguła nix (dowiązanie), avahi (dowiązanie), restic (opakowanie) – nigdy by nie pasowały.
3. OpenSnitch: brak reguły mount.cifs – udział NAS nie montowałby się.
4. NAS i /mnt/games otwarte dla grupy users (= wszystkie konta, w tym zeroroot).
5. Wygasanie dostępu claude do minuty za późno (AccuracySec).
6. Reguła „Firefox zawsze” omijałaby listę domen secure_user.
7. OpenSnitch po awarii wstawał po 30 s (ruch bez kontroli) → 2 s.
8. /var/lib/sops-nix z prawami 0755 → 0700.
9. Puste punkty montowania po restarcie zdradzały nazwy udostępnionych plików → czyszczenie przy rozruchu.
