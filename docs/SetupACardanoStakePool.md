# Stake pool guide
This document is a step-by-step guide to set up your own Cardano stake pool. By the end of the
document, you should have a brand new stake pool that's ready to forge blocks. If you run into
issues or have suggestions, please raise an [issue]() or create a [pull request]() on the GitHub
page.

* Hardware & Network
* Setup WireGuard & SSH
* Install NixOS
* Managing System
* Create Keys & Certs

### Hardware & Network
Current hardware and network requirements for operating a stake pool are the following: 

* 8 GB RAM
* 24 GB disk space
* 1 CPU
* Public IPV4 address
* 1 GB network bandwidth/hour

Keep in mind that these are minimum requirements. You should plan for additional capacity to meet
future requirements of the network. I recommend at least 100 GB disk space, 4 CPUs, and 8 GB RAM. 

For security, you must operate 1 or more relay nodes and a *single* block producing (BP) node. The
BP node will only communicate with your relay node. The relay will communicate with other relays in
the Cardano network. Hence, you will need at least *2 separate instances* of the hardware described
above.



![Stake Pool Network](/docs/assets/network.svg)


### Setup WireGuard & SSH
For security, we will use [WireGuard](https://www.wireguard.com/) VPN to manage our block producing
and relay nodes. We will set up an encrypted network between the local machine, block producer, and
relay node. 

You will SSH and access [cardano-rt-view](https://github.com/input-output-hk/cardano-rt-view) from
this private network. The relay node will allow access to the cardano-node process from the public
network. Block producer node will *only* allow connections to its cardano-node process from the
relay on the public network.

WireGuard is simple, fast, and modern. Download and install a [WireGuard
client](https://www.wireguard.com/install/) for your OS and create a key pair using the client.

You must substitute `<LOCAL_MACHINE_WG_PUBLIC_KEY>` value in the following section with the contents
of your locally-generated public key. Substitute `PublicKey` value of the peers from the NixOS
install section.


Using your wireguard client, create a network configuration file like the following

```conf
[Interface]
PrivateKey = <LOCAL_MACHINE_WG_PRIVATE_KEY>
Address = 10.100.0.1/32

[Peer]
PublicKey = <RELAY_WG_PUBLIC_KEY>
AllowedIPs = 10.100.0.3/32
Endpoint = <RELAY_IP>:<RELAY_WG_PORT>
PersistentKeepalive = 21

[Peer]
PublicKey = <BP_WG_PUBLIC_KEY>
AllowedIPs = 10.100.0.2/32
Endpoint = <BP_IP>:<BP_WG_PORT>
PersistentKeepalive = 21
```

Next ddit `~/.ssh/config` and add the following lines so you can easily log in to block producer and
relay nodes from your local machine

```config
Host relay
    User relay
    Hostname 10.100.0.3
    Port <RELAY_SSH_PORT>
    IdentityFile <PATH_TO_PRIVATE_SSH_KEY> # Usually ~/.ssh/id_rsa

Host producer
    User producer
    Hostname 10.100.0.2
    Port <BP_SSH_PORT>
    IdentityFile <PATH_TO_PRIVATE_SSH_KEY> # Usually ~/.ssh/id_rsa
```

### Install NixOS
In this section, you will install [NixOS](https://nixos.org) on your hardware. NixOS is a Linux
distribution built on top of the Nix package manager. NixOS has the following key properties that
are perfect for operating a stake pool

* *Declarative*
* *Reliability*
* *Reprodicibility*

With NixOS we only have to edit a single file to make changes to our system making it *declarative*.
It is *reliable* because we can painlessly upgrade and roll back packages without breaking other
packages. We can also *reproduce* releases of
[input-output-hk/cardano-node](https://github.com/input-output-hk/cardano-node) guaranteeing same
build across machines.

First, install NixOS on your relay hardware. Please read NixOS
[documentation](https://nixos.org/manual/nixos/stable/#sec-installation) for more detailed steps.
For a cloud instance, your steps might look like the following.

Download [nixos-20.09](https://channels.nixos.org/nixos-20.09/latest-nixos-minimal-x86_64-linux.iso)
minimal install ISO and attach to your cloud instance. Log in to the instance using directions given
by your hosting provider. 

You will be logged in as `nixos` user. Next, set up `ssh` keys on the install image so we can
complete the installation from a terminal.
```sh
mkdir ~/.ssh/
echo '<PUBLIC_SSH_KEY>' > ~/.ssh/authorized_keys
```

Login to your relay instance from your local machine
```sh
ssh nixos@<RELAY_IP>
```


Now become root `sudo su` and partition and format your drive to install the operating system by
doing the following:

* Create *MBR* partition table
* Create *root* partition that fills the disk except for the last 16 GB
* Create the *swap* partition using the last 16 GB
* Format the partitions
```sh
parted /dev/vda -- mklabel msdos
parted /dev/vda -- mkpart primary 1MiB -16GiB
parted /dev/vda -- mkpart primary linux-swap -16GiB 100%

mkfs.ext4 -L nixos /dev/vda1
mkswap -L swap /dev/vda2
```

Next, mount the partition and generate nixos configuration file
```sh
mount /dev/disk/by-label/nixos /mnt
swapon /dev/vda2
nixos-generate-config --root /mnt
```

Next, setup WireGuard keys by running the following
```sh 
umask 077
mkdir -p /mnt/keys/wg
cd /mnt/keys/wg
nix-shell -p wireguard --run 'wg genkey | tee privatekey | wg pubkey > publickey'
```

For the relay, substitute `<RELAY_WG_PUBLIC_KEY>` value with contents of `/mnt/keys/wg/publickey`.
For the block producer do the same except replace `<BP_WG_PUBLIC_KEY>`.

Edit `/mnt/etc/nixos/configuration.nix` to look like the following. *Do not* enable cardano-node
just yet. Enabling it at this step will cause the installation to fail. Set it to true after the
install.
```nix
{ config, pkgs, lib, ... }:

{
  nix.binaryCaches = [
    "https://hydra.iohk.io"
  ];

  nix.binaryCachePublicKeys = [
    "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ="
  ];

  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
      (import ./diy.nix {
        config = config;
        pkgs = pkgs;
        lib = lib;

        cardano-node-src = {
          url = "https://github.com/input-output-hk/cardano-node/archive/refs/tags/1.26.2.tar.gz";
          hash = "17zr2lhnrly6gqb1hxf3cjwfw1iz8s85hhhdiivb5ax7fkrrp8pp";
        };
        cardano-rt-view-src = {
          url = "https://github.com/input-output-hk/cardano-rt-view/archive/0.3.0.tar.gz";
          hash = "0m6na9gm0yvkg8z9w8f2i2isd05n2p0ha5y1j1gmciwr5srx4r60";
        };
      })
    ];

  boot.loader.grub.device = "/dev/vda";

  services.stake-pool = {
    name = "<POOL_NAME>";

    ssh = {
      port = <RELAY_SSH_PORT>;
      public-key = ''<PUBLIC_SSH_KEY>'';
    };

    cardano-node = {
      enable = false;
      port = <RELAY_CARDANO_NODE_PORT>;
      tracePort = 8000;
    };

    cardano-rt-view = {
      port = 8088;
    };

    topology = [
      {
        addr = "<BP_IP>"
        port = <BP_CARDANO_NODE_PORT>;
        valency = 1;
      }
      # Pick 15-20 relays from this list https://explorer.mainnet.cardano.org/relays/topology.json
      # Make sure to pick a few that are geographically close to your relay
      # Then pick nodes from a variety of geographic locations
      {
        addr = "<IP_OR_DOMAIN>"
        port = <PORT>;
        valency = 1;
      }
    ];

    wireguard = {
      port = <RELAY_WG_PORT>;
      peerPublicKey = ''<LOCAL_MACHINE_WG_PUBLIC_KEY>'';
    };
  };
}
```

Finally, install nixos and reboot. Set the root password when the last step in install prompts you
to. Also, don't forget to detach the ISO from the instance
```sh 
nixos-install
reboot
```

For the block producer node, follow the same steps as above except edit `service.stake-pool` section
in `/mnt/etc/nixos/configuration.nix` to look like this instead
```nix
services.stake-pool = {
  name = "<POOL_NAME>";

  ssh = {
    port = <BP_SSH_PORT>;
    public-key = ''<PUBLIC_SSH_KEY>'';
  };

  cardano-node = {
    enable = false;
    port = <BP_CARDANO_NODE_PORT>;
    tracePort = 8000;

    kesKey = "/todo/kes.skey"
    vrfKey = "/todo/vrf.skey"
    operationalCertificate = "/todo/node.cert"
  };

  cardano-rt-view = {
    port = 8088;
  };

  topology = [
    {
      # This must be an IPV4 address since its used in an iptables rule
      addr = "<RELAY_PUBLIC_IP>"; 
      port = <RELAY_CARDANO_NODE_PORT>;
      valency = 1;
    }
  ];

  wireguard = {
    port = <BP_WG_PORT>;
    peerPublicKey = ''<LOCAL_MACHINE_WG_PUBLIC_KEY>'';
  };
};
```

Note that you *must* set `kesKey`, `vrfKey`, and `operationalCertificate` so that block producer
configuration is applied. Set the values to a non-existent path during the install. We will set
these to real paths later. Just like before, set `cardano-node.enable = false` for now

### Managing System
You should now have NixOS installed on the hardware. Now connect to the wireguard network and login
to the relay. You will be logged in as the `relay` user. Become root user and set a password for the
`relay` user. Repeat these steps for the block producer node too

```sh
ssh relay
su              # Enter root password
passwd relay    # Enter a new password for the relay user
```

Login to the relay node and become root. Then enable cardano node by editing configuration.nix.
Temporarily remove your block producer address from the topology section since the block producer
cardano-node is not running yet. After editing the file, while being root, rebuild nixos. This will
download and install
[input-output-hk/cardano-node](https://github.com/input-output-hk/cardano-node). This may take up to
30 minutes. 
```sh
ssh relay
su
vim /etc/nixos/configuration.nix

# Enable cardano-node
services.stake-pool {
  cardano-node {
    enable = true;
  };
};

nixos-rebuild switch
```

Now you should have cardano-node process running on the relay node. You can manage cardano-node
process using system control commands:

* View status `systemctl status cardano-node.service`
* Follow logs `journalctl -u cardano-node.service -f`
* Stop process `systemctl stop cardano-node-.service`
* Restart process `systemctl restart cardano-node.service`

To view the application-specific state of cardano-node, navigate to
[http://10.100.0.3:8088](http://10.100.0.3:8088). This will show cardano-rt-view's UI for the relay
node. If you do not see anything, restart cardano-rt-view service by running `systemctl restart
cardano-rt-view.service`

For the block producer, first generate `kes.skey`, `vrf.skey`, and `node.cert` from the following
section and specify the path to them in the configuration file. After the block producer node is
enabled, add block producer to the topology section in the relay node.

Note that anytime you make changes to `/etc/nixos/configuration.nix`, you must run `nixos-rebuild
switch` for it to take effect. Also, if you need to upgrade cardano-node or cardano-rt-view version,
just change the values of `src` and `hash` values in the imports section. You can compute the nix
hash by running the following command

```sh
nix-prefetch-url --unpack https://github.com/input-output-hk/cardano-node/archive/refs/tags/1.26.2.tar.gz
17zr2lhnrly6gqb1hxf3cjwfw1iz8s85hhhdiivb5ax7fkrrp8pp
```

### Create Keys & Certs

This section is still being worked on. Please see Cardano doc [Creating keys and operational
certificates](https://docs.cardano.org/en/latest/getting-started/stake-pool-operators/creating-keys-and-operational-certificates.html)
for now