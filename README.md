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
- Built-in SMTP email alerts with YAML-configured templates and recipients
- Persistent state and transition-only hooks
- Global non-blocking lock to prevent overlapping runs
- Dry-run and single-service modes
- Strict YAML validation and bounded command execution

## Requirements

- Linux and Bash 4.3 or newer
- [Mike Farah `yq` v4](https://github.com/mikefarah/yq)
- `curl`, `flock`, GNU `timeout`/coreutils (including `base64`), and `unzip`
  for ZIP installation

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

Download the stable `v1.0.6` source archive from GitHub:

```bash
curl -fL \
  https://github.com/tigusigalpa/watchdog/archive/refs/tags/v1.0.6.zip \
  -o watchdog.zip
unzip watchdog.zip
cd watchdog-1.0.6
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
2. If every attempt fails, the target changes to `unavailable` and transition
   notifications run once.
3. `actions.commands` run sequentially when the cooldown allows remediation.
4. After `verify_after` seconds, the complete check is repeated.
5. A successful verification changes the target back to `healthy` and sends one
   recovery notification.

Set `cooldown: 0` to allow an action on every scheduled run. Commands stop at
the first failure, matching shell `&&` semantics. A continuing outage can retry
remediation after its cooldown, but it does not repeat the failure email.

### Built-in SMTP email

Built-in email is sent only on state transitions:

- `unknown/healthy → unavailable`: one failure message before remediation;
- repeated `unavailable` checks: no duplicate failure messages;
- `unavailable → healthy`: one recovery message after a successful check.

Set `enabled: false` to disable built-in email without removing its settings.
The following example uses authenticated SMTP over implicit TLS on port `465`:

```yaml
notifications:
  email:
    enabled: true
    smtp:
      url: smtps://smtp.example.com:465
      from: watchdog@example.com
      username: watchdog@example.com
      password_env: WATCHDOG_SMTP_PASSWORD
      tls_required: true
      insecure_skip_verify: false
      timeout: 30
    recipients:
      - administrator@example.com
      - on-call@example.com

    failure:
      subject: "[watchdog] {{service}} is unavailable"
      body: |-
        Watchdog detected a service availability problem.

        Service: {{service}}
        Time: {{timestamp}}
        Check type: {{check_type}}
        Detail: {{detail}}
        HTTP status: {{http_status}}
        Check exit code: {{check_exit}}
        Remediation: {{action_status}}

        This message is sent once and will not repeat until recovery.

    recovery:
      subject: "[watchdog] {{service}} recovered"
      body: |-
        Watchdog confirmed that the service is available again.

        Service: {{service}}
        Time: {{timestamp}}
        Check type: {{check_type}}
        Detail: {{detail}}
        Remediation: {{action_status}}
```

SMTP fields:

- `url` is the SMTP endpoint. Use `smtps://host:465` for implicit TLS or
  `smtp://host:587` for SMTP upgraded with STARTTLS.
- `from` is the envelope sender and the value of the email `From` header.
- `username` is optional for SMTP servers that do not require authentication.
- `password_env` names the environment variable containing the password. The
  variable itself, not its value, is written to YAML.
- `password` is an optional inline alternative to `password_env`. Do not set
  both fields; `password_env` is recommended.
- `tls_required: true` requires a secure SMTP connection. Keep this enabled for
  Internet-facing SMTP servers.
- `insecure_skip_verify: false` verifies the SMTP server certificate. Set it to
  `true` only for a trusted server with a deliberately self-signed certificate.
- `timeout` limits both connection establishment and the complete SMTP request
  and must be between 1 and 60 seconds.
- `recipients` must contain at least one address. Every notification is sent to
  every address in this list.

For STARTTLS on port `587`, only the URL needs to change:

```yaml
notifications:
  email:
    enabled: true
    smtp:
      url: smtp://smtp.example.com:587
      from: watchdog@example.com
      username: watchdog@example.com
      password_env: WATCHDOG_SMTP_PASSWORD
      tls_required: true
      insecure_skip_verify: false
      timeout: 30
    recipients:
      - ops@example.com
    failure:
      subject: "[watchdog] Problem with {{service}}"
      body: "Check failed: {{detail}}"
    recovery:
      subject: "[watchdog] {{service}} is healthy"
      body: "The service recovered at {{timestamp}}."
```

`failure.subject` and `recovery.subject` must be single-line strings. Their
`body` fields can be either short quoted strings or YAML multiline blocks.
Messages are generated as UTF-8, so templates can contain non-ASCII text:

```yaml
failure:
  subject: "[watchdog] Сервис {{service}} недоступен"
  body: |-
    Обнаружена проблема с сервисом {{service}}.

    Время: {{timestamp}}
    Проверка: {{check_type}}
    Описание: {{detail}}
    Статус исправления: {{action_status}}

recovery:
  subject: "[watchdog] Сервис {{service}} восстановлен"
  body: |-
    Сервис снова доступен.

    Время: {{timestamp}}
    Статус исправления: {{action_status}}
```

Available template variables:

- `{{service}}`: service name from `services[].name`;
- `{{event}}`: `failure` or `recovery`;
- `{{timestamp}}`: local date, time, and UTC offset at message creation;
- `{{check_type}}`: `http`, `tcp`, or `command`;
- `{{detail}}`: diagnostic message from the most recent check;
- `{{http_status}}`: HTTP response code, or `n/a` for another check type;
- `{{check_exit}}`: check command exit code, or `n/a` when unavailable;
- `{{action_status}}`: remediation state such as `pending`, `cooldown`,
  `not-configured`, `successful`, or `not-required`.

For the included systemd unit, store the password in its optional environment
file instead of YAML:

```bash
sudo install -m 0600 /dev/null /etc/service-watchdog/environment
sudoedit /etc/service-watchdog/environment
sudo chmod 0600 /etc/service-watchdog/environment
```

Add the variable named by `password_env` to that file:

```text
WATCHDOG_SMTP_PASSWORD=replace-with-the-real-password
```

The included systemd unit reads this file automatically. Restarting the timer
is not required after changing the password; the environment file is read each
time the one-shot service starts. Test the settings by manually starting the
service and then inspecting its log:

```bash
sudo systemctl start service-watchdog.service
sudo journalctl -u service-watchdog.service -n 50 --no-pager
sudo tail -n 50 /var/log/service-watchdog/service-watchdog.log
```

Email is emitted only when a configured service changes state. Starting the
service while every target remains healthy validates the configuration but does
not send a test message.

When running from root's crontab instead of systemd, the password can be set as
a crontab environment variable above the scheduled command:

```cron
WATCHDOG_SMTP_PASSWORD=replace-with-the-real-password

* * * * * /opt/service-watchdog/service-watchdog.sh -c /etc/service-watchdog/config.yaml >> /var/log/service-watchdog/cron.log 2>&1
```

The less secure `smtp.password` YAML field is supported for environments where
an external secret cannot be provided:

```yaml
smtp:
  url: smtps://smtp.example.com:465
  from: watchdog@example.com
  username: watchdog@example.com
  password: "replace-with-the-real-password"
  tls_required: true
```

Do not combine `password` and `password_env`. See
[`examples/smtp-email.yaml`](examples/smtp-email.yaml) for a complete example.
If delivery fails, the error is logged; the state transition is still recorded
so the watchdog does not flood recipients with repeated attempts. A successful
SMTP request is written to the operational log as `result=email-sent`; a failed
request is written as `result=email-failed`.

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

Keep hook secrets outside YAML. Notification scripts can read credentials from
a root-owned environment file or secret manager.

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
- Prefer `notifications.email.smtp.password_env` over an inline SMTP password.
- Commands are executed directly as argument arrays; no `eval` or `bash -c` is
  used for configured commands.
- Command output is truncated before it is written to the log.

## Testing

```bash
bash -n service-watchdog.sh install.sh tests/smoke.sh
bash -n tests/email-notifications.sh
shellcheck service-watchdog.sh install.sh tests/smoke.sh tests/email-notifications.sh
bash ./tests/smoke.sh
bash ./tests/email-notifications.sh
```

The smoke test starts a local HTTP server and verifies both the healthy path and
the remediation path.

## License

MIT

## Author

[Igor Sazonov](https://github.com/tigusigalpa) —
[sovletig@gmail.com](mailto:sovletig@gmail.com)

Project repository: [github.com/tigusigalpa/watchdog](https://github.com/tigusigalpa/watchdog)
