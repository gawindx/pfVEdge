# pfVEdge

**v0.2**: Functional version, tested in a real-world environment. The project is still in its early stages, so **use at your own risk.**

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
pfVEdge/
├── config/
│   ├── bridges.env                            # Active configuration (see §4)
│   └── bridges.env.example                    # Annotated template
├── container/                                 # pfVEdge container image (see container/readme.md)
│   ├── Dockerfile
│   └── src/
│       ├── start.sh                           # Injects TAPs into QEMU
│       └── healthcheck/                       # healthcheck.sh + watchdog.sh
├── lib/                                       # Bash library shared by all scripts
│   ├── init.sh                                # Common entry point (parsing, config, libs)
│   ├── constants.sh                           # Exit codes, constants
│   ├── parser.sh                              # Parses BRIDGES_NETWORKS
│   ├── validation.sh                          # Validates configuration and live network state
│   ├── bridges.sh                             # Creates/manages NetworkManager bridges
│   ├── ports.sh                               # Attaches interfaces (real/Podman) to bridges
│   ├── taps.sh                                # Creates/validates TAPs, exports them to QEMU
│   ├── networkmanager.sh                      # Backup/restore of NetworkManager profiles
│   ├── firewalld.sh                           # Generates firewalld profiles (pfSense/recovery/user)
│   ├── routing.sh                             # Generates routing policies for bridge on host (avoid asymetric routes)
│   ├── logging.sh / utils.sh                  # Shared utilities
├── scripts/
│   ├── qemu-networks.sh                       # Prepares bridges + TAPs + firewalld before starting the VM
│   ├── firewalld-profile.sh                   # CLI: backup / apply <profile> / reset
│   ├── restore-nmcli.sh                       # Restores the original NetworkManager configuration
│   └── validate-full-stack.sh                 # Test full stack
├── services/etc/
│   ├── containers/systemd/pfVEdge.container   # Podman quadlet (the pfSense VM)
│   └── systemd/system/
│       ├── pfVEdge.target                     # Global orchestrator
│       ├── pfVEdge-bridges.service            # Prepares the host network
│       └── pfVEdge-recovery.service           # Emergency firewalld fallback
├── storage/                                   # Persistent disk of the pfSense VM
├── deploy.sh / undeploy.sh / upgrade.sh       # Deployement scripts
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
1. builds the `pfVEdge:current` image if it doesn't already exist;
2. installs the systemd units and the quadlet (`services/etc/*` → `/etc/*`), substituting `__PROJECT_DIR__` with the actual project path;
3. reloads systemd and enables the units (except `pfVEdge-recovery.service`, which is never enabled at boot: it is only triggered via `OnFailure`);
4. prints the command to start the stack.

Starting the stack:

```bash
sudo systemctl start pfVEdge.target
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
pfVEdge.target
  ├── Requires: pfVEdge-bridges.service   (oneshot, prepares bridges + TAPs + pfSense firewalld profile)
  └── Requires: pfVEdge.service           (generated by the quadlet, the pfSense VM under QEMU)
                    └── OnFailure: pfVEdge-recovery.service
```

- **`pfVEdge-bridges.service`** runs `scripts/qemu-networks.sh`: backs up the NetworkManager configuration (factory + transaction), resets NetworkManager, creates/validates the bridges, attaches real interfaces and/or Podman networks to them, applies MTU and `sysctl` hardening, backs up the user's firewalld profile if not already saved, generates the `pfSense` firewalld profile (one zone per bridge, `DROP` by default), creates and validates the TAPs, and finally writes `/run/pfVEdge/network.env` (list of TAPs) as well as the `/run/pfVEdge/network.ready` marker. If validation fails, the transaction NetworkManager configuration is automatically restored.
- **The `pfVEdge` container** (quadlet) only starts once `network.ready` exists (`ExecStartPre`). It mounts the TAP file generated in the previous step, as well as the persistent `storage/` volume.
- **Resilience**: `StartLimitIntervalSec=300` / `StartLimitBurst=5` — if the container fails more than 5 times in 5 minutes, systemd stops restarting it and triggers `pfVEdge-recovery.service` (`OnFailure`, `OnFailureJobMode=replace-irreversibly`).
- **`pfVEdge-recovery.service`** then applies the `recovery` firewalld profile: a **single zone** grouping all the project's bridges, `DROP` by default, with only the SSH port opened — the port is extracted dynamically from `/etc/ssh/sshd_config` (`get_ssh_port`, falling back to `22` if absent). The goal: keep administrative access to the server even if pfSense is completely down, without falling back to an open-by-default firewalld configuration.

## 7. Systemd Quadlets

To use and bind a quadlet to the target, you must use specific parameters that allow your containers to start after `pfVEdge.target` and also follow its restarts.

You will also find parameters to ensure the container restarts in the event of a failure (you will need to provide the command to check the container's status).

Exemple of quadlet

```
[Unit]
Description=Systemd Quadlet Example
After=pfVEdge.service
Requires=pfVEdge.service
PartOf=pfVEdge.service
PartOf=pfVEdge.target

[Container]
Image=registry/container/example:latest
ContainerName=Container_Name

Network=br-pod-dmz
IP=1.2.3.4

HealthCmd=put_your_healthcheck_command_here 
HealthInterval=30s
HealthTimeout=5s
HealthRetries=3
HealthStartPeriod=30s
HealthOnFailure=kill

[Service]
Restart=always
TimeoutStartSec=300

[Install]
WantedBy=pfVEdge.target
```

## 8. automatic route policies

To avoid asymmetric routing errors, every physical interface that has a valid IP address and is not assigned to the WAN is allocated a routing rule and routing table, enabling it to correctly route packets to pfVEdge. Without these rules, there is a risk of asymmetric routing and packet leakage via the host itself.

The rule number is derived from the bridge name to avoid overwriting another bridge's routing table; the same applies to the rule index.
The host remains autonomous, continues using the main routing table, and is therefore unaffected.

Each rule contains the necessary routes to ensure that packets originating from the relevant bridge are correctly forwarded to the pfVEdge networks and the Internet, thereby preventing the bridge from bypassing the firewall via the host.

However, this behavior can cause issues in certain cases. If you use a program that lacks settings to specify the interface to bind to, and it defaults to the first interface it finds, it might not bind to the correct one.
This example is based on how Squeezelite operates.

In my case, I use my homelab's audio output as a Squeezelite player.
Unfortunately, Squeezelite was binding to the WAN address by default, with no option to specify which interface or IP to use.
It is possible to create a specific routing table and rule based on UID detection.
In my case, Squeezelite runs under a specific user account, and therefore has a fixed, specific UID.

There are two scenarios:
- The service is launched without 'User' and 'Group' restrictions. In this case, if you are on a recent system, you can edit the relevant service and 
  add the following:

```
[Unit]
Description=Mon Service Reseau Dynamique
After=network.target
After=pfVEdge.service
Requires=pfVEdge.service
PartsOf=pfVEdge.service
PartOf=pfVEdge.target

[Service]
DynamicUser=yes

Environment=RULE_IDX=5000

ExecStartPre=+/bin/sh -c '/usr/bin/ip rule del pref $RULE_IDX 2>/dev/null || true'
ExecStartPre=+/usr/bin/bash -c ' \
    TABLE_IDX=$(( %U - 5588000 )); \
    /usr/sbin/ip route replace listening_interface_ip/cidr dev interface_name table $TABLE_IDX; \
    /usr/sbin/ip route replace other_subnet/cidr via gateway_of_interface dev interface_name table $TABLE_IDX; \
    /usr/sbin/ip rule add pref $RULE_IDX uidrange %U-%U lookup $TABLE_IDX'

ExecStopPost=+/usr/bin/bash -c ' \
    TABLE_IDX=$(( %U - 58000 )); \
    /usr/sbin/ip rule del pref $RULE_IDX 2>/dev/null || true; \
    /usr/sbin/ip route flush table $TABLE_IDX 2>/dev/null || true'
```
- The service is already running with the 'User' and 'Group' parameters; you need to retrieve the user's UID via:

```bash
sudo id -u username
```
Keep it!

Edit the relevant service, adapt the template to your configuration (UID, network, gateway, etc.) and add it.

```
[Unit]
After=pfVEdge.service
Requires=pfVEdge.service
PartOf=pfVEdge.service
PartOf=pfVEdge.target

[Service]
Environment=UID=uid_username
Environment=RULE_IDX=5000
ExecStartPre=+/bin/sh -c '/usr/bin/ip rule del pref $(( $RULE_IDX + $UID )) 2>/dev/null || true'
ExecStartPre=+/usr/sbin/ip route replace listening_interface_ip/cidr dev interface_name table $UID
ExecStartPre=+/usr/sbin/ip route replace other_subnet/cidr via gateway_of_interface dev interface_name table $UID
ExecStartPre=+/usr/sbin/ip rule add pref $(( $RULE_IDX + $UID )) uidrange $UID-$UID lookup $UID

ExecStopPost=+/usr/sbin/ip route flush table $TABLE_IDX
```
Unit directives are recommended because they ensure the route is correctly recreated after each startup of pfVEdge.service (which implies that the network may have been affected).



## 9. firewalld profiles

Three profiles, managed by `lib/firewalld.sh` / `scripts/firewalld-profile.sh`:

| Profile    | When                                                  | Behavior                                       |
|------------|-------------------------------------------------------|------------------------------------------------|
| `user`     | Automatically backed up before the first deployment,  | The host's original firewalld configuration,   |
|            | restored by `undeploy.sh`                             | before the project was integrated              |
| `pfSense`  | Normal operation                                      | One zone per bridge, `DROP` by default,        |
|            |                                                       | optionally SSH if `FWD_ALLOW_SSH_HOST=true`    |
| `recovery` | After repeated failure of the pfSense container       | A single zone grouping all bridges, `DROP` by  |
|            |                                                       | default, only SSH open                         |

```bash
# Manual CLI usage
sudo ./scripts/firewalld-profile.sh backup
sudo ./scripts/firewalld-profile.sh apply pfSense
sudo ./scripts/firewalld-profile.sh apply recovery
sudo ./scripts/firewalld-profile.sh reset
```

Each profile application backs up the current firewalld configuration before making changes, and automatically restores it if generation fails.

## 10. Logging and troubleshooting

```bash
# Overall status
systemctl status pfVEdge.target
systemctl status pfVEdge-bridges.service
systemctl status pfVEdge.service

# Detailed logs
journalctl -u pfVEdge-bridges.service -f
journalctl -u pfVEdge.service -f

# Active firewalld zones
sudo firewall-cmd --get-active-zones

# Switch to DEBUG (config/bridges.env)
LOG_LEVEL=DEBUG
```

For troubleshooting specific to the pfSense VM itself (healthcheck, watchdog, QEMU network injection), see the [container README](./container/readme.md).


## 11. License

MIT — see [`license.md`](./license.md).
