{
  inputs,
  pkgs,
  self,
  system,
  nix-flake-tests,
}:
{
  lib = nix-flake-tests.lib.check {
    inherit pkgs;
    tests = pkgs.callPackage ./lib.nix { };
  };
}
// pkgs.lib.optionalAttrs (system == "x86_64-linux") {
  beacon = import ./beacon-vm.nix {
    inherit inputs pkgs system;
    skarabox = self;
  };
  template = import ./template.nix {
    inherit pkgs;
    inherit (self.packages.${system})
      gen-new-host
      sops-add-main-key
      sops-create-main-key
      ;
  };
}
// pkgs.lib.optionalAttrs (system == "x86_64-linux") (
  import ./variants.nix {
    inherit inputs pkgs system;
    skarabox = self;
  }
)
// pkgs.lib.optionalAttrs (system == "x86_64-linux") (
  import ./static.nix {
    inherit inputs pkgs system;
    skarabox = self;
  }
)
