# KDE Plasma 6 (Wayland), dźwięk, drukarka, czcionki, Firefox.
{ pkgs, ... }:
{
  services.desktopManager.plasma6.enable = true;
  services.displayManager.sddm = {
    enable = true;
    wayland.enable = true;
  };

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

  # Główna przeglądarka.
  programs.firefox = {
    enable = true;
    policies = {
      DisableTelemetry = true;
      DisableFirefoxStudies = true;
      DisablePocket = true;
    };
  };

  # Klucze GPG (2 prywatne z Fedory) i YubiKey.
  programs.gnupg.agent = {
    enable = true;
    pinentryPackage = pkgs.pinentry-qt;
  };
  services.pcscd.enable = true; # Yubico Authenticator (OATH/PIV) bez tego nie widzi klucza
  services.udev.packages = [ pkgs.yubikey-personalization ];
}
