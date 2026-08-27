# Configuration examples

These examples demonstrate common `service-watchdog` use cases. Copy the
closest example to a root-owned location and replace all domains, paths, ports,
service names, and commands before enabling scheduled runs.

| Example | Use case |
| --- | --- |
| [`http-docker-compose.yaml`](http-docker-compose.yaml) | Check an HTTP health endpoint and restart Docker Compose services |
| [`tcp-systemd.yaml`](tcp-systemd.yaml) | Check a TCP port and restart a systemd unit |
| [`command-check.yaml`](command-check.yaml) | Use a local command as the health check |
| [`multiple-services.yaml`](multiple-services.yaml) | Monitor HTTP, TCP, and systemd services in one run |
| [`hooks.yaml`](hooks.yaml) | Run notification hooks on failure and recovery transitions |
| [`smtp-email.yaml`](smtp-email.yaml) | Send built-in SMTP email on failure and recovery transitions |
| [`telegram-notifications.yaml`](telegram-notifications.yaml) | Send Telegram transition notifications with a bot token from the environment |

Test a configuration without executing remediation commands or changing state:

```bash
sudo ./service-watchdog.sh \
  -c ./examples/http-docker-compose.yaml \
  -n
```

Check only one configured service:

```bash
sudo ./service-watchdog.sh \
  -c ./examples/multiple-services.yaml \
  -s public-api \
  -n
```

The paths in the examples are intentionally illustrative. Configuration
validation will fail until referenced working directories exist on the target
server.
