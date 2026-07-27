{
  dataPool,
  deploymentTests ? false,
  inputs,
  legacyNixpkgs ? false,
  name,
  pkgs,
  rootDisk2,
  skarabox,
  sshBootPort ? 2223,
  sshPort ? 2222,
  staticNetwork ? null,
  system,
}:
let
  testFixture = import ./test-flake.nix {
    inherit
      dataPool
      deploymentTests
      inputs
      legacyNixpkgs
      rootDisk2
      skarabox
      sshBootPort
      sshPort
      staticNetwork
      system
      ;
    mailserverSource = if deploymentTests then resolvedMailserverSource else null;
  };
  testFlake = testFixture.flake;
  targetConfig = testFlake.nixosConfigurations.test.config;
  targetSystem = targetConfig.system.build.toplevel;
  diskoScript = targetConfig.system.build.diskoScript;
  hostPackages = testFlake.packages.${system};
  beaconVM = hostPackages.test-beacon-vm;
  bootSsh = hostPackages.test-boot-ssh;
  getFacter = hostPackages.test-get-facter;
  ssh = hostPackages.test-ssh;
  sshBeacon = hostPackages.test-ssh-beacon;
  nixosAnywhere = inputs.nixos-anywhere.packages.${system}.nixos-anywhere;

  # This fixed private key is deliberately public test data. Building the
  # target before boot requires its host and authorized keys during evaluation.
  sshPrivateKey = ./fixtures/insecure-test-ssh-key;
  sshPublicKey = pkgs.lib.strings.trim (builtins.readFile ./fixtures/insecure-test-ssh-key.pub);
  rootPassphrase = pkgs.writeText "root-passphrase" "root-passphrase\n";
  dataPassphrase = pkgs.writeText "data-passphrase" "data-passphrase\n";
  # The mailserver module fetches its upstream source during evaluation.
  # Resolve it outside the sandboxed VM so the deployment flake can reuse it.
  resolvedMailserverSource = builtins.dirOf (
    builtins.head (
      (import inputs.selfhostblocks.nixosModules.mailserver {
        config = null;
        lib = null;
        pkgs = null;
        shb = null;
      }).imports
    )
  );
  knownHosts = pkgs.writeText "known-hosts" ''
    [10.0.2.2]:${toString sshPort} ${sshPublicKey}
    [10.0.2.2]:${toString sshBootPort} ${sshPublicKey}
  '';
  installCommand = pkgs.lib.escapeShellArgs (
    [
      "nixos-anywhere"
      "--phases"
      "disko,install,reboot"
      "--store-paths"
      diskoScript
      targetSystem
      "--disk-encryption-keys"
      "/tmp/host_key"
      "/etc/scenario/ssh"
      "--disk-encryption-keys"
      "/tmp/root_passphrase"
      "/etc/scenario/root-passphrase"
    ]
    ++ pkgs.lib.optionals dataPool [
      "--disk-encryption-keys"
      "/tmp/data_passphrase"
      "/etc/scenario/data-passphrase"
    ]
    ++ [
      "--no-substitute-on-destination"
      "--ssh-option"
      "ConnectTimeout=10"
      "--ssh-option"
      "StrictHostKeyChecking=no"
      "--ssh-option"
      "UserKnownHostsFile=/dev/null"
      "-i"
      "/etc/scenario/ssh"
      "-p"
      (toString sshPort)
      "root@10.0.2.2"
    ]
  );
  skaraboxFlakeUrl = "path:${skarabox.outPath}?narHash=${skarabox.narHash}";
  # The deployment CLIs require a flake on disk. Reopen this locked store
  # source so the fixture can reuse its inputs without network access.
  deploymentFlakeNix = pkgs.writeText "deployment-flake.nix" ''
    {
      outputs = _:
        let
          skarabox = builtins.getFlake "${skaraboxFlakeUrl}";
        in
        builtins.removeAttrs
          (import ./test-flake.nix {
            dataPool = false;
            deploymentTests = true;
            inputs = skarabox.inputs;
            legacyNixpkgs = false;
            mailserverSource = ./mailserver;
            rootDisk2 = false;
            inherit skarabox;
            sshBootPort = ${toString sshBootPort};
            sshPort = ${toString sshPort};
            system = "${system}";
          }).flake
          [ "inputs" ];
    }
  '';
  deploymentFlake = pkgs.runCommand "deployment-flake" { } ''
    mkdir "$out"
    cp ${deploymentFlakeNix} "$out/flake.nix"
    cp ${./test-flake.nix} "$out/test-flake.nix"
    cp -r ${./fixtures} "$out/fixtures"
    cp -r ${resolvedMailserverSource} "$out/mailserver"
  '';

  # Flake evaluation needs every transitive input source in the offline VM.
  flakeInputSources =
    input:
    [ input.outPath ]
    ++ pkgs.lib.concatMap flakeInputSources (builtins.attrValues (input.inputs or { }));
  # Preload the CLIs, evaluation-only dependencies, and deployed systems.
  deploymentDependencies = [
    inputs.colmena.packages.${system}.colmena
    inputs.deploy-rs.packages.${system}.deploy-rs
    inputs.selfhostblocks.lib.${system}.patchedNixpkgs
    testFlake.colmenaHive.toplevel.test
    testFlake.deploy.nodes.test.profiles.system.path
  ]
  ++ builtins.attrValues testFlake.checks.${system};
in
pkgs.testers.runNixOSTest {
  inherit name;

  nodes.installer = {
    nix.settings.experimental-features = pkgs.lib.optionals deploymentTests [
      "nix-command"
      "flakes"
    ];
    environment.systemPackages = [
      nixosAnywhere
      pkgs.jq
      pkgs.openssh
    ];
    # Make the prebuilt install artifacts available in the installer VM's store.
    system.extraDependencies = [
      diskoScript
      targetSystem
    ]
    ++ pkgs.lib.optionals deploymentTests (
      [ deploymentFlake ] ++ deploymentDependencies ++ pkgs.lib.unique (flakeInputSources skarabox)
    );
    environment.etc = {
      "scenario/data-passphrase".source = dataPassphrase;
      "scenario/known-hosts".source = knownHosts;
      "scenario/root-passphrase".source = rootPassphrase;
      "scenario/ssh" = {
        source = sshPrivateKey;
        mode = "0600";
      };
    };
    virtualisation = {
      cores = 2;
      diskSize = 20 * 1024;
      memorySize = 4096;
    };
  };

  testScript = ''
    import shlex

    # The beacon VM mounts the builder's store, so retain the stage-2 system
    # even though it is intentionally absent from the generated ISO.
    beacon_system = "${beaconVM.beaconSystem}"

    # Running the beacon inside the installer VM would require nested virtualization.
    beacon = create_machine(
        start_command="exec ${pkgs.lib.getExe beaconVM}",
        name="beacon",
    )
    driver.machines_qemu.append(beacon)
    beacon.start(allow_reboot=True)
    installer.start()

    with subtest("beacon is reachable"):
        installer.wait_until_succeeds(
            "${pkgs.lib.getExe sshBeacon} echo connected",
            timeout=300,
        )

    with subtest("collect hardware configuration"):
        installer.succeed(
            "${pkgs.lib.getExe getFacter} > /tmp/facter.json",
            timeout=300,
        )
        installer.succeed("jq -e 'type == \"object\"' /tmp/facter.json")

    with subtest("install prebuilt system"):
        # Keep installation independent from the synchronous backdoor command
        # while nixos-anywhere replaces and reboots the target.
        installer.succeed(
            "systemd-run --unit=skarabox-install "
            "--setenv=HOME=/root "
            "--property=StandardOutput=append:/tmp/skarabox-install.log "
            "--property=StandardError=append:/tmp/skarabox-install.log "
            "${installCommand}",
        )
        installer.wait_until_succeeds(
            "test \"$(systemctl show -p ActiveState --value "
            "skarabox-install)\" = inactive",
            timeout=1200,
        )
        installer.succeed(
            "test \"$(systemctl show -p Result --value "
            "skarabox-install)\" = success "
            "|| { cat /tmp/skarabox-install.log; false; }"
        )

    unlock_command = (
        "cat /etc/scenario/root-passphrase | "
        + "${pkgs.lib.getExe bootSsh} -T"
    )
    def target_command(*, command: str) -> str:
        return "${pkgs.lib.getExe ssh} " + shlex.quote(command)

    def target_password_hash() -> str:
        return installer.succeed(
            target_command(
                command="sudo getent shadow skarabox | cut -d: -f2"
            )
        ).strip()

    with subtest("unlock and boot installed system"):
        installer.wait_until_succeeds(unlock_command, timeout=300)
        installer.wait_until_succeeds(
            target_command(command="test \"$(hostname)\" = test"),
            timeout=300,
        )

    with subtest("storage topology is correct"):
        installer.succeed(
            target_command(
                command="sudo zpool status -LP root | grep -F /dev/nvme0n1p2"
            )
        )
        ${
          if rootDisk2 then
            ''
              installer.succeed(
                  target_command(
                      command="sudo zpool status -LP root | grep -F /dev/nvme1n1p2"
                  )
              )
            ''
          else
            ''
              installer.fail(
                  target_command(
                      command="sudo zpool status -LP root | grep -F /dev/nvme1n1p2"
                  )
              )
            ''
        }
        ${
          if dataPool then
            ''
              installer.succeed(
                  target_command(
                      command="sudo zpool status -LP zdata | grep -F /dev/sda1"
                  )
              )
              installer.succeed(
                  target_command(
                      command="sudo zpool status -LP zdata | grep -F /dev/sdb1"
                  )
              )
            ''
          else
            ''
              installer.fail(target_command(command="sudo zpool status zdata"))
            ''
        }

    with subtest("password and persistent user maps are populated"):
        password_hash = target_password_hash()
        assert password_hash == "${testFixture.testPasswordHash}"
        uid_map = installer.succeed(
            target_command(command="sudo cat /var/lib/nixos/uid-map")
        ).strip()
        gid_map = installer.succeed(
            target_command(command="sudo cat /var/lib/nixos/gid-map")
        ).strip()
        assert uid_map, "No uid map found"
        assert gid_map, "No gid map found"

    with subtest("state survives a reboot"):
        installer.succeed(
            target_command(
                command="(sleep 1 && sudo reboot) >/dev/null 2>&1 &"
            )
        )
        installer.wait_until_succeeds(unlock_command, timeout=300)
        installer.wait_until_succeeds(
            target_command(command="true"),
            timeout=300,
        )
        assert installer.succeed(
            target_command(command="sudo cat /var/lib/nixos/uid-map")
        ).strip() == uid_map
        assert installer.succeed(
            target_command(command="sudo cat /var/lib/nixos/gid-map")
        ).strip() == gid_map
        assert target_password_hash() == password_hash

    ${pkgs.lib.optionalString deploymentTests ''
      with subtest("deploy with deploy-rs"):
          installer.succeed(
              "mkdir -p /tmp/codex && "
              "cp -r ${deploymentFlake} /tmp/codex/deployment && "
              "chmod -R u+w /tmp/codex/deployment && "
              "cd /tmp/codex/deployment && nix flake lock path:.",
              timeout=300,
          )
          installer.succeed(
              "cd /tmp/codex/deployment && "
              "nix run path:.#deploy-rs -- "
              "--skip-checks --debug-logs --temp-path /tmp/deploy-rs",
              timeout=600,
          )
          installer.succeed(target_command(command="true"))

      with subtest("deploy with Colmena"):
          installer.succeed(
              "cd /tmp/codex/deployment && "
              "nix run path:.#colmena -- apply --show-trace",
              timeout=600,
          )
          installer.succeed(target_command(command="true"))

      with subtest("password survives deployment"):
          assert target_password_hash() == password_hash
    ''}

    beacon.crash()
  '';
}
