# Watchdog

![Watchdog Hero Banner](https://i.postimg.cc/YCBRD2hr/watchdog-hero-banner-github.jpg)

[![CI](https://github.com/tigusigalpa/watchdog/actions/workflows/ci.yml/badge.svg)](https://github.com/tigusigalpa/watchdog/actions/workflows/ci.yml)
[![GitHub release](https://img.shields.io/github/v/release/tigusigalpa/watchdog)](https://github.com/tigusigalpa/watchdog/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Bash 4.3+](https://img.shields.io/badge/bash-4.3%2B-4EAA25?logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)

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
- `curl`, `flock`, GNU `timeout`/coreutils, and `unzip` for ZIP installation

On Debian or Ubuntu, install the system packages with:

```bash
sudo apt-get install bash curl util-linux coreutils unzip
```

Install `yq` v4 using its official package or release instructions. The Python
package with the same name is not compatible.

For example, on Ubuntu with Snap:

```bash
sudo snap install yq
yq --version  # Must report Mike Farah yq version v4.x.x
```

## Quick start

Download the stable `v1.0.3` source archive from GitHub:

```bash
curl -fL \
  https://github.com/tigusigalpa/watchdog/archive/refs/tags/v1.0.3.zip \
  -o watchdog.zip
unzip watchdog.zip
cd watchdog-1.0.3
```

Alternatively, clone the repository with Git:

```bash
git clone https://github.com/tigusigalpa/watchdog.git
cd watchdog
```

Install and configure the watchdog:

```bash
sudo install -d -m 0755 /opt/service-watchdog
sudo install -m 0755 service-watchdog.sh /opt/service-watchdog/
sudo install -m 0640 config.example.yaml /opt/service-watchdog/config.yaml
sudoedit /opt/service-watchdog/config.yaml
sudo /opt/service-watchdog/service-watchdog.sh -n
sudo /opt/service-watchdog/service-watchdog.sh
```

Or run `sudo ./install.sh` to verify dependencies, install the script and
example configuration, create runtime directories, install the systemd units,
and reload systemd. The installer preserves an existing configuration.

To test the development branch instead, clone the repository as shown above or
download [`main.zip`](https://github.com/tigusigalpa/watchdog/archive/refs/heads/main.zip).

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
examples. Additional ready-to-adapt configurations are available in the
[`examples`](examples) directory, including Docker Compose, systemd, combined
multi-service monitoring, and failure/recovery hooks.

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
service-watchdog.sh -V | --version
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
sudo install -d -m 0750 /var/log/service-watchdog
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

## Troubleshooting

### `yq: command not found` or unsupported `yq` version

Install [Mike Farah `yq` v4](https://github.com/mikefarah/yq). The unrelated
Python package named `yq` is not compatible. Verify the installed binary:

```bash
yq --version
```

### Configuration file permission denied

Keep the configuration readable by the account running the watchdog and
writable only by an administrator:

```bash
sudo chown root:root /etc/service-watchdog/config.yaml
sudo chmod 0640 /etc/service-watchdog/config.yaml
```

When running as a non-root service account, set an appropriate group instead of
weakening permissions for all users.

### Cron does not create its log

The shell opens redirection targets before it starts the watchdog. Create the
log directory before installing the crontab entry:

```bash
sudo install -d -m 0750 /var/log/service-watchdog
```

### Remediation command fails with permission denied

Run the watchdog under an account that can execute the configured action. For
Docker, verify socket/group access; for `systemctl`, use root's timer or a
narrowly scoped sudo/polkit rule. Do not make the configuration world-writable.

### A scheduled run is skipped

The watchdog intentionally skips a run when another instance holds the global
`flock` lock. Check whether a previous command is still running and review its
configured timeout before increasing the schedule interval.

### Understanding exit codes

- `0` means all selected targets were healthy and no remediation ran.
- `1` means a target was unavailable or remediation was attempted; this is an
  expected monitoring result.
- `2` means the watchdog encountered a configuration, dependency, or runtime
  error.

## Security notes

- Run with the least privileges required by remediation commands.
- Keep the configuration root-owned and not writable by the service account.
- Avoid putting passwords, tokens, or shell snippets in YAML.
- Commands are executed directly as argument arrays; no `eval` or `bash -c` is
  used for configured commands.
- Command output is truncated before it is written to the log.

## Testing

```bash
bash -n service-watchdog.sh install.sh tests/smoke.sh
shellcheck service-watchdog.sh install.sh tests/smoke.sh
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
