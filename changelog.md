# Changelog

All notable changes to pfVEdge are documented in this file.

## [0.4.0] - 2026-10-06

### Changed

* Migrated the configuration system from the legacy environment file to JSON.
* Removed VLAN-specific configuration and logic.
* Improved NetworkManager integration and persistent network configuration.
* Added configurable DNS handling for network bridges.
* Improved dependency and environment validation.
* Added temporary port 8006 access during initial firewall VM installation only.
* Improved installation-state detection and automatic firewall rule cleanup.
* Simplified and reorganized the network architecture.
* Updated installation, configuration, upgrade, and operational documentation.
* Cleaned up obsolete configuration, routing, and VLAN references.

## [0.3.0]

### Added

* Added systemd-based service and startup management.
* Added automatic network initialization and recovery handling.
* Added firewalld integration and fallback rules.
* Added persistent network configuration and routing management.
* Improved QEMU/Podman integration and VM lifecycle handling.
* Added upgrade and migration support.
* Improved network validation and error handling.
* Added support for delayed VM startup.
* Improved documentation and deployment tooling.

## [0.2.0]

### Added

* First functional release.
* Added bridge creation and network wiring.
* Added TAP interface management for QEMU.
* Added port and interface management.
* Added QEMU virtual machine integration.
* Added Podman container integration.
* Added basic deployment and startup automation.

## [0.1.0]

### Added

* First pfVEdge version.
* Initial proof of concept for running a virtual firewall on a Linux host.
