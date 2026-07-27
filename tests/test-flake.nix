{
  dataPool ? false,
  deploymentTests ? false,
  inputs,
  legacyNixpkgs ? false,
  mailserverSource ? null,
  rootDisk2 ? false,
  skarabox,
  sshBootPort ? 2223,
  sshPort ? 2222,
  staticNetwork ? null,
  system,
}:
let
  testPasswordHash = "$6$skarabox$4ahWDg7R18sy6OpbSMoa6wUvfiFMYeiKkdDjkCbAMDZ3ZIRKF7ghQPX2oHUN.BgJPWsyFB2pQSRUqckf7a2aR1";
  testInputs = {
    self = testFlake;
    inherit skarabox;
    inherit (inputs)
      colmena
      deploy-rs
      flake-parts
      nixos-anywhere
      nixos-generators
      nixpkgs
      selfhostblocks
      ;
  };
  selfhostblocksModule =
    if mailserverSource == null then
      inputs.selfhostblocks.nixosModules.default
    else
      {
        imports = map (
          module:
          if module == inputs.selfhostblocks.nixosModules.mailserver then
            builtins.scopedImport {
              builtins = builtins // {
                fetchGit = _: mailserverSource;
              };
            } module
          else
            module
        ) inputs.selfhostblocks.nixosModules.default.imports;
      };
  testFlake =
    (testInputs.flake-parts.lib.mkFlake { inputs = testInputs; } {
      systems = [ system ];

      imports = [
        skarabox.flakeModules.default
      ]
      ++ inputs.nixpkgs.lib.optionals deploymentTests [
        skarabox.flakeModules.colmena
        skarabox.flakeModules.deploy-rs
        {
          # Updating GRUB in the QEMU target takes longer than deploy-rs's
          # 30-second default confirmation timeout.
          flake.deploy.nodes.test.confirmTimeout = 600;
        }
      ];

      skarabox.hosts.test = {
        nixpkgs = if legacyNixpkgs then null else inputs.selfhostblocks.lib.${system}.patchedNixpkgs;
        inherit sshBootPort sshPort system;
        hostKeyPath = "/etc/scenario/ssh";
        hostKeyPub = ./fixtures/insecure-test-ssh-key.pub;
        ip = "10.0.2.2";
        knownHostsPath = "/etc/scenario/known-hosts";
        sshPrivateKeyPath = "/etc/scenario/ssh";
        sshPublicKeyPath = null;
        modules =
          inputs.nixpkgs.lib.optionals (!legacyNixpkgs) [
            selfhostblocksModule
          ]
          ++ [
            (
              { lib, modulesPath, ... }:
              {
                imports = [
                  (modulesPath + "/profiles/qemu-guest.nix")
                ];

                # Preserve the DHCP lease while QEMU resets its virtual link during
                # the transition from initrd networkd to stage-2 networkd.
                systemd.network.networks."10-lan".networkConfig = lib.optionalAttrs (staticNetwork == null) {
                  KeepConfiguration = "dynamic";
                };
                boot.initrd.systemd.network.networks."10-lan".networkConfig =
                  lib.optionalAttrs (staticNetwork == null)
                    {
                      KeepConfiguration = "dynamic";
                    };
                boot.initrd.availableKernelModules = [
                  "ata_piix"
                  "e1000"
                  "nvme"
                  "sd_mod"
                ];
                skarabox = {
                  hostname = "test";
                  username = "skarabox";
                  hashedPasswordFile = builtins.toFile "hashed-password" testPasswordHash;
                  facter-config = builtins.toFile "empty-facter.json" "";
                  hostId = "00000000";
                  machineId = "0123456789abcdef0123456789abcdef";
                  sshAuthorizedKeys = [ ./fixtures/insecure-test-ssh-key.pub ];
                  inherit staticNetwork;
                  disks = {
                    rootPool = {
                      disk1 = "/dev/nvme0n1";
                      disk2 = if rootDisk2 then "/dev/nvme1n1" else null;
                      reservation = "500M";
                      bootloader = "uefi";
                    };
                    dataPool = {
                      enable = dataPool;
                      disk1 = "/dev/sda";
                      disk2 = "/dev/sdb";
                      reservation = "1G";
                    };
                  };
                };
              }
            )
          ];
        extraBeaconModules = [
          (
            { lib, modulesPath, ... }:
            {
              imports = [
                (modulesPath + "/testing/test-instrumentation.nix")
              ];
              users.users.root.hashedPasswordFile = lib.mkForce null;
            }
          )
        ];
      };
    })
    // {
      inputs = testInputs;
    };
in
{
  flake = testFlake;
  inherit testPasswordHash;
}
