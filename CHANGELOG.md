# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.6] - 2026-08-15

### Added

- Built-in SMTP email notifications with YAML-configured connection settings,
  recipients, and failure/recovery templates.
- Transition-only delivery: one failure message per incident and one recovery
  message when the service becomes healthy again.
- Automated coverage for email delivery and duplicate suppression.

## [1.0.3] - 2026-08-15

### Added

- HTTP, TCP, and command-based health checks.
- Configurable retries, timeouts, remediation cooldowns, and post-action checks.
- Failure and recovery hooks with structured environment variables.
- Persistent service state and a global non-blocking execution lock.
- Dry-run and single-service modes.
- systemd service/timer units and cron documentation.
- Ready-to-adapt configurations in the `examples` directory.
- GitHub Actions smoke testing and ShellCheck validation.
- `-V` and `--version` options.

### Changed

- Improved installer dependency checks, runtime directory creation, and summary.
- Quick Start now uses the stable `v1.0.3` source archive.
- Expanded repository ignore rules and troubleshooting documentation.

[Unreleased]: https://github.com/tigusigalpa/watchdog/compare/v1.0.6...HEAD
[1.0.6]: https://github.com/tigusigalpa/watchdog/compare/v1.0.3...v1.0.6
[1.0.3]: https://github.com/tigusigalpa/watchdog/releases/tag/v1.0.3
