{
  description = "NixOS – komputery Jacka (JustJackPC, w przyszłości laptop)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    # Tylko dla pojedynczych pakietów, którym stabilna gałąź nie wystarcza (np. heroic w apps/games.nix:
    # poprawka logowania GOG przez Cloudflare). Resztę systemu trzyma stabilne nixpkgs powyżej.
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    # Deklaratywny układ dysków (używany tylko przy instalacji + jako źródło fileSystems).
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Secure Boot (podpisane UKI, własne klucze sbctl).
    lanzaboote = {
      url = "github:nix-community/lanzaboote/v1.2.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Sekrety zaszyfrowane w repo (age; klucz maszyny na dysku, klucze admina na YubiKeyach).
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { self, nixpkgs, ... }@inputs:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      # Każdy katalog w hosts/ = jeden komputer. Wspólne moduły: modules/.
      mkHost =
        name:
        nixpkgs.lib.nixosSystem {
          specialArgs = { inherit inputs; };
          modules = [ ./hosts/${name} ];
        };
    in
    {
      nixosConfigurations = {
        justjackpc = mkHost "justjackpc";
        # laptop = mkHost "laptop";
      };

      # nix flake check = pełna ewaluacja + budowa systemu.
      checks.${system} = {
        justjackpc = self.nixosConfigurations.justjackpc.config.system.build.toplevel;
        # Test w maszynie wirtualnej (moduły na żywym systemie): nix build .#checks.x86_64-linux.vm -L
        vm = import ./tests/vm.nix { inherit pkgs inputs; };
        # Pulpit (Plasma, OpenSnitch UI, ego, zeroroot-run): nix build .#checks.x86_64-linux.pulpit -L
        pulpit = import ./tests/pulpit.nix { inherit pkgs inputs; };
        # Dyski (disko + btrfs + snapper, instalacja i rozruch): nix build .#checks.x86_64-linux.dyski -L
        dyski = import ./tests/dyski.nix { inherit pkgs inputs; };
      };

      formatter.${system} = pkgs.nixfmt-tree;

      # Narzędzia do pracy z repo (direnv: .envrc → use flake).
      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          nil
          nixfmt
          sops
          age
          age-plugin-yubikey
          nvd
        ];
      };
    };
}
