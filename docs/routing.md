# Automatic Route Policies

pfVEdge uses policy routing to ensure that traffic originating from a LAN or DMZ bridge reaches the firewall VM instead of accidentally following the host's main routing table.

This mechanism is primarily implemented through **NetworkManager/nmcli**.

A separate, optional mechanism based on `ip rule` / `ip route` is available for applications that require routing based on their UID.

---

## 1. Why policy routing is required

A Linux host normally uses the `main` routing table.

This works well for a simple single-network configuration, but becomes problematic when the host simultaneously carries several networks that are supposed to use the virtual firewall as their gateway.

For example:

```text
             ┌─────────────────┐
             │   Fedora host   │
             │                 │
LAN ─────────┤ br-lan          │
             │                 │
DMZ ─────────┤ br-dmz          │
             │                 │
WAN ─────────┤ br-wan          │
             └─────────────────┘
```

The host itself must remain able to communicate through its normal WAN route.

At the same time, traffic originating from a LAN or DMZ address must use the firewall VM as its next hop.

A single global default route cannot express both requirements safely.

Policy routing solves this by selecting a routing table according to the source network.

```text
Traffic from LAN ──▶ LAN routing table ──▶ pfVEdge
Traffic from DMZ ──▶ DMZ routing table ──▶ pfVEdge
Host traffic       ──▶ main table      ──▶ normal host route
```

---

## 2. Eligible bridges

Not every bridge receives an automatic routing policy.

The automatic mechanism applies to bridges that:

* have a valid statically configured IPv4 address;
* are not the WAN bridge;
* represent a LAN or DMZ network;
* have a usable firewall gateway.

The following are therefore excluded from automatic policy routing:

* WAN bridges;
* bridges without an IPv4 address;
* DHCP-configured bridges;
* Podman bridges that are only used as transit networks and do not have an eligible host address.

The distinction is intentional.

In particular, a DHCP address is not treated as a stable source network for automatic policy routing.

This prevents the routing system from creating persistent policy tables from addresses that may change or from transient addresses such as link-local `169.254.0.0/16` addresses.

---

## 3. NetworkManager-based routing

The main routing mechanism is configured through NetworkManager.

pfVEdge determines the routing information required for each eligible bridge and configures the corresponding NetworkManager connection profile.

Conceptually, each eligible bridge receives:

1. a dedicated routing table;
2. a source-based routing rule;
3. a route for its directly connected network;
4. routes for the other pfVEdge-controlled networks;
5. a default route through the firewall gateway.

NetworkManager then applies this configuration to the kernel when the connection is activated.

The important point is that **pfVEdge does not directly maintain the runtime `ip rule` state for the automatic routing mechanism**.

Instead:

```text
pfVEdge
   │
   ▼
NetworkManager connection profile
   │
   ▼
NetworkManager applies routing configuration
   │
   ▼
Linux kernel
```

This makes the routing configuration persistent across connection reactivation and host/network restarts.

---

## 4. Routing table selection

Each eligible bridge receives a deterministic routing table identifier.

The identifier is derived from the bridge name so that:

* different bridges do not accidentally share the same table;
* the same bridge receives the same table after a restart;
* routing configuration remains predictable.

The exact table number is an implementation detail and should not normally be hard-coded in user configuration.

Conceptually:

```text
br-lan  ──▶ table A
br-dmz  ──▶ table B
br-sec  ──▶ table C
```

The same principle is used for the associated rule priority.

---

## 5. Source-based policy rules

Each eligible bridge gets a source-based rule.

Conceptually:

```text
from <LAN-network> lookup <LAN-table>
from <DMZ-network> lookup <DMZ-table>
```

This means that traffic originating from the LAN address space uses the LAN routing table, while traffic originating from the DMZ address space uses the DMZ routing table.

The host's normal traffic continues to use the main routing table unless another policy explicitly applies.

This is important because the host must remain autonomous and must not have its normal management or WAN routing redirected through pfVEdge.

---

## 6. Contents of an automatic routing table

A typical policy table contains three categories of routes.

### 6.1 Directly connected network

The bridge's own network is directly reachable through the bridge:

```text
<LAN-network> dev br-lan
```

### 6.2 Other pfVEdge-controlled networks

Other LAN, DMZ and Podman networks are reached through the firewall gateway:

```text
<DMZ-network> via <firewall-gateway> dev br-lan
<Podman-network> via <firewall-gateway> dev br-lan
```

### 6.3 Default route

Internet-bound traffic originating from the network uses the firewall:

```text
default via <firewall-gateway> dev br-lan
```

The result is conceptually:

```text
                   LAN policy table
                   ┌─────────────────────────┐
LAN network ──────▶│ directly connected      │
DMZ network ──────▶│ via pfVEdge             │
Podman network ───▶│ via pfVEdge             │
Internet ─────────▶│ default via pfVEdge     │
                   └─────────────────────────┘
```

---

## 7. Podman networks

Podman networks do not need to have their own source-policy routing tables.

Instead, their networks are included as destinations in the policy tables of the eligible LAN/DMZ bridges.

For example:

```text
LAN policy table
 ├── LAN network       → directly connected
 ├── DMZ network       → via pfVEdge
 ├── Podman network A  → via pfVEdge
 └── default           → via pfVEdge
```

This allows traffic originating from a physical LAN or DMZ interface to reach containers located behind pfVEdge without creating unnecessary routing tables for every Podman bridge.

---

## 8. Main routing table

The automatic policy-routing mechanism does not require modifying the host's normal `main` routing table.

This separation is intentional.

The host therefore retains its normal routing behavior:

```text
Host-originated traffic
        │
        ▼
    main table
        │
        ▼
 normal host gateway
```

while traffic originating from an eligible bridge follows the corresponding policy table:

```text
Bridge-originated traffic
        │
        ▼
source-based rule
        │
        ▼
bridge-specific table
        │
        ▼
pfVEdge gateway
```

This prevents the firewall routing requirements from taking over the host's own routing.

---

## 9. NetworkManager inspection

The configured policy can be inspected with:

```bash
nmcli connection show
```

For a specific connection:

```bash
nmcli -f connection.id,ipv4.addresses,ipv4.gateway,ipv4.routes,ipv4.routing-rules connection show <connection-name>
```

The important fields are:

```text
ipv4.routes
ipv4.routing-rules
```

These represent the persistent NetworkManager configuration.

The kernel's current runtime state can then be checked independently.

---

## 10. Kernel runtime inspection

List policy rules:

```bash
ip rule
```

List all routing tables:

```bash
ip route show table all
```

Inspect a specific table:

```bash
ip route show table <table-id>
```

Ask the kernel which route it would select:

```bash
ip route get <destination> from <source>
```

This last command is particularly useful because it tests the actual policy decision for a given source address.

---

## 11. Troubleshooting

### NetworkManager configuration is missing

Check:

```bash
nmcli connection show
nmcli -f ipv4.routes,ipv4.routing-rules connection show <connection-name>
```

If the routes or rules are missing, inspect the pfVEdge routing configuration and its deployment logs.

---

### NetworkManager configuration is correct but the kernel state is wrong

Check:

```bash
ip rule
ip route show table all
```

Then reactivate the connection:

```bash
nmcli connection down <connection-name>
nmcli connection up <connection-name>
```

This forces NetworkManager to reapply the connection's routing configuration.

---

### Traffic uses the wrong source address

Check the route decision explicitly:

```bash
ip route get <destination> from <source-address>
```

Then inspect:

```bash
ip rule
ip route show table all
```

The problem may not be the automatic bridge routing itself. Applications can select a source address or interface independently of the network's policy-routing configuration.

---

# 12. Application-specific UID routing

Some applications do not provide a useful option to select their source interface or source IP.

In such cases, a secondary routing mechanism can be attached to the service itself.

This mechanism is deliberately **not managed through NetworkManager**.

It is a service-specific runtime workaround implemented through systemd `ExecStartPre` commands.

The distinction is:

| Mechanism                     | Scope                        | Persistence                |
| ----------------------------- | ---------------------------- | -------------------------- |
| NetworkManager policy routing | Network / source address     | Persistent                 |
| UID routing                   | Specific application/service | Recreated at service start |

This keeps the general network configuration clean while allowing a particular service to receive special routing treatment when necessary.

---

## 13. UID routing concept

The mechanism associates a UID with a dedicated routing table:

```text
Application
     │
     │ UID
     ▼
ip rule
     │
     ▼
dedicated routing table
     │
     ▼
specific interface / gateway
```

The UID and routing table ID are logically separate concepts.

They may happen to use related values in a particular implementation, but they do not need to be identical.

---

## 14. Example systemd configuration

The following is a deliberately generic example.

```ini
[Unit]
After=pfVEdge.service
Requires=pfVEdge.service
PartOf=pfVEdge.service
PartOf=pfVEdge.target

[Service]
Environment=UID=1234
Environment=RULE_IDX=10050

ExecStartPre=+/bin/sh -c '/usr/bin/ip rule del pref $(( RULE_IDX + UID )) 2>/dev/null || true'

ExecStartPre=+/usr/sbin/ip route replace <local-network>/24 \
    dev <interface> \
    table $UID

ExecStartPre=+/usr/sbin/ip route replace <remote-network>/24 \
    via <firewall-gateway> \
    dev <interface> \
    table $UID

ExecStartPre=+/usr/sbin/ip rule add \
    pref $(( RULE_IDX + UID )) \
    uidrange $UID-$UID \
    lookup $UID
```

The first command removes an existing rule before recreating it.

This makes the operation idempotent when the service is restarted.

The important part is that the commands run when the service starts, after pfVEdge has prepared the network.

---

## 15. Obtaining a service UID

If the service runs under a dedicated system user:

```bash
id -u <username>
```

The returned UID can then be used in the service override.

For example:

```bash
sudo id -u <username>
```

The actual UID, network, interface and gateway depend entirely on the application being configured.

---

## 16. Why UID routing remains outside NetworkManager

The UID mechanism is intentionally kept separate from the main routing implementation.

It is:

* application-specific;
* optional;
* normally required only for a small number of services;
* recreated when the service starts;
* not part of the host's general network topology.

Moving every such exception into NetworkManager would make the general routing configuration harder to understand and maintain.

The architecture therefore remains:

```text
                    pfVEdge routing
                         │
             ┌───────────┴───────────┐
             │                       │
             ▼                       ▼
      NetworkManager             systemd service
      network routing            application routing
             │                       │
             ▼                       ▼
       source network                UID
             │                       │
             ▼                       ▼
      persistent policy        runtime ip rule
```

---

## 17. Summary

The routing architecture deliberately separates two different problems.

### Automatic network routing

```text
Bridge
  │
  ▼
NetworkManager connection
  │
  ├── routing table
  └── source-based rule
          │
          ▼
       pfVEdge
```

This is the normal pfVEdge routing mechanism and is persistent.

### Application-specific routing

```text
Service
  │
  ▼
systemd ExecStartPre
  │
  ├── ip route
  └── ip rule
          │
          ▼
     UID-specific table
```

This is an optional exception for applications that require explicit routing behavior.

Keeping these two mechanisms separate prevents application-specific workarounds from becoming part of the general network configuration.
