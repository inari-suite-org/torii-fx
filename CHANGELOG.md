# Changelog

All notable changes to torii. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the
project uses [semantic versioning](https://semver.org/).

## Unreleased — v0.2

Waits for a server with real players to run v0.1 in observe mode ([STATUS.md](STATUS.md)). Until then these changes
stay on the `v0.2` branch.

### Added

- `torii_dynamic_code 'files'`: `load` is allowed only on text exactly as `LoadResourceFile` returned it, which is what
  ox_lib's module loader needs, instead of the blanket grant. Text the resource wrote itself (`SaveResourceFile`, or
  anything read after an `io.open` write) is never trusted. The log records where each loaded text came from.
- Plain-language verdicts in `torii approve`: every proposed item is marked common, check or suspicious, with one
  sentence on what to do. Suspicious items are left out of `--write` unless `--include-suspicious`.
- `torii approve --ask`: one question per item that is not common, and a confirmation before writing.
- `torii exempt`: lists the JavaScript/C# resources torii cannot inspect, and exempts or un-exempts them.
- Read-only console commands for the server console and the txAdmin live console: `torii`, `torii review`,
  `torii explain <n>`. A summary at start and at most hourly, and a "ready for enforce" indicator.
- English and French messages for the server owner (`set torii_lang "fr"`).
- `torii simulate` (replay observe logs against a lockfile) and `torii explain` (why each event was blocked).
- Experiment 11 (who can run a restricted console command) and a console-check script for a development server.

### Changed

- The step-by-step guide uses `approve --ask`, `torii exempt` and the console review.

## [0.1.0] — 2026-10-08

First public release, **experimental**: tested on a development server only.

### Added

- Lua runtime guard injected with `shared_script '@torii/init.lua'`: HTTP natives, `Citizen.InvokeNative` by hash,
  `Citizen.LoadNative`, `load` (text only, bytecode always refused), `debug.getupvalue` hardening, manifest rewrites.
- Observe and enforce modes; lockfile granted by the admin, with the hash of the reviewed declaration; JSON-lines log
  without secrets; manifest gate and attestation in the core resource.
- Strict URL parser (every IPv4 and IPv6 spelling; local, private and link-local ranges always refused), checked
  against libcurl by differential testing.
- Node CLI without dependencies: `install`, `uninstall`, `status`, `approve --from-logs`, presets for well-known
  libraries (opt-in, origin-checked).
- Step-by-step guide for server owners, in English and French.

### Fixed

- The ox_lib preset only grants the read-only release-check paths, not the whole `api.github.com/repos/overextended`
  prefix, which also accepts issues and comments.

[0.1.0]: https://github.com/inari-suite-org/torii-fx/commits/main
