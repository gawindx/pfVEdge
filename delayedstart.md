# Delayed Service Startup

pfVEdge provides an optional systemd timer template to stagger the startup of services that depend on the pfVEdge network stack.

The mechanism is **opt-in**. pfVEdge does not need to know which applications are installed on the host, and no application-specific service names are hard-coded into the project.

## How it works

The following template is provided by pfVEdge:

```text
DelayedStart@.timer
```

An administrator enables an instance for any systemd service that should use delayed startup:

```bash
systemctl enable DelayedStart@USerService.timer
```

The instance name (`USerService`) identifies the service started by the timer:

```text
DelayedStart@USerService.timer
        |
        | Unit=%i.service
        v
   USerService.service
```

The timer is enabled as a dependency of `pfVEdge.target`. When pfVEdge starts, the timer schedules the service instead of starting it immediately.

The default startup window is:

```text
45 seconds + random delay of 0–30 seconds
```

Therefore, each service starts between approximately **45 and 75 seconds** after the timer is activated.

This spreads the initial workload instead of starting all dependent applications simultaneously.

## Enabling delayed startup

For a service named `USerService.service`:

```bash
systemctl enable DelayedStart@USerService.timer
```

No modification of `pfVEdge.target` is required.

The instance is automatically installed in the appropriate systemd dependency directory.

To test an instance immediately without enabling it permanently:

```bash
systemctl start DelayedStart@USerService.timer
```

To inspect it:

```bash
systemctl status DelayedStart@USerService.timer
```

To list active delayed-start timers:

```bash
systemctl list-timers 'DelayedStart@*.timer'
```

## Service configuration

The service itself does not need to know that it is started by a delayed-start timer.

The timer only controls the **initial startup**. The service keeps its normal systemd lifecycle and restart policy.

### Independent service

For a service that should follow the lifecycle of pfVEdge:

```ini
[Unit]
Description=Example service
After=pfVEdge.target
BindsTo=pfVEdge.service

[Service]
ExecStart=/path/to/application
Restart=always
RestartSec=10s
```
Note that tere is no [Install].

Then:

```bash
systemctl enable DelayedStart@Example.timer
```

The lifecycle is:

```text
pfVEdge.service
      |
      v
pfVEdge.target
      |
      v
DelayedStart@Example.timer
      |
    45–75s
      |
      v
Example.service
```

If the service subsequently fails, its normal `Restart=` policy applies. The delayed-start timer is not involved in crash recovery.

## Services belonging to another service or pod

If several processes already belong to a higher-level service or container pod, apply the delayed startup to the **top-level unit**.

For example:

```text
MasterService.service
    |
    +-- Slave Service 1
    +-- Slave Service 2
    +-- Slave Service 3
```

Use:

```bash
systemctl enable DelayedStart@MAsterService.timer
```

rather than creating separate delayed-start timers for every component.

This preserves the existing lifecycle relationship between the components.

## Services that should not follow pfVEdge restarts

Not every service that uses the pfVEdge network must necessarily be restarted when pfVEdge restarts.

Such a service can simply use:

```ini
[Unit]
After=pfVEdge.target

[Service]
ExecStart=/path/to/application
Restart=always
RestartSec=10s
```

and still use:

```bash
systemctl enable DelayedStart@Example.timer
```

The important distinction is:

* `After=` controls startup ordering.
* `PartOf=` propagates stop/restart operations.
* `BindsTo=` creates a stronger lifecycle relationship and stops the dependent unit when the bound unit disappears.
* `DelayedStart@.timer` only delays the activation of the service.

Choose the lifecycle dependencies according to the application's requirements.

## Restart behavior

The delayed-start timer is intended for **initial activation after pfVEdge starts**.

It does not replace the service's own restart policy.

For example:

```ini
[Service]
Restart=always
RestartSec=10s
```

means that a failed service is restarted normally after 10 seconds, rather than waiting for the delayed-start window again.

When pfVEdge itself is restarted, services explicitly bound to its lifecycle can be stopped and subsequently started again through their enabled delayed-start timers.

## Design principle

The feature follows a simple rule:

> **pfVEdge provides the scheduling mechanism; the administrator decides which services use it.**

This keeps pfVEdge independent from the applications installed on the host and makes delayed startup suitable for arbitrary deployments.

The mechanism is particularly useful for services that generate significant startup load, such as media servers, monitoring systems, indexing services, databases, or container stacks.
