# RTX 2070 (Turing) – otwarte moduły jądra NVIDIA (zalecane od Turinga).
# Plan awaryjny: open = false (zamknięte moduły).
{ config, pkgs, ... }:
{
  services.xserver.videoDrivers = [ "nvidia" ];

  hardware.graphics = {
    enable = true;
    enable32Bit = true; # Steam / Proton / Wine
    # Sprzętowe dekodowanie wideo przez VA-API (mpv, VLC). Firefox wymaga jeszcze ustawień
    # w about:config (media.ffmpeg.vaapi.enabled itd.) – do włączenia po instalacji, jeśli potrzebne.
    extraPackages = [ pkgs.nvidia-vaapi-driver ];
  };

  hardware.nvidia = {
    open = true;
    modesetting.enable = true;
    # Zachowuje pamięć karty przy uśpieniu (bez tego bywa czarny ekran po wybudzeniu).
    powerManagement.enable = true;
    nvidiaSettings = true;
    package = config.boot.kernelPackages.nvidiaPackages.stable;
  };

  environment.sessionVariables = {
    LIBVA_DRIVER_NAME = "nvidia";
    NVD_BACKEND = "direct";
  };
}
