# pfVEdge Documentation

pfVEdge integrates a virtualized firewall (pfSense or OPNsense) as the edge firewall of a Fedora host, running under QEMU inside a Podman container.

The project automates network wiring through NetworkManager, connects the resulting bridges to the firewall VM through TAP interfaces, and provides a firewalld recovery path if pfVEdge becomes unavailable.

> **Status:** early-stage project, tested in a real-world environment. Use at your own risk.

---

## 1. Overview

pfVEdge provides a virtualized edge firewall architecture in which the host's physical and virtual networks are connected to a pfSense or OPNsense VM.

The main components are:

1. Linux bridges managed by NetworkManager.
2. Physical interfaces and/or Podman networks attached to these bridges.
3. A dedicated TAP interface for each bridge.
4. A QEMU container running the firewall VM.
5. systemd units orchestrating the complete stack.
6. firewalld providing bridge isolation and a recovery configuration.

```text
                         Fedora Host
┌────────────────────────────────────────────────────────────────────────┐
│                                                                        │
│  Physical NIC ──┐                                                     │
│                 ├──▶ NetworkManager bridge ──▶ TAP ──┐                │
│  Physical NIC ──┘                                    │                │
│                                                      │                │
│  Podman network ──▶ NetworkManager bridge ──▶ TAP ──┼──▶ QEMU         │
│                                                      │      │         │
│  Physical NIC ──▶ NetworkManager bridge ──▶ TAP ────┘      ▼         │
│                                                        pfSense/       │
│                                                        OPNsense       │
│                                                                        │
│  firewalld: bridge isolation / recovery                               │
└────────────────────────────────────────────────────────────────────────┘
```

The firewall VM becomes the filtering point between the configured networks.

`firewalld` is **not used as the normal application-level firewall** once pfVEdge is operational. Its primary role is to isolate the host bridges and provide a safe recovery configuration.

---

## 2. Project layout

```text
pfVEdge/
├── config/
│   ├── bridges.env
│   └── bridges.env.example
│
├── container/
│   ├── Dockerfile
│   └── src/
│       ├── start.sh
│       └── healthcheck/
│
├── lib/
│   ├── init.sh
│   ├── constants.sh
│   ├── parser.sh
│   ├── validation.sh
│   ├── bridges.sh
│   ├── ports.sh
│   ├── taps.sh
│   ├── networkmanager.sh
│   ├── routing.sh
│   ├── firewalld.sh
│   ├── logging.sh
│   └── utils.sh
│
├── scripts/
│   ├── qemu-networks.sh
│   ├── firewalld-profile.sh
│   ├── restore-nmcli.sh
│   └── validate-full-stack.sh
│
├── services/
│   └── etc/
│       ├── containers/systemd/
│       │   └── pfVEdge.container
│       └── systemd/system/
│           ├── pfVEdge.target
│           ├── pfVEdge-bridges.service
│           └── pfVEdge-recovery.service
│
├── docs/
│   ├── README.md
│   ├── routing.md
│   ├── delayedstart.md
│   └── containers.md
│
├── deploy.sh
├── upgrade.sh
├── undeploy.sh
└── license.md
```

---

## 3. Prerequisites

* Fedora-like operating system with NetworkManager active.
* Podman with Quadlet support.
* firewalld installed.
* KVM acceleration available through `/dev/kvm`.
* root privileges for deployment.
* A pfSense or OPNsense boot image.

Network bridges are managed through **NetworkManager/nmcli**.

---

## 4. Configuration (`config/bridges.env`)

The network topology is declared through `BRIDGES_NETWORKS`, with one entry per bridge.

```text
bridge_name:type:interfaces[,interfaces]:ipv4:vlans[,vlans]:firewall-role
```

| Field           | Description                                                        |
| --------------- | ------------------------------------------------------------------ |
| `bridge_name`   | Logical bridge name, automatically prefixed with `br-`             |
| `type`          | `podman` for a Podman network, otherwise a physical/host interface |
| `interfaces`    | Host interface(s) attached to the bridge                           |
| `ipv4`          | Static CIDR, `dhcp`, or empty                                      |
| `vlans`         | Declarative VLAN information handled by the firewall side          |
| `firewall-role` | `wan`, `lan` or `dmz`                                              |

Example:

```bash
BRIDGES_NETWORKS="
wan:eth:eno1:dhcp::wan
lan:eth:eno2:10.10.10.1/24:10,20,30:lan
dmz:podman:net-dmz:10.20.20.1/24::dmz
"
```

Additional parameters are documented in:

```text
config/bridges.env.example
```

At least one `wan` and one `lan` bridge are required.

---

## 5. Deployment

Run:

```bash
sudo ./deploy.sh
```

The deployment process:

1. Builds the pfVEdge container image if required.
2. Installs the systemd and Quadlet units.
3. Substitutes the project path in installed units.
4. Reloads systemd.
5. Enables the required units.
6. Leaves the recovery service disabled; it is triggered through `OnFailure`.

Start pfVEdge with:

```bash
sudo systemctl start pfVEdge.target
```

### Upgrade

```bash
sudo ./upgrade.sh
```

The upgrade script rebuilds the image when required, restarts the stack, validates it and can automatically roll back if validation fails.

### Removal

```bash
sudo ./undeploy.sh
```

The removal process stops and disables pfVEdge, restores the user's firewalld configuration and cleans up the project's runtime resources.

---

## 6. systemd orchestration

The main dependency tree is:

```text
pfVEdge.target
├── Requires: pfVEdge-bridges.service
│             └── prepares bridges, TAPs and firewall state
│
└── Requires: pfVEdge.service
              └── QEMU / pfVEdge VM
                    └── OnFailure:
                        pfVEdge-recovery.service
```

`pfVEdge-bridges.service` prepares the host network before the VM starts.

It:

* backs up the NetworkManager configuration;
* prepares the configured bridges;
* attaches physical and/or Podman interfaces;
* applies network hardening;
* prepares the pfVEdge firewalld profile;
* creates and validates TAP interfaces;
* generates `/run/pfVEdge/network.env`;
* creates the `network.ready` marker.

If validation fails, the NetworkManager transaction can be restored.

The QEMU container only starts once the network is ready.

### Recovery

If the pfVEdge container repeatedly fails, systemd triggers:

```text
pfVEdge-recovery.service
```

The recovery profile isolates the project's bridges and keeps the configured administrative access available.

The objective is to preserve host administration even when the firewall VM itself is unavailable.

---

## 7. Delayed Service Startup

pfVEdge provides an optional systemd timer template for starting dependent services after the firewall becomes available.

The timer uses:

```text
DelayedStart@<service>.timer
```

to start:

```text
<service>.service
```

after a configurable delay.

See [`delayedstart.md`](delayedstart.md) for:

* the default delay;
* randomized startup;
* template overrides;
* per-service overrides;
* enabling/disabling timer instances;
* interaction with service restart policies.

The timer controls the **initial delayed activation**. It does not replace the service's own `Restart=` policy.

---

## 8. Systemd Quadlets

Services depending on pfVEdge should be bound to the firewall lifecycle.

A typical Quadlet can use:

```ini
[Unit]
Description=Systemd Quadlet Example
After=pfVEdge.target
BindsTo=pfVEdge.service

[Container]
Image=registry/container/example:latest
ContainerName=container_name

Network=br-pod-dmz
IP=10.20.20.10

HealthCmd=/path/to/healthcheck
HealthInterval=30s
HealthTimeout=5s
HealthRetries=3
HealthStartPeriod=30s
HealthOnFailure=kill

[Service]
Restart=always
RestartSec=10s

[Install]
WantedBy=pfVEdge.target
```

For a service started through `DelayedStart@`, the service itself must not contain an `[Install]` section that independently enables it under `pfVEdge.target`.

See [`delayedstart.md`](delayedstart.md) for the delayed-start model.

For details specific to the QEMU/pfVEdge container, see [`container.md`](container.md).

---

## 9. Automatic Route Policies

The automatic routing system is documented separately because it covers both NetworkManager-based policy routing and the optional application-specific UID routing mechanism.

See:

**[`routing.md`](routing.md)**

The important distinction is:

* **Automatic network routing:** persistent configuration managed through NetworkManager/nmcli.
* **Application-specific routing:** optional runtime `ip rule` / `ip route` configuration attached to a systemd service.

The first mechanism is part of pfVEdge's network configuration. The second is a service-specific workaround for applications that need explicit source/interface selection but do not provide an adequate configuration option.

---

## 10. firewalld profiles

pfVEdge manages three logical firewalld profiles:

| Profile    | Purpose                                                  |
| ---------- | -------------------------------------------------------- |
| `user`     | Original host configuration, backed up before deployment |
| `pfVEdge`  | Normal operation, one isolated zone per bridge           |
| `recovery` | Emergency configuration after repeated pfVEdge failure   |

In normal operation, the pfVEdge profile uses `DROP` as the default target for the project bridges.

The host firewall is therefore not responsible for replacing the firewall VM. It provides isolation and a recovery boundary around the host.

Manual profile management is available through:

```bash
sudo ./scripts/firewalld-profile.sh backup
sudo ./scripts/firewalld-profile.sh apply pfVEdge
sudo ./scripts/firewalld-profile.sh apply recovery
sudo ./scripts/firewalld-profile.sh reset
```

---

## 11. Logging and troubleshooting

### Overall status

```bash
systemctl status pfVEdge.target
systemctl status pfVEdge-bridges.service
systemctl status pfVEdge.service
```

### Detailed logs

```bash
journalctl -u pfVEdge-bridges.service -f
journalctl -u pfVEdge.service -f
```

### NetworkManager state

```bash
nmcli connection show
nmcli device status
```

### firewalld

```bash
sudo firewall-cmd --get-active-zones
```

### Debug logging

Set in `config/bridges.env`:

```bash
LOG_LEVEL=DEBUG
```

For routing-specific diagnostics, see [`routing.md`](routing.md).

For QEMU, TAP injection, healthcheck and watchdog troubleshooting, see [`container.md`](container.md).

---

## 12. License

MIT — see [`../license.md`](../license.md).
