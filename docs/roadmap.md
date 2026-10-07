# Roadmap

What comes next, in the order we intend to do it, and why. None of this is in v0.1. Priorities change when users
tell us what hurts.

## Next: make the claims easy to check

| Item | Why |
|---|---|
| Run the research resources against a real FXServer on a schedule | torii depends on FXServer details (native hashes, stub names, redirect behaviour). A nightly job against the latest artifact would tell us the day one of them changes, instead of a user telling us. |
| Differential test of the URL parser against libcurl | the parser is deliberately stricter than curl, but any difference in how a URL is read is a possible bypass. Comparing the two on generated inputs finds the cases by machine instead of by imagination. |
| Windows job in CI | most FiveM servers run on Windows, and the CLI edits files and manifests. |
| Signed releases with build provenance | a security tool should let people verify what they download. |
| Test with an Asset Escrow resource | the one limit we mention without having measured it ([research/README.md](../research/README.md)). |

## Then: make it easier to live with

| Item | Why |
|---|---|
| `torii doctor` | one command that checks the artifact build, the `ensure` order, `add_filesystem_permission` and the lockfile, and says what is missing. |
| More presets | `oxmysql` aside (it is JavaScript), the common frameworks and inventories, each checked against its source ([presets.md](presets.md)). |
| Webhook alerts | being told about a block without watching the console. |
| Log rotation | the JSON-lines file grows forever. |
| Published npm package | `npx torii-fx` instead of `node cli/torii.mjs`. |
| txAdmin integration | coverage and pending approvals in the panel. |

## Later: widen what is covered

| Item | Why |
|---|---|
| Export and event filtering between resources | closes the "confused deputy" and exfiltration-through-another-resource gaps in the [threat model](threat-model.md). |
| Provenance for `load` | allow `load` only on text read from the resource's own files, so a library no longer needs a blanket `dynamic_code` grant. Hard with libraries that concatenate files. |
| Signed or chained lockfile | detect tampering with `policy.lock.json` by something that can write the folder. |
| Wildcard hosts | convenient, but widens the parser's attack surface: only with strict rules and tests. |
| Artifact-level mode | patching `scheduler.lua` would protect every resource without touching manifests. Unsupported by Cfx.re and overwritten by updates, so only ever opt-in. |
| A JavaScript runtime shim | the newest public backdoor family is JavaScript. Node has many more sinks than Lua, so this is a separate project with its own threat model. |
