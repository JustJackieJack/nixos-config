# Sprzęt. Po instalacji porównać z: nixos-generate-config --no-filesystems --show-hardware-config
# (systemy plików są w disko.nix, więc tutaj ich nie ma).
{ modulesPath, ... }:
{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  nixpkgs.hostPlatform = "x86_64-linux";

  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "ahci"
    "nvme"
    "usbhid"
    "usb_storage"
    "sd_mod"
  ];
  # Bez "kvm-intel": nie uruchamiamy maszyn wirtualnych.

  hardware.cpu.intel.updateMicrocode = true;
  hardware.enableRedistributableFirmware = true;

  # Intel I219-V (eno1) – sterownik e1000e ładuje się sam.
}
