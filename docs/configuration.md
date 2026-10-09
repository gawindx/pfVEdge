# pfVEdge — Configuration

The main pfVEdge configuration file is:

```text
config/config.json
```

It defines the general pfVEdge behavior and the network bridges used by the firewall VM.

For the installation procedure, see [Installation](installation.md).

---

## Configuration format

The configuration uses JSON.

A commented example is provided with the project.

> Comments in the example configuration are only intended to document the available parameters.
>
> The active configuration file must contain valid JSON and must not contain comments.

---

## General configuration

Example:

```json
{
  "firewall": "pfsense",
  "backup_dir": "/var/lib/pfVEdge",
  "log_level": "info"
}
```

### `backup_dir`

Directory used for pfVEdge backups.

Default:

```json
"backup_dir": "/var/lib/pfVEdge"
```

### `log_level`

Logging level used by pfVEdge.

Default:

```json
"log_level": "info"
```

---

## Network configuration

The `network` section contains the parameters required to configure the network.

Example:

```json
{
  "network": {
    "initialize": false,
    "network_manager": {
      "force_factory_backup": false
    },
    "firewalld": {
      "allow_ssh_host": false
    },
    "gateway_offset": 1,
    "tap_prefix": "tap"
  }
}
```

### `initialize`

Requests network initialization by pfVEdge.

```json
"initialize": false
```

---

## NetworkManager

### `force_factory_backup`

Forces creation of a NetworkManager configuration backup before operations that may modify it.

```json
"force_factory_backup": false
```

---

## Firewalld

### `allow_ssh_host`

Explicitly allows SSH access to the host through the firewalld configuration managed by pfVEdge.

```json
"allow_ssh_host": false
```

This option controls access to the host itself. It does not control access to the firewall VM.

---

## Bridges

The network bridges used by pfVEdge are defined under:

```json
"network": {
  "bridges": {
    ...
  }
}
```

Each bridge has its own configuration.

Example:

```json
"br-wan": {
  "iface": "eth0",
  "iface_type": "eth",
  "ipv4": "192.168.1.254/24",
  "gateway": "192.168.1.1",
  "dns": "192.168.1.1",
  "role": "wan"
}
```

### `iface`

Interface used by the bridge.

Example:

```json
"iface": "eth0"
```

Multiple interfaces can be specified as a comma-separated list when supported by the selected interface type.

Multiple interfaces functionnality will be removed soon, you must migrate each interface to a custom and independant 
bridge.

### `iface_type`

Type of interface used by the bridge.

Supported interface types currently include:

```text
eth
podman
```

### `ipv4`

IPv4 address assigned to the bridge.

Example:

```json
"ipv4": "192.168.1.254/24"
```

Depending on the interface type, an address may be omitted when no host address is required.

You can also use 'dhcp' if interface get his address from dhcp server (wan interface behind router for example).

Podman bridges require a static IPv4 address.

### `gateway`

IPv4 gateway used by the bridge.

Example:

```json
"gateway": "192.168.1.1"
```

If no gateway is specified and the configured IPv4 address provides enough information, pfVEdge can calculate the gateway automatically.

### `dns`

DNS server associated with the bridge.

Example:

```json
"dns": "192.168.1.1"
```

If no DNS server is specified, pfVEdge uses the configured or calculated gateway as the default when possible.

### `role`

Firewall role assigned to the bridge.

Supported roles are:

```text
wan
lan
dmz
```

A valid configuration must contain exactly one `wan` bridge and at least one `lan` bridge.

---

## Additional network parameters

### `gateway_offset`

Offset used when automatically calculating certain gateway addresses.

Default:

```json
"gateway_offset": 1
```

if bridge ip addresses is 10.10.1.1/16 and gateway_offset is 3, calculated gateway will be 10.10.0.3 (mask will be used for determining subnet).

### `tap_prefix`

Prefix used for the TAP interfaces associated with the VM.

Default:

```json
"tap_prefix": "tap"
```

---

## Complete example

```json
{
  "firewall": "pfsense",
  "backup_dir": "/var/lib/pfVEdge",
  "log_level": "info",
  "network": {
    "initialize": false,
    "network_manager": {
      "force_factory_backup": false
    },
    "firewalld": {
      "allow_ssh_host": false
    },
    "bridges": {
      "br-wan": {
        "iface": "eth0",
        "iface_type": "eth",
        "ipv4": "192.168.1.254/24",
        "gateway": "192.168.1.1",
        "dns": "192.168.1.1",
        "role": "wan"
      },
      "br-trunk": {
        "iface": "eth1",
        "iface_type": "eth",
        "ipv4": "10.10.1.1/24",
        "gateway": "10.10.1.2",
        "dns": "10.10.1.2",
        "role": "lan"
      },
      "br-pod-lan": {
        "iface": "pod-lan",
        "iface_type": "podman",
        "ipv4": "10.250.250.1/24",
        "role": "lan"
      },
      "br-pod-dmz": {
        "iface": "pod-dmz",
        "iface_type": "podman",
        "ipv4": "10.254.254.1/24",
        "role": "dmz"
      }
    },
    "gateway_offset": 1,
    "tap_prefix": "tap"
  }
}
```
