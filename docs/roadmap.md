# Roadmap

v0.1 is frozen and experimental ([STATUS.md](../STATUS.md)). Until a server with real players has run it, the only
work on it is fixing reported bugs. Everything below is for later, in the order we intend to do it. Priorities change
when users tell us what hurts.

## Before leaving "experimental"

| Item | Why |
|---|---|
| Compatibility run on a development server | ox_lib, a framework and popular scripts under simulated load, observe then enforce, for hours: crashes, memory, blocking false positives. |
| Asset Escrow check | the one feasibility check still open ([research/README.md](../research/README.md)). |
| A server with real players in observe mode | the only way to learn how torii behaves with real traffic. Its log summary decides the v0.2 fixes. |

## v0.2 candidates

| Item | Why | State |
|---|---|---|
| `torii simulate` | replay observe-mode logs against a candidate lockfile: what enforce mode would block, before switching | written and tested, kept out of v0.1 |
| `torii explain` | why an event was blocked, and the exact lockfile line that would allow it | written and tested, kept out of v0.1 |
| `torii_dynamic_code 'files'` | `load` only on text exactly as read from resource files: what ox_lib users need, without the blanket grant. Texts the resource wrote itself are excluded | written and tested, kept out of v0.1 |
| Plain-language verdicts in `approve` | every proposed item is marked common, check or suspicious, with one sentence on what to do; suspicious items are left out of `--write` unless `--include-suspicious`. "Common" comes from audited presets and a short list of read-only destinations (`cli/presets/common-hosts.json`, additions by PR with a source) | written and tested, kept out of v0.1 |
| Read-only console commands | `torii`, `torii review`, `torii explain <n>` in the server console (txAdmin live console): what is waiting for a decision with the same verdicts, a summary at start and at most hourly, a "ready for enforce" indicator (3 days, a weekend, nothing pending), English and French messages | written and unit-tested, not yet run on a server |
| Console commands that change something (`allow`, `deny`, `mode`) | without Node on the server; first prove a script cannot type them itself (ACL on `ExecuteCommand`, `GetInvokingResource()` in the handler, txAdmin `consoleCommand` origin) | experiments planned |
| Signals about hosts in `approve` | look-alike names (edit distance), punycode, raw IP addresses, random-looking labels. Measured: 1 false positive on 50 common legitimate hosts, 9 of 12 suspicious names caught | written and tested, kept out of v0.1 |
| `torii doctor` | checks the artifact build, the `ensure` order, `add_filesystem_permission` and the lockfile | idea |
| Reachability audit | walk every object a resource can reach and prove none of the original natives is among them, instead of closing known bypasses one by one | idea |
| Statistical signature of `load` input | size, entropy, escape density: sort dynamic-code requests by how encoded they look, without storing the text | idea |
| Nightly run of `research/` against the latest artifact | FXServer details torii depends on can change | idea |
| Windows CI job, signed releases with provenance, npm package | trust and ease of installation | idea |
| Webhook alerts, log rotation, txAdmin integration | living with it day to day | idea |

## Later

| Item | Why |
|---|---|
| A per-resource network permission inside FXServer | proposed upstream, it would close every Lua bypass at once and cover JavaScript and C#; torii would be its prototype |
| Firewall rules generated from the lockfile | one source of truth for the in-VM layer and the operating system layer |
| Export and event filtering between resources | closes the "confused deputy" gaps in the [threat model](threat-model.md) |
| Signed lockfile, wildcard hosts, artifact-level mode | each has a cost; only with tests and on demand |
| JavaScript coverage | a separate project: Node has many more ways out than Lua |
