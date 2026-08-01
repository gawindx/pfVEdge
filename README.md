# qemu-pfsense

**v0.1**: first released version ; No real-world testing has been performed; only tests in a virtualized environment have been conducted. **Use at your own risk.**

Any feedback is welcome.

Offloads firewall management from a **Fedora** host to a **pfSense** VM, running under QEMU inside a Podman container, with automated network wiring and a firewalld fallback in case of failure.

`firewalld` is no longer used to filter traffic: once the project is deployed, its only job is to isolate the host bridges from each other (`DROP` by default) while pfSense takes over actual traffic filtering.

---

## 1. Overview

1. On the host, **Linux bridges** (NetworkManager) are created from real interfaces (e.g. `ens160`, `ens192`) and/or virtual **Podman** networks (e.g. an internal DMZ for application containers).
2. Each bridge gets a dedicated **TAP** interface.
3. These TAPs are injected into a QEMU container (based on [`qemux/qemu`](https://github.com/qemus/qemu)) that boots a **pfSense** VM, which attaches one TAP per bridge = one network interface per bridge on the pfSense side (WAN, LAN/trunk, DMZ, ...).
4. pfSense becomes the single filtering point between these networks. `firewalld`'s role on the host is reduced to isolating the bridges by default (`DROP`), while/until pfSense is up and running.
5. Everything is orchestrated by a **systemd target**, with dual supervision of the VM (Podman healthcheck + internal container watchdog) and an automatic **fallback mode** if the pfSense container repeatedly fails.

```
                  Fedora Host
   ┌─────────────────────────────────────────────────────────────────────────────┐
   │  ens160 ──┐                                                                 │
   │           ├─▶ br-wan   ──▶ tap-wan   ──┐                                   │
   │  ens192 ──┐                             │                                   │
   │           ├─▶ br-trunk ──▶ tap-trunk ──┼──▶ Container│──▶ pfSense VM      |
   │  podman ──┐                             │      (QEMU)     WAN / LAN / DMZ   |
   │  network ─┴─▶ br-net-dmz ─▶ tap-net-dmz┘                                   │
   │                                                                             │
   │  firewalld: one zone per bridge, default target=DROP                        │
   └─────────────────────────────────────────────────────────────────────────────┘
```

## 2. Project layout

```
qemu-pfsense/
├── config/
│   ├── bridges.env            # Active configuration (see §4)
│   └── bridges.env.example    # Annotated template
├── container/                 # QEMU/pfSense image (see container/readme.md)
│   ├── Dockerfile
│   └── src/
│       ├── start.sh           # Injects TAPs into QEMU
│       └── healthcheck/       # healthcheck.sh + watchdog.sh
├── lib/                       # Bash library shared by all scripts
│   ├── init.sh                # Common entry point (parsing, config, libs)
│   ├── constants.sh           # Exit codes, constants
│   ├── parser.sh              # Parses BRIDGES_NETWORKS
│   ├── validation.sh          # Validates configuration and live network state
│   ├── bridges.sh             # Creates/manages NetworkManager bridges
│   ├── ports.sh                # Attaches interfaces (real/Podman) to bridges
│   ├── taps.sh                 # Creates/validates TAPs, exports them to QEMU
│   ├── networkmanager.sh       # Backup/restore of NetworkManager profiles
│   ├── firewalld.sh            # Generates firewalld profiles (pfsense/recovery/user)
│   ├── logging.sh / utils.sh   # Shared utilities
├── scripts/
│   ├── qemu-networks.sh        # Prepares bridges + TAPs + firewalld before starting the VM
│   ├── firewalld-profile.sh    # CLI: backup / apply <profile> / reset
│   └── restore-nmcli.sh        # Restores the original NetworkManager configuration
├── services/etc/
│   ├── containers/systemd/qemu-pfsense.container   # Podman quadlet (the pfSense VM)
│   └── systemd/system/
│       ├── qemu-pfsense.target                     # Global orchestrator
│       ├── qemu-pfsense-bridges.service            # Prepares the host network
│       └── qemu-pfsense-recovery.service           # Emergency firewalld fallback
├── storage/                    # Persistent disk of the pfSense VM
├── deploy.sh / undeploy.sh / upgrade.sh / validate-full-stack.sh
└── license.md
```

## 3. Prerequisites

- Fedora-Like Os with **NetworkManager** active (bridges are managed exclusively via `nmcli`);
- **Podman** with quadlet support (`/etc/containers/systemd`);
- **firewalld** installed (used only for zone isolation, not application-level filtering);
- **KVM** acceleration available (`/dev/kvm`) for decent pfSense performance;
- root privileges for deployment (`deploy.sh`, `undeploy.sh`, `upgrade.sh`);
- a pfSense boot image (default defined in the [Dockerfile](./container/Dockerfile), overridable).

## 4. Configuration (`config/bridges.env`)

The entire network topology is declared in a single variable, `BRIDGES_NETWORKS`, one line per bridge:

```
bridge_name:type:interfaces[,interfaces]:ipv4:vlans[,vlans]:firewall-role
```

| Field           | Description                                                                                  |
|-----------------|----------------------------------------------------------------------------------------------|
| `bridge_name`   | Logical bridge name (automatically prefixed with `br-`)                                      |
| `type`          | `podman` to create a Podman network attached to the bridge, otherwise real interface(s)      |
| `interfaces`    | Host interface(s) to attach (comma-separated list)                                           |
| `ipv4`          | `cidr` (`10.0.0.1/24`), `dhcp`, or empty (bridge carries no address)                         |
| `vlans`         | Declarative only (validated and stored, not created — VLANs are handled on the pfSense side) |
| `firewall-role` | `wan`, `lan` or `dmz` — determines the associated firewalld zone                             |

Example (current project `config/bridges.env`):

```bash
BRIDGES_NETWORKS="
wan:eth:ens160:dhcp::wan
trunk:eth:ens192:192.168.1.10/24:10,20,30,40,50:lan
net-dmz:podman:net-dmz:10.254.254.1/24::dmz
"
LOG_LEVEL="DEBUG"
NM_AUTO_MIGRATE_IFACE=true
```

> Exactly **one `wan` bridge** and **at least one `lan` bridge** are required (`validate_fw_roles`, in `lib/validation.sh`). The full, annotated file is available at [`config/bridges.env.example`](./config/bridges.env.example), with details on all additional parameters (`NM_AUTO_MIGRATE_IFACE`, `NM_FORCE_FACTORY_BACKUP`, `FWD_ALLOW_SSH_HOST`, `TAP_PREFIX`, `BACKUP_DIR`, `LOG_LEVEL`).

## 5. Deployment

```bash
sudo ./deploy.sh
```

This script:
1. builds the `qemu-pfsense:current` image if it doesn't already exist;
2. installs the systemd units and the quadlet (`services/etc/*` → `/etc/*`), substituting `__PROJECT_DIR__` with the actual project path;
3. reloads systemd and enables the units (except `qemu-pfsense-recovery.service`, which is never enabled at boot: it is only triggered via `OnFailure`);
4. prints the command to start the stack.

Starting the stack:

```bash
sudo systemctl start qemu-pfsense.target
```

Other operations:

```bash
sudo ./upgrade.sh     # Rebuilds the image if container/ contents changed,
                       # restarts the stack, validates it, and rolls back automatically on failure

sudo ./undeploy.sh     # Stops/disables the units, restores the "user" firewalld profile,
                       # cleans up TAPs and container images
```

## 6. systemd orchestration

```
qemu-pfsense.target
  ├── Requires: qemu-pfsense-bridges.service   (oneshot, prepares bridges + TAPs + pfsense firewalld profile)
  └── Requires: qemu-pfsense.service           (generated by the quadlet, the pfSense VM under QEMU)
                    └── OnFailure: qemu-pfsense-recovery.service
```

- **`qemu-pfsense-bridges.service`** runs `scripts/qemu-networks.sh`: backs up the NetworkManager configuration (factory + transaction), resets NetworkManager, creates/validates the bridges, attaches real interfaces and/or Podman networks to them, applies MTU and `sysctl` hardening, backs up the user's firewalld profile if not already saved, generates the `pfsense` firewalld profile (one zone per bridge, `DROP` by default), creates and validates the TAPs, and finally writes `/run/qemu-pfsense/network.env` (list of TAPs) as well as the `/run/qemu-pfsense/network.ready` marker. If validation fails, the transaction NetworkManager configuration is automatically restored.
- **The `qemu-pfsense` container** (quadlet) only starts once `network.ready` exists (`ExecStartPre`). It mounts the TAP file generated in the previous step, as well as the persistent `storage/` volume.
- **Resilience**: `StartLimitIntervalSec=300` / `StartLimitBurst=5` — if the container fails more than 5 times in 5 minutes, systemd stops restarting it and triggers `qemu-pfsense-recovery.service` (`OnFailure`, `OnFailureJobMode=replace-irreversibly`).
- **`qemu-pfsense-recovery.service`** then applies the `recovery` firewalld profile: a **single zone** grouping all the project's bridges, `DROP` by default, with only the SSH port opened — the port is extracted dynamically from `/etc/ssh/sshd_config` (`get_ssh_port`, falling back to `22` if absent). The goal: keep administrative access to the server even if pfSense is completely down, without falling back to an open-by-default firewalld configuration.

## 7. firewalld profiles

Three profiles, managed by `lib/firewalld.sh` / `scripts/firewalld-profile.sh`:

| Profile    | When                                                  | Behavior                                       |
|------------|-------------------------------------------------------|------------------------------------------------|
| `user`     | Automatically backed up before the first deployment,  | The host's original firewalld configuration,   |
|            | restored by `undeploy.sh`                             | before the project was integrated              |
| `pfsense`  | Normal operation                                      | One zone per bridge, `DROP` by default,        |
|            |                                                       | optionally SSH if `FWD_ALLOW_SSH_HOST=true`    |
| `recovery` | After repeated failure of the pfSense container       | A single zone grouping all bridges, `DROP` by  |
|            |                                                       | default, only SSH open                         |

```bash
# Manual CLI usage
sudo ./scripts/firewalld-profile.sh backup
sudo ./scripts/firewalld-profile.sh apply pfsense
sudo ./scripts/firewalld-profile.sh apply recovery
sudo ./scripts/firewalld-profile.sh reset
```

Each profile application backs up the current firewalld configuration before making changes, and automatically restores it if generation fails.

## 8. Logging and troubleshooting

```bash
# Overall status
systemctl status qemu-pfsense.target
systemctl status qemu-pfsense-bridges.service
systemctl status qemu-pfsense.service

# Detailed logs
journalctl -u qemu-pfsense-bridges.service -f
journalctl -u qemu-pfsense.service -f

# Active firewalld zones
sudo firewall-cmd --get-active-zones

# Switch to DEBUG (config/bridges.env)
LOG_LEVEL=DEBUG
```

For troubleshooting specific to the pfSense VM itself (healthcheck, watchdog, QEMU network injection), see the [container README](./container/readme.md).

## 9. License

MIT — see [`license.md`](./license.md).
