# pfVEdge Container

This directory contains the container definition and runtime files used to run the pfVEdge QEMU environment.

## Contents

The container is responsible for running the QEMU virtual machine and exposing the interfaces required to connect the VM to the pfVEdge host networking.

The main components include:

* the container image definition;
* the QEMU startup script;
* QEMU network/TAP handling;
* the QMP monitor socket;
* the noVNC console;
* the QEMU healthcheck and watchdog logic;
* the pfSense / OPNsense VM storage.

## Documentation

The complete documentation for the pfVEdge container is available in:

**[`../docs/container.md`](../docs/container.md)**

That document covers:

* container architecture;
* QEMU startup;
* network and TAP injection;
* QMP;
* noVNC;
* healthchecks;
* watchdog behaviour;
* VM installation detection;
* runtime markers;
* troubleshooting.

## Development

Changes to the container startup or QEMU runtime should be tested together with the corresponding systemd/Quadlet units.

The container is normally built and managed through the pfVEdge deployment scripts rather than manually.
