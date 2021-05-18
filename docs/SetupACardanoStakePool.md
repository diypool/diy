# Stake pool guide
This document is a step-by-step guide to set up your own Cardano stake pool. By the end of the
document, you should have a brand new stake pool that's ready to mint blocks. If you run into issues
or have suggestions, please raise an [issue](https://github.com/diypool/diy/issues) or create a
[pull request](https://github.com/diypool/diy) on the GitHub page.

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

Next edit `~/.ssh/config` and add the following lines so you can easily log in to block producer and
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
* *Reproducibility*

With NixOS we only have to edit a single file to make changes to our system making it *declarative*.
It is *reliable* because we can painlessly upgrade and roll back packages without breaking other
packages. We can also *reproduce* releases of
[input-output-hk/cardano-node](https://github.com/input-output-hk/cardano-node) guaranteeing the
same build across machines

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


Now become the root `sudo su` and partition and format your drive to install the operating system by
doing the following:

* Create *MBR* partition table
* Create the *root* partition that fills the disk except for the last 16 GB
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

For the relay, substitute `<RELAY_WG_PUBLIC_KEY>` value (in your local wireguard configuration file)
with contents of `/mnt/keys/wg/publickey`. For the block producer do the same except replace
`<BP_WG_PUBLIC_KEY>`.

Edit `/mnt/etc/nixos/configuration.nix` to look like the following. *Do not* enable cardano-node
just yet. Enabling it at this step will cause the installation to fail. Set it to true after the
install.
```nix
{ config, pkgs, lib, ... }:

let

  diySrc = builtins.fetchTarball {
    url = "https://github.com/diypool/diy/archive/refs/tags/v0.0.0.tar.gz";
    sha256 = "1sdvvrg216z5gxq2pl1pzd377fp2fgb4rw57l6rs3bzgzy276hgg";
  };

  diy = import "${diySrc}/nix/nixos/diy.nix" {
    config = config;
    pkgs = pkgs;
    lib = lib;

    cardano-node-src = {
      url = "https://github.com/input-output-hk/cardano-node/archive/refs/tags/1.27.0.tar.gz";
      hash = "1c9zc899wlgicrs49i33l0bwb554acsavzh1vcyhnxmpm0dmy8vj";
    };
    cardano-rt-view-src = {
      url = "https://github.com/input-output-hk/cardano-rt-view/archive/0.3.0.tar.gz";
      hash = "0m6na9gm0yvkg8z9w8f2i2isd05n2p0ha5y1j1gmciwr5srx4r60";
    };
  };

in

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
      diy
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
        addr = "<BP_IP>";
        port = <BP_CARDANO_NODE_PORT>;
        valency = 1;
      }
      # Pick 15-20 relays from this list https://explorer.mainnet.cardano.org/relays/topology.json
      # Make sure to pick a few that are geographically close to your relay
      # Then pick nodes from a variety of geographic locations
      {
        addr = "<IP_OR_DOMAIN>";
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

    kesKey = "/todo/kes.skey";
    vrfKey = "/todo/vrf.skey";
    operationalCertificate = "/todo/node.cert";
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
to the relay. You will be logged in as the `relay` user. Become the root user and set a password for
the `relay` user. Repeat these steps for the block producer node too

```sh
ssh relay
su              # Enter root password
passwd relay    # Enter a new password for the relay user
```

Login to the relay node and become root. Then enable cardano-node by editing configuration.nix.
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
nix-env -iA nixos.git # See Note
nixos-rebuild switch
```

Note that in cardano-node 1.27.0, IOG started using `fetchGit` in their nix configuration.
Apparently, this requires `git` binary to be installed to work properly. See this
[issue](https://github.com/NixOS/nixpkgs/issues/46603) on NixOS for more info.

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
nix-prefetch-url --unpack https://github.com/input-output-hk/cardano-node/archive/refs/tags/1.27.0.tar.gz
1c9zc899wlgicrs49i33l0bwb554acsavzh1vcyhnxmpm0dmy8vj
```

### Create Keys & Certs

This section is still being worked on. Please see Cardano doc [Creating keys and operational
certificates](https://docs.cardano.org/en/latest/getting-started/stake-pool-operators/creating-keys-and-operational-certificates.html)
for now

### Updating KES and Certs
Key Evolving Signature (KES), is a mechanism used by Cardano to prove that you still control the
cold keys. Each 90 day period you must generate a new KES key pair and a new node certificate using
your cold keys. Note that 90 days is the maximum period. You can generate new keys and a certificate
anytime within this period.

To generate new KES keys and a node certificate, first, figure out the KES period. This is done
using the genesis file and by querying the current slot of the tip of the blockchain. Replace
`<KES_PERIOD>` below with output of this command

```sh
 expr $(cardano-cli query tip --mainnet | nix-shell -p jq --run 'jq .slot') / $(nix-shell -p curl jq --run 'curl -s https://hydra.iohk.io/build/6198010/download/1/mainnet-shelley-genesis.json | jq .slotsPerKESPeriod')
```

Next, generate a new KES key pair

```sh
cardano-cli node key-gen-KES \
  --verification-key-file kes.vkey \
  --signing-key-file kes.skey
```

Next, use your cold signing key and cold operational certificate issue counter along with the
generated KES key to generate your new node certificate

```sh
cardano-cli node issue-op-cert \
  --kes-verification-key-file kes.vkey \
  --cold-signing-key-file cold.skey \
  --operational-certificate-issue-counter cold.counter \
  --kes-period <KES_PERIOD> \
  --out-file node.cert
```

Next, safely copy the KES keys and node certificate onto your block producer node and replace the old KES keys and node certificate. Finally, restart cardano-node

```sh
systemctl restart cardano-node.service
```

### Update Pool Parameters
To update pool fees, margin, metadata, relays, etc, you need to re-register the pool with an updated
pool registration certificate. You do not have to pay the original ₳500 deposit again. Although, you
will have to pay the transaction fee of ~₳0.2. Following are the steps to register the pool with a
new pool registration certificate

First, calculate the hash of `pool-metadata.json`. You must ensure the pool metadata JSON file is
unchanged after this since the hashes will differ. Replace `<POOL_METADATA_HASH>` below with the
output of this command 

```sh
cardano-cli stake-pool metadata-hash --pool-metadata-file pool-metadata.json
```

Next, generate the new pool registration certificate using your cold keys. Note that in this
example, the rewards account and owner stake key are the same. Also, a DNS name is used instead of
an IPV4 address for the relay. Replace relay domain and metadata URL with your value.
`<POOL_MARGIN>` is a decimal value between 0 and 1.0.

```sh
cardano-cli stake-pool registration-certificate \
  --cold-verification-key-file <PATH_TO_COLD_VKEY> \
  --vrf-verification-key-file <PATH_TO_VRF_VKEY> \
  --pool-pledge <PLEDGE_AMOUNT_LOVELACE> \
  --pool-cost <POOL_COST_LOVELACE> \
  --pool-margin <POOL_MARGIN> \
  --pool-reward-account-verification-key-file <PATH_TO_STAKE_VKEY> \
  --pool-owner-stake-verification-key-file <PATH_TO_STAKE_VKEY> \
  --mainnet \
  --single-host-pool-relay <RELAY_DOMAIN> \
  --pool-relay-port <RELAY_PORT> \
  --metadata-url <POOL_METADATA_URL> \
  --metadata-hash <POOL_METADATA_HASH> \
  --out-file pool-registration.cert
```

Next, build a transaction draft using the delegation certificate and your new pool registration
certificate

```sh
cardano-cli transaction build-raw \
  --tx-in <TxHash>#<TxIx> \
  --tx-out $(cat payment.addr)+0 \
  --invalid-hereafter 0 \
  --fee 0 \
  --out-file tx.draft \
  --certificate-file pool-registration.cert \
  --certificate-file delegation.cert
```

Next, calculate the fees. Replace `<TRANSACTION_FEE>` with the output of this command below

```sh
cardano-cli transaction calculate-min-fee \
  --tx-body-file tx.draft \
  --tx-in-count 1 \
  --tx-out-count 1 \
  --witness-count 3 \
  --byron-witness-count 0 \
  --mainnet \
  --protocol-params-file protocol.json
```

Next, calculate the change for `--tx-out` parameter. Replace `<CHANGE_IN_LOVELACE>` with the output
of this command below

```sh
expr <UTxO_BALANCE> - <TRANSACTION_FEE>
```

Next, build the transaction

```sh
cardano-cli transaction build-raw \
  --tx-in <TxHash>#<TxIx> \
  --tx-out $(cat payment.addr)+<CHANGE_IN_LOVELACE> \
  --invalid-hereafter <TTL> \
  --fee <TRANSACTION_FEE> \
  --out-file tx.raw \
  --certificate-file pool-registration.cert \
  --certificate-file delegation.cert
```

Next, sign the transaction

```sh
cardano-cli transaction sign \
  --tx-body-file tx.raw \
  --signing-key-file payment.skey \
  --signing-key-file stake.skey \
  --signing-key-file cold.skey \
  --mainnet \
  --out-file tx.signed
```

Finally, copy the signed transaction to your hot environment and submit it to the blockchain

```sh
cardano-cli transaction submit \
  --tx-file tx.signed \
  --mainnet
```

Verify whether pool registration was successful by running the following commands. First, find the pool id by running this from your cold environment. Replace `<POOL_ID>` with the output of
this command

```sh
cardano-cli stake-pool id 
  --cold-verification-key-file cold.vkey \
  --output-format "hex"
```

Check for pool params in the ledger. Your changes should be reflected in the `"futurePoolParams"`
section

```sh
cardano-cli query pool-params \
  --stake-pool-id <POOL_ID> \
  --mainnet
```