# Research harness

Small resources used to check, on a real FXServer, the assumptions torii depends on. Results for build 36897 are in
[docs/verification.md](../docs/verification.md). Run them again after a major artifact update: if a result changes,
torii's design notes need updating.

Use a **development** server. Copy the folders you need into `resources/`. Commands in italics are typed in the server
console. Nothing here uses the network except `exp10`, which talks to a Python server on `127.0.0.1` only.

| Folder | Question | How to run | A result that breaks an assumption |
|---|---|---|---|
| `exp01_*` | Does `@provider/init.lua` run when the provider is stopped or missing, and in which order? | `ensure exp01_provider`, `ensure exp01_consumer`; then `stop exp01_provider`, `restart exp01_consumer`; then rename the provider folder, `refresh`, `restart exp01_consumer` | the consumer does not start when the provider is missing (then injection would not fail open) |
| `exp02_*` | Can custom manifest keys be read in `onResourceStarting`, and does `CancelEvent()` stop the start? | `ensure exp02_core`, `ensure exp02_victim`; then `set exp02_cancel 1` and `ensure exp02_victim` again | counts are 0 before start, or the victim still starts |
| `exp03_natives` | Lazy or full natives, how stubs are named, which hashes | `ensure exp03_natives`, then search the artifact's `citizen/scripting/lua/` for each native name | stub chunk names are not `@Name.lua` |
| `exp06_*` | Are cross-resource writes denied? | `ensure exp06_target`, `ensure exp06_writer`, *exp06_write*; then add `add_filesystem_permission exp06_writer write exp06_target` to `server.cfg` before the `ensure` lines and run it again | writes succeed without the permission |
| `exp07_ioread` | How far does `io.open` read? | create a harmless file containing `CANARY-OK`, `ensure exp07_ioread`, *exp07_read <path>* for each path to test | an absolute host path becomes readable |
| `exp08_bench` | Cost of a wrapper layer | `ensure exp08_bench`, *exp08_bench 1000000* twice, ignore the first run | a simple wrapper costs several microseconds per call |
| `exp10_redirect` | Does the HTTP native follow redirects? | in `exp10_redirect/`: `python redirect_server.py`; then `ensure exp10_redirect`, *exp10_run*, *exp10_raw* | redirects are no longer followed by default |

None of these resources prints file contents, secrets or convar values.

## URL parser against libcurl

`url-differential/` generates URLs and compares how torii's parser and curl read them (scheme, host, port). It needs Lua 5.4 and curl 8.1 or later, and sends nothing over the network: curl's connections go to a closed local port.

```bash
node research/url-differential/run.mjs 3000 20261008   # count, seed
```

It exits with an error if torii accepts a URL that curl reads differently.

## Asset Escrow (not yet verified)

Needs a resource protected by Cfx Asset Escrow that you own, on a server whose license belongs to the same Cfx
account.

1. Back up its `fxmanifest.lua`.
2. Add `shared_script '@exp01_provider/init.lua'` as the first script line.
3. `ensure exp01_provider`, then `restart <that resource>`.
4. Expected if torii can protect escrowed resources: the line
   `[exp01] provider init.lua runs inside resource "<that resource>"` appears and the resource works.
5. A refusal, an escrow error, or no output means the manifest approach cannot cover escrowed resources.

Please report the result (build number, outcome) in an issue.
