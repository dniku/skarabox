{
  inputs,
  pkgs,
  skarabox,
  system,
}:
let
  testInputs = {
    self = testFlake;
    inherit skarabox;
    inherit (inputs)
      flake-parts
      nixos-anywhere
      nixos-generators
      nixpkgs
      ;
  };
  testFlake = (testInputs.flake-parts.lib.mkFlake { inputs = testInputs; } {
    systems = [ system ];

    imports = [
      skarabox.flakeModules.default
    ];

    skarabox.hosts.test = {
      nixpkgs = null;
      inherit system;
      hostKeyPub = ./fixtures/single-ssh-key.pub;
      sshPrivateKeyPath = null;
      sshPublicKeyPath = null;
      modules = [
        {
          skarabox = {
            hostname = "test";
            username = "skarabox";
            hashedPasswordFile = builtins.toFile "hashed-password" "!";
            facter-config = builtins.toFile "empty-facter.json" "";
            hostId = "00000000";
            machineId = "00000000000000000000000000000000";
            sshAuthorizedKeys = [ ./fixtures/single-ssh-key.pub ];
            disks = {
              rootPool = {
                disk1 = "/dev/nvme0n1";
                reservation = "500M";
                bootloader = "uefi";
              };
              dataPool = {
                enable = false;
                disk1 = "/dev/sda";
                disk2 = "/dev/sdb";
                reservation = "1G";
              };
            };
          };
        }
      ];
      extraBeaconModules = [
        ({ lib, modulesPath, ... }: {
          imports = [
            (modulesPath + "/testing/test-instrumentation.nix")
          ];
          users.users.root.hashedPasswordFile = lib.mkForce null;
        })
      ];
    };
  }) // {
    inputs = testInputs;
  };
  beaconVM = testFlake.packages.${system}.test-beacon-vm;
in
pkgs.testers.runNixOSTest {
  name = "beacon-vm";
  # Run the existing beacon-vm QEMU command under the host-side test driver.
  # Defining a node here and running beacon-vm inside it would require nested virtualization.
  nodes = { };

  testScript = ''
    # The VM mounts the builder's store, so keep its stage-2 system in the
    # test derivation closure even though it is intentionally absent from the ISO.
    beacon_system = "${beaconVM.beaconSystem}"

    beacon = create_machine(
        start_command="${pkgs.lib.getExe beaconVM}",
        name="beacon",
    )
    driver.machines_qemu.append(beacon)
    beacon.start()
    beacon.wait_for_unit("multi-user.target")
    beacon.succeed("test \"$(hostname)\" = test-beacon")
    beacon.succeed("systemctl is-active sshd.service")
    beacon.shutdown()
  '';
}
