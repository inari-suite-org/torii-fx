# Status

Last updated: 2026-10-08. Release label: **experimental**.

torii has only run on a development server with no players. Until a server with real players has run it in observe
mode, it stays experimental, observe mode stays the default, and the README says so.

| Criterion | State | Evidence and what is missing |
|---|---|---|
| Feasibility checks on a real FXServer | **in progress** | 7 of 8 checks done with written results ([docs/verification.md](docs/verification.md)), plus experiment 11 (console commands), a differential test of the URL parser against libcurl and one of the CLI and console verdicts. None of them invalidated the approach. Missing: the Asset Escrow check, which needs an escrow-protected resource ([research/README.md](research/README.md)). |
| Publishable | **done, to confirm** | README, step-by-step guide in English and French, MIT license, [example manifest and lockfile](examples/README.md), observe mode by default, 143 Lua specs and 48 CLI tests. Install not yet timed with someone who has never seen the project. CI runs are paused at the moment; the tests pass locally. |
| Compatibility on a development server | **done** | ox_lib 3.40.0, oxmysql 2.14.3, qb-core, qb-weathersync, qb-smallresources, ox_target 1.18.1, pma-voice and a synthetic load (`research/compat/`). Long run on 2026-10-08: 2 h in observe mode, then 3 h in enforce mode after `approve --from-logs --use-presets`. No script error, no SQL or HTTP failure over about 250,000 load cycles, process memory went down (142 to 107 MB), and the only block in enforce mode was the unapproved host the test sends on purpose. Findings: every resource that includes `@ox_lib/init.lua` needs dynamic code, and the narrow `'files'` level of v0.2 is enough for it (checked in observe and in enforce mode); the log cut GitHub version-check paths too short (fixed in v0.2). ESX was not part of the run. This says **nothing** about behaviour with real players. |
| Limits documented | **done** | JavaScript and C# not covered ([README](README.md#limits), [threat model](docs/threat-model.md)); every bypass considered and its outcome in the [bypass table](docs/design.md#4-bypasses-considered). |
| Validation with real players | **not started** | Needs a server with players running torii in observe mode and sharing the log summary. Until then: experimental. |

## Scope

v0.2 (verdicts, the narrow `'files'` level, console review, `approve --ask`, `torii exempt`) joins `main` once it has
run on the development server, so that the first tester gets the version meant for beginners. Commands that change
grants from the console wait for their design to be written and tested. Anything else goes to
[docs/roadmap.md](docs/roadmap.md).
