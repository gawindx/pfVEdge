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
systemctl enable DelayedStart@UserService.timer
```

The instance name (`UserService`) identifies the service started by the timer:

```text
DelayedStart@UserService.timer
        |
        | Unit=%i.service
        v
   UserService.service
```

The timer is enabled as a dependency of `pfVEdge.target`. When pfVEdge starts, the timer schedules the service instead of starting it immediately.

The default timer configuration is:

```ini
[Timer]
OnActiveSec=45s
RandomizedDelaySec=30s
AccuracySec=5s
```

This means that the service is normally started approximately **45 to 75 seconds** after the timer becomes active, with a small scheduling tolerance controlled by `AccuracySec`.

The random delay is intentional: it spreads the initial workload instead of starting all dependent applications simultaneously.

## Enabling delayed startup

For a service named `UserService.service`:

```bash
systemctl enable DelayedStart@UserService.timer
```

No modification of `pfVEdge.target` is required.

The instance is automatically installed in the appropriate systemd dependency directory.

To test an instance immediately without enabling it permanently:

```bash
systemctl start DelayedStart@UserService.timer
```

To inspect it:

```bash
systemctl status DelayedStart@UserService.timer
```

To list active delayed-start timers:

```bash
systemctl list-timers 'DelayedStart@*.timer'
```

## Customizing the startup delay

The default delay is suitable for most installations, but it can be changed without modifying the files installed by pfVEdge.

Systemd provides **drop-in overrides** specifically for this purpose.

To change the default delay for all `DelayedStart@` instances:

```bash
systemctl edit DelayedStart@.timer
```

Add a `[Timer]` section containing the values you want to override.

For example:

```ini
[Timer]
OnActiveSec=60s
RandomizedDelaySec=60s
```

With this configuration, services will normally start approximately **60 to 120 seconds** after their delayed-start timer becomes active.

Only the properties explicitly specified in the override are changed. Other timer settings provided by pfVEdge remain unchanged.

For example, to change only the random delay:

```ini
[Timer]
RandomizedDelaySec=60s
```

The original `OnActiveSec=45s` and `AccuracySec=5s` settings remain in effect.

### Per-service customization

If a different delay is required for a particular service, the override can be applied to the specific timer instance instead:

```bash
systemctl edit DelayedStart@UserService.timer
```

For example:

```ini
[Timer]
OnActiveSec=120s
RandomizedDelaySec=30s
```

This changes the delay only for `UserService`.

### Template versus instance

There are two different types of override:

```bash
# All delayed-start instances
systemctl edit DelayedStart@.timer
```

and:

```bash
# One specific instance
systemctl edit DelayedStart@UserService.timer
```

Use the **template override** when the same delay should apply to all services.

Use an **instance override** when one service needs a different startup delay.

### Where does the override go?

`systemctl edit` creates a systemd drop-in rather than modifying the original pfVEdge file.

For the template, the resulting file is typically:

```text
/etc/systemd/system/DelayedStart@.timer.d/override.conf
```

For an individual instance:

```text
/etc/systemd/system/DelayedStart@UserService.timer.d/override.conf
```

This is preferable to editing the timer installed by pfVEdge because the override is kept separately from the project files and is therefore not overwritten when pfVEdge is upgraded.

After creating or modifying an override, reload the systemd configuration:

```bash
systemctl daemon-reload
```

The timer can then be restarted if the change needs to take effect immediately on an already active timer:

```bash
systemctl restart DelayedStart@UserService.timer
```

> **Note:** restarting the timer does not restart the associated service directly. It resets the timer and schedules a new delayed activation according to its current configuration.

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

Note that there is no `[Install]`.

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
systemctl enable DelayedStart@MasterService.timer
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

Also no `[Install]`.

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
