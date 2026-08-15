# Watchdog

A small, dependency-light Bash watchdog for websites and services. It runs
configured health checks and executes an explicit command sequence when a
target stays unavailable after all retry attempts.

The watchdog is intentionally a one-shot program. Run it from a systemd timer,
cron, or another scheduler.

## Features

- HTTP/HTTPS checks with redirects, timeouts, retries, and expected statuses
- TCP port checks using Bash `/dev/tcp`
- Arbitrary command checks
- Ordered remediation commands without `eval`
- Per-service action cooldown
- Optional health verification after remediation
- Failure and recovery hooks with environment variables
- Persistent state and transition-only hooks
- Global non-blocking lock to prevent overlapping runs
- Dry-run and single-service modes
- Strict YAML validation and bounded command execution

## Requirements

- Linux and Bash 4.3 or newer
- [Mike Farah `yq` v4](https://github.com/mikefarah/yq)
- `curl`, `flock`, and GNU `timeout`/coreutils

On Debian or Ubuntu, install the system packages with:

```bash
sudo apt-get install bash curl util-linux coreutils
```

Install `yq` v4 using its official package or release instructions. The Python
package with the same name is not compatible.

## Quick start

```bash
sudo install -d -m 0755 /opt/service-watchdog
sudo install -m 0755 service-watchdog.sh /opt/service-watchdog/
sudo install -m 0640 config.example.yaml /opt/service-watchdog/config.yaml
sudo editor /opt/service-watchdog/config.yaml
sudo /opt/service-watchdog/service-watchdog.sh -n
sudo /opt/service-watchdog/service-watchdog.sh
```

Or run `sudo ./install.sh` to install the script and systemd units.

## Configuration

Commands are YAML arrays, not shell strings. This preserves argument boundaries
and prevents accidental shell interpolation:

```yaml
services:
  - name: api
    check:
      type: http
      url: https://api.example.com/health
      success_status: [200, 204]
      timeout: 10
      attempts: 2
      retry_delay: 2

    actions:
      cooldown: 300
      verify_after: 5
      commands:
        - command: [docker, compose, restart, api]
          working_directory: /srv/api
          timeout: 120
```

See [`config.example.yaml`](config.example.yaml) for HTTP, TCP, and command
examples.

### Check types

#### HTTP

Required fields: `type: http` and `url`. By default, any final `2xx` response is
successful. Set `success_status` to an explicit list when needed. A timeout,
connection error, empty response, `HTTP 000`, or unexpected status is a failed
attempt.

#### TCP

Required fields: `type: tcp`, `host`, and `port`. The check succeeds when a TCP
connection can be opened before the timeout.

#### Command

Required fields: `type: command` and `commands`. Commands run sequentially and
the check fails on the first non-zero exit status.

### Remediation behavior

1. The check is attempted `attempts` times.
2. If every attempt fails, `actions.commands` run sequentially.
3. Further actions are suppressed until `cooldown` seconds pass.
4. After `verify_after` seconds, the complete check is repeated.
5. The target is marked unavailable if it still fails.

Set `cooldown: 0` to allow an action on every scheduled run. Commands stop at
the first failure, matching shell `&&` semantics.

### Hooks and integrations

`hooks.on_failure` and `hooks.on_recovery` run only on state transitions. Use
them to call a mailer, Slack script, incident platform, or any local integration.
Each command receives:

- `WATCHDOG_SERVICE`
- `WATCHDOG_EVENT` (`unavailable` or `healthy`)
- `WATCHDOG_DETAIL`
- `WATCHDOG_CHECK_TYPE`
- `WATCHDOG_HTTP_STATUS`
- `WATCHDOG_CHECK_EXIT`
- `WATCHDOG_TIMESTAMP`

Example:

```yaml
hooks:
  on_failure:
    - command: [/usr/local/bin/notify-watchdog]
      timeout: 30
  on_recovery:
    - command: [/usr/local/bin/notify-watchdog]
      timeout: 30
```

Keep secrets outside YAML. Notification scripts can read credentials from a
root-owned environment file or secret manager.

## Usage and exit codes

```text
service-watchdog.sh [-c FILE] [-s SERVICE] [-n]
```

- `0`: all selected services are healthy and no remediation was attempted
- `1`: at least one service is unavailable or remediation was attempted
- `2`: configuration, dependency, or environment error

`-n` performs checks but skips remediation, hooks, and state writes. It still
writes operational logs and acquires the lock.

## systemd

The included timer runs once per minute. Adjust `OnUnitActiveSec` in
`packaging/systemd/service-watchdog.timer` if needed.

```bash
sudo systemctl enable --now service-watchdog.timer
systemctl list-timers service-watchdog.timer
journalctl -u service-watchdog.service
```

The service unit treats exit code `1` as an expected watchdog result; only exit
code `2` marks the unit failed.

## cron

Use root's crontab when remediation commands require access to Docker,
`systemctl`, or other privileged services. First make the script executable and
verify the configuration in dry-run mode:

```bash
sudo chmod +x /opt/service-watchdog/service-watchdog.sh
sudo /opt/service-watchdog/service-watchdog.sh \
  -c /etc/service-watchdog/config.yaml \
  -n
```

Open root's crontab:

```bash
sudo crontab -e
```

Run the watchdog every minute:

```cron
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

* * * * * /opt/service-watchdog/service-watchdog.sh -c /etc/service-watchdog/config.yaml >> /var/log/service-watchdog/cron.log 2>&1
```

For a five-minute interval, use:

```cron
*/5 * * * * /opt/service-watchdog/service-watchdog.sh -c /etc/service-watchdog/config.yaml >> /var/log/service-watchdog/cron.log 2>&1
```

Check the installation and follow the operational log:

```bash
sudo systemctl status cron
sudo crontab -l
sudo tail -f /var/log/service-watchdog/service-watchdog.log
```

The global `flock` lock prevents overlapping cron runs. Exit code `1` is an
expected result when a target remains unavailable or remediation was attempted;
cron can continue scheduling subsequent runs normally.

## Security notes

- Run with the least privileges required by remediation commands.
- Keep the configuration root-owned and not writable by the service account.
- Avoid putting passwords, tokens, or shell snippets in YAML.
- Commands are executed directly as argument arrays; no `eval` or `bash -c` is
  used for configured commands.
- Command output is truncated before it is written to the log.

## Testing

```bash
bash -n service-watchdog.sh tests/smoke.sh
./tests/smoke.sh
```

The smoke test starts a local HTTP server and verifies both the healthy path and
the remediation path.

## License

MIT

## Author

[Igor Sazonov](https://github.com/tigusigalpa) —
[sovletig@gmail.com](mailto:sovletig@gmail.com)

Project repository: [github.com/tigusigalpa/watchdog](https://github.com/tigusigalpa/watchdog)
