{
  inputs,
  pkgs,
  skarabox,
  system,
}:
let
  testFlake =
    (import ./test-flake.nix {
      inherit inputs skarabox system;
      # Keep host forwards distinct from the other VM checks.
      sshPort = 8222;
      sshBootPort = 8223;
    }).flake;
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
        start_command="exec ${pkgs.lib.getExe beaconVM}",
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
