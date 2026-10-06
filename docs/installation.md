# pfVEdge — Installation and Upgrade

This document describes the complete installation and upgrade procedure for pfVEdge on a Fedora host using Podman, NetworkManager, and systemd.

For a general overview of the project, see the [README](../README.md).

---

## 1. Prerequisites

pfVEdge is designed to run on a Linux host using:

* Fedora;
* Podman;
* systemd;
* NetworkManager;
* firewalld;
* QEMU;
* `jq`.

The required dependencies are checked by pfVEdge during deployment.

The user running the installation must have `sudo` privileges.

---

## 2. Install pfVEdge from Git

pfVEdge should be installed directly from its Git repository.

Create the installation directory:

```bash
sudo mkdir -p /opt/pfVEdge
sudo chown "$USER":"$USER" /opt/pfVEdge
```

Clone the repository:

```bash
git clone https://github.com/gawindx/pfVEdge.git /opt/pfVEdge
```

Enter the project directory:

```bash
cd /opt/pfVEdge
```

Using Git makes it possible to update an existing installation without reinstalling pfVEdge.

---

## 3. Prepare the configuration

The pfVEdge configuration is stored in:

```text
config/config.json
```

A commented example configuration is provided with the project.

Copy the example configuration to the active configuration file and adapt the values to your environment.

> The example file may contain comments to explain the available parameters.
>
> The configuration file used by pfVEdge must be valid JSON and must not contain comments.

See [Configuration](configuration.md) for a detailed description of the available parameters.

---

## 4. Deploy pfVEdge

From the project root directory:

```bash
sudo ./deploy.sh
```

The deployment script checks the required dependencies and installs the systemd and network components required by pfVEdge.

Review any errors or warnings reported by the script before continuing.

---

## 5. Initial VM installation

During the initial installation, the VM disk has not yet been initialized.

pfVEdge automatically detects this state and temporarily allows TCP port `8006` on all interfaces so that the VM can be installed through the noVNC interface.

Port `8006` is not intended to remain open during normal operation (and certainly not on all interfaces).

Once the disk has been detected as initialized, pfVEdge creates its installation marker and the temporary port-opening mechanism is stopped.

When VM is fully installed, it generaly reboot and once she is started you can configure tap inside VM accordingly with your config file (see pfSense or OpnSense documentation).

For full VM reinstall, you can delete file /opt/pfVEdge/storage/install-done and existing vm. At next container boot
the port will be reopen on all interfaces.

---

## 6. Access the VM 

### Acces the VM console

During the initial installation, access:

```text
http://<host-address>:8006
```

The pfSense or other supported firewall installation can then be performed through the QEMU console.

Once the installation is complete, port `8006` will be closed at next container boot.

The container expose this port at all time, if you want to access to the vm console during normal operation
you must open the port on the desired interface through host's firewall and create firewall rule on the VM if necessary.

### Access the VM WebGUI

Once VM is installed and configured (ip interfaces can set through the VM Console) you can access to the WebGui for configuring firewall (see pfSense or OpnSense documentation).

```text
https://<pfVEdge-tap-lan-address>:443
```

By default, when lan bridge is dhcp, WebGUI for pfSense and OpnSense will be accessible on :

```text
https://192.168.1.1:443
```

---

## 7. Verify the installation

Check the main systemd units:

```bash
systemctl status pfVEdge.target
systemctl status pfVEdge-bridges.service
systemctl status pfVEdge.service
```

Check the logs:

```bash
journalctl -u pfVEdge-bridges.service
journalctl -u pfVEdge.service
```

The network configuration can also be checked with:

```bash
ip link
ip route
nmcli connection show
```

---

## 8. Upgrade an existing installation

An existing pfVEdge installation should be upgraded using Git.

From the project directory:

```bash
cd /opt/pfVEdge
git pull
sudo ./upgrade.sh
```

The process is intentionally split into two steps:

1. `git pull` retrieves the new project version;
2. `upgrade.sh` applies any changes required by the new version to the existing installation.

### Check for local changes before upgrading

Before upgrading, check the repository status:

```bash
git status
```

If tracked files have been modified locally, review those changes before continuing.

Do not blindly use:

```bash
git reset --hard
```

as this can permanently remove local changes.

In particular, make sure that the local pfVEdge configuration is preserved before performing any operation that could modify it.

---

## 9. Migration from an older version

Versions requiring a specific migration are handled by `upgrade.sh`.

For an installation originating from a version prior to v0.4:

```bash
cd /opt/pfVEdge
git pull
sudo ./upgrade.sh
```

The upgrade script can convert legacy configuration formats when required.

Compatibility mechanisms kept for older installations are not required for new installations.

---

## 10. Post-upgrade checks

After a significant upgrade, check:

```bash
systemctl status pfVEdge.target
```

Then review the logs:

```bash
journalctl -u pfVEdge-bridges.service -b
journalctl -u pfVEdge.service -b
```

Finally, verify that the expected interfaces and routes are present:

```bash
ip link
ip route
nmcli connection show
```

---

## 11. Additional documentation

* [Configuration](configuration.md) — detailed `config.json` documentation
* [Container](container.md) — QEMU container integration and installation handling
* [Delayed Start](delayedstart.md) — delayed startup configuration
* [Routing](routing.md) — routing-specific diagnostics


The documentation structure may evolve as pfVEdge develops.
