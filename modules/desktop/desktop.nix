# KDE Plasma 6 (Wayland), dźwięk, drukarka, czcionki, Firefox (pakiet/polityki globalne - samo
# Jacka nie używa go wprost, patrz niżej).
{ lib, pkgs, ... }:
let
  # Firefox NIE jest dla Jacka - tylko przez konta szablonu "browse"/"bank" (browse_user,
  # secure_user). Pakiet i polityki (DisableTelemetry itd.) muszą zostać globalne (potrzebują ich
  # oba te konta), ale zwykły skrót (odpaliłby jako Jacek) jest chowany tym samym wzorcem co
  # Chromium/Steam/Heroic/VSCode gdzie indziej w repo - blokada sieci dla Jacka jest w
  # security/opensnitch.nix (reguła 020-firefox-blokada-jacka).
  hideFirefox = lib.hiPrio (
    pkgs.runCommand "hide-firefox" { } ''
      mkdir -p $out/share/applications
      printf '[Desktop Entry]\nType=Application\nName=Firefox\nNoDisplay=true\nHidden=true\n' \
        > $out/share/applications/firefox.desktop
    ''
  );
in
{
  services.desktopManager.plasma6.enable = true;
  services.displayManager.sddm = {
    enable = true;
    wayland.enable = true;
  };
  # services.displayManager.hiddenUsers: generowane w modules/users/konta.nix z centralnego
  # rejestru kont (każda piaskownica = zablokowane hasło + ukryta, automatycznie).

  # Dźwięk: PipeWire (z warstwą PulseAudio – ego daje do niej dostęp innym użytkownikom).
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  # Bluetooth wyłączony (nieużywany; moduły zablokowane w hardening.nix).
  hardware.bluetooth.enable = false;

  # Drukarka Brother DCP-T500W przez Wi-Fi (na Fedorze: socket://192.168.50.157:9100).
  # Brak paczki Brothera dla tego modelu w nixpkgs → gutenprint / sterowniki bez PPD.
  # Dodanie drukarki: Ustawienia systemowe → Drukarki (raz, po instalacji).
  services.printing = {
    enable = true;
    drivers = [ pkgs.gutenprint ];
  };

  fonts.packages = with pkgs; [
    noto-fonts
    noto-fonts-color-emoji
    liberation_ttf
    jetbrains-mono
  ];

  # Pakiet + polityki globalne - dla browse_user/secure_user, NIE dla Jacka (patrz let wyżej).
  programs.firefox = {
    enable = true;
    policies = {
      DisableTelemetry = true;
      DisableFirefoxStudies = true;
      DisablePocket = true;
    };
  };
  environment.systemPackages = [ hideFirefox ];

  # Klucze GPG (2 prywatne z Fedory) i YubiKey.
  programs.gnupg.agent = {
    enable = true;
    pinentryPackage = pkgs.pinentry-qt;
  };
  services.pcscd.enable = true; # Yubico Authenticator (OATH/PIV) bez tego nie widzi klucza
  services.udev.packages = [ pkgs.yubikey-personalization ];
}
