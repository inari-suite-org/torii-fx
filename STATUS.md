# Status

Last updated: 2026-10-08. Release label: **experimental**.

torii has only run on a development server with no players. Until a server with real players has run it in observe
mode, it stays experimental, observe mode stays the default, and the README says so.

| Criterion | State | Evidence and what is missing |
|---|---|---|
| Feasibility checks on a real FXServer | **in progress** | 7 of 8 checks done with written results ([docs/verification.md](docs/verification.md)), plus a differential test of the URL parser against libcurl. None of them invalidated the approach. Missing: the Asset Escrow check, which needs an escrow-protected resource ([research/README.md](research/README.md)). |
| v0.1 publishable | **done, to confirm** | Install: about 10 seconds of mechanical steps on a dev server (copy the folder, `torii install`, restart); not yet timed with someone who has never seen the project. README, MIT license, [example manifest and lockfile](examples/README.md), observe mode, 90 Lua specs and 29 CLI tests. CI runs are paused at the moment; the tests pass locally. |
| Compatibility on a development server | **blocking: not started** | To do: ox_lib, one framework (ESX or QBCore) and a few popular scripts, simulated load, observe then enforce, several hours, watching crashes, memory and blocking false positives. This will **not** say anything about behaviour with real players. |
| Limits documented | **done** | JavaScript and C# not covered ([README](README.md#limits), [threat model](docs/threat-model.md)); every bypass considered and its outcome in the [bypass table](docs/design.md#4-bypasses-considered). |
| Validation with real players | **not started** | Needs a server with players running torii in observe mode and sharing the log summary. Until then: experimental. |

## Scope

v0.1 is frozen. Anything else goes to [docs/roadmap.md](docs/roadmap.md); after v0.1, only reported bugs are fixed.
