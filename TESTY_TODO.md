# Testy – plan (aktualizacja 2026-11-23)

Testy przerwane na prośbę Jacka. **Rano zaczynamy od testów.**

## Gdzie skończyliśmy
`tests/vm.nix` (`nix build .#checks.x86_64-linux.vm -L`) – ostatni pełny przebieg doszedł do NAS.
Przeszły: usługi, użytkownicy, hidepid, polkit/machinectl (ego), sudo-rs, foldery wspólne, daj-claude
(z atakami na pomocnika root), zapora, zeroroot bez sieci (z OpenSnitch i bez), ścieżki reguł OpenSnitch,
reguły OpenSnitch, strażnik → demon Nix, sekrety sops, kopia restic na NAS.

Ostatnie poprawki (NIE sprawdzone jeszcze testem – przerwane w trakcie):
- NAS montowany `file_mode=0600,dir_mode=0700` (wcześniej 0660/0770 + grupa users = dostęp dla
  claude, game_user i zeroroot), `/mnt/games` 0700.
- Reguła OpenSnitch `109-mount-cifs` (bez niej udział NAS się nie montował).

## Stan 2026-11-23
- [x] `checks.vm` – PRZECHODZI w całości (NAS 0600/0700, mount.cifs, ClamAV, hardening, strażnik, Lynis, awaryjny).
- [x] `checks.pulpit` – PRZECHODZI: Plasma Wayland, okno OpenSnitch połączone, strażnik w sesji, menu,
      ego jako game_user (Wayland + dźwięk + okno Konsoli), piaskownica zeroroot (wszystkie zabezpieczenia).
      Ograniczenie VM: gamescope nie ruszy na llvmpipe (brak VK_EXT_physical_device_drm) – sprawdzić na
      prawdziwym sprzęcie: `zeroroot-uruchom kitty`.
- [ ] `checks.dyski` – NIE URUCHOMIONY: wymaga pobrania paczek (QEMU z Canokey), a DNS 10.0.110.2 nie działał
      („No route to host”; router 10.0.10.1 rozwiązuje). Uruchomić, gdy DNS wróci:
      `nix build .#checks.x86_64-linux.dyski -L`

## Kolejność (pierwotna)
1. `nix build .#checks.x86_64-linux.vm -L` – dokończyć: NAS (uprawnienia), ClamAV (sygnatura testowa),
   hardening, strażnik, Lynis, tryb awaryjny.
2. `nix build .#checks.x86_64-linux.pulpit -L` – pierwszy przebieg: Plasma (Wayland) z autologowaniem,
   okno OpenSnitch, ego (konsole + dźwięk jako game_user), zeroroot-uruchom (ego → gamescope → bwrap).
   Możliwe problemy środowiska: KWin/gamescope na programowej grafice w maszynie wirtualnej.
3. `nix build .#checks.x86_64-linux.dyski -L` – pierwszy przebieg: disko (GPT, LUKS2, btrfs, ext4),
   klucz FIDO2 (Canokey) w LUKS i rozruch BEZ hasła, podwoluminy, wspólne wolne miejsce, snapper, scrub.
4. Usunąć ten plik, zaktualizować README (tabela „do przetestowania”: co już sprawdzone testami).

## Błędy znalezione dzięki testom (wszystkie poprawione w kodzie)
daj-claude odsłaniał pliki 644 w domu; reguły OpenSnitch: nix (dowiązanie), avahi (dowiązanie),
restic (opakowanie .restic-wrapped), brak mount.cifs; NAS i /mnt/games otwarte dla grupy users;
wygasanie dostępu do 1 min za późno.
