# pfVEdge

**pfVEdge** integrates a virtualized firewall (pfSense or OPNsense) as the edge firewall of a Fedora host, using QEMU, Podman and NetworkManager.

The project automates the network wiring between the host and the firewall VM while keeping a **firewalld recovery path** in case pfVEdge becomes unavailable.

> **Status:** early-stage project, tested in a real-world environment. Use at your own risk.

## Overview

pfVEdge provides:

* NetworkManager-managed bridges for physical and Podman networks
* Automatic TAP creation and injection into the QEMU firewall VM
* pfSense / OPNsense support
* Network policy routing to avoid asymmetric routing
* Podman / Quadlet integration
* firewalld bridge isolation
* automatic recovery if the firewall VM repeatedly fails
* systemd-based orchestration
* optional delayed startup of dependent services

```text
                         Fedora Host
┌─────────────────────────────────────────────────────────────────────┐
│                                                                     │
│  Physical NIC ──▶ NetworkManager bridge ──▶ TAP ──┐                │
│                                                    │                │
│  Podman network ─▶ NetworkManager bridge ──▶ TAP ─┼──▶ QEMU        │
│                                                    │     │          │
│  Physical NIC ──▶ NetworkManager bridge ──▶ TAP ──┘     ▼          │
│                                                     pfSense/        │
│                                                     OPNsense        │
│                                                                     │
│  firewalld isolates host bridges and provides a recovery path       │
└─────────────────────────────────────────────────────────────────────┘
```

## Quick start

```bash
sudo ./deploy.sh
sudo systemctl start pfVEdge.target
```

For upgrades:

```bash
sudo ./upgrade.sh
```

To completely remove pfVEdge:

```bash
sudo ./undeploy.sh
```

## Documentation

The complete documentation is available in [`docs/README.md`](docs/README.md).

### Main topics

* [Configuration](docs/README.md#4-configuration-configbridgesenv)
* [Deployment](docs/README.md#5-deployment)
* [systemd orchestration](docs/README.md#6-systemd-orchestration)
* [Delayed service startup](docs/delayedstart.md)
* [Systemd Quadlets](docs/README.md#8-systemd-quadlets)
* [Automatic routing policies](docs/routing.md)
* [firewalld profiles](docs/README.md#10-firewalld-profiles)
* [Troubleshooting](docs/README.md#11-logging-and-troubleshooting)
* [Container / QEMU documentation](docs/container.md)

## Project layout

```text
pfVEdge/
├── config/                    # pfVEdge configuration
├── container/                 # QEMU/pfVEdge container
├── lib/                       # Shared Bash libraries
├── scripts/                   # Operational scripts
├── services/                  # systemd and Quadlet units
├── docs/                      # Project documentation
├── deploy.sh                  # Installation
├── upgrade.sh                 # Upgrade
└── undeploy.sh                # Removal
```

## License

MIT — see [`license.md`](license.md).
