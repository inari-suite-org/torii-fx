# torii - Phase 1 experiments

Minimal test resources that turn the **[A]** assumptions of `docs/feasibility.md` §7 into **[V]**.
Run them on a **dev server only**. They use no network (except exp10, localhost only), write nothing
outside their own folders (except exp06, which is the point of that test) and never print file contents.

Setup: copy the `exp*` folders you need into `resources/`. Commands marked *(console)* are typed in the
server console (they are registered as restricted commands).

Send me the console output for each experiment, plus the artifact build (`version` in the console).

---

## exp01 - Does `@provider/init.lua` load when the provider is stopped or missing? (§7.1)

Also checks the load order claim: shared scripts run before server scripts, whatever the manifest order.

| | |
|---|---|
| Run A | `ensure exp01_provider` then `ensure exp01_consumer` |
| Run B | `stop exp01_provider` then `restart exp01_consumer` |
| Run C | rename the folder `exp01_provider` to `exp01_provider_off`, `refresh`, then `restart exp01_consumer` |
| Observe | the `[exp01]` lines; any `Failed to load script` message; whether "consumer started" still appears |
| **A is valid if** | order is `provider-init > late_shared > server` (shared before server although `server_script` is declared first) |
| **B is valid if** | `provider-init` still appears (the included file does not need the provider to be started) |
| **C** | expected: an error/warning about the missing script **and** the consumer still starts. If the consumer does NOT start, the "fails open" claim in §1.2 is wrong (good news for us) - tell me. |

## exp02 - Custom manifest keys, metadata before start, and `CancelEvent` (§7.2)

| | |
|---|---|
| Run A | `ensure exp02_core`, then `ensure exp02_victim` |
| Run B | `stop exp02_victim`, `set exp02_cancel 1`, `ensure exp02_victim` |
| Observe | the `[exp02]` lines; any console warning about unknown manifest keys; whether `victim server.lua ran` appears; the "2s later" state |
| **Valid if** | in `onResourceStarting`, `torii_http` has count=2 with the two values, `torii_dynamic_code` count=1, `torii_not_declared` count=0, `shared_script` lists `shared.lua`; no warning for custom keys; in run B the victim does **not** run and the 2s state is not `started` |
| **Invalid if** | counts are 0 before start (metadata unavailable → the manifest gate needs another approach), or the victim still starts after `CancelEvent()` |

## exp03 - Natives mode, stub origin, hash spellings (§7.3)

| | |
|---|---|
| Run | `ensure exp03_natives` |
| Observe | the `_G has a metatable` line; for each name, `rawget before/after` and `source` |
| Reads | metatable present + `rawget before=nil, after=function` → lazy natives mode. No metatable → full natives file mode. The `source` column tells me how native stubs are named in this mode (I need it to write the policy for phase 1). |
| Hash | the real invocation hash must come from the artifact itself. Search the artifact folder `citizen/scripting/lua/` for the native name and send me the matching line(s): `findstr /s /i "PerformHttpRequestInternalEx" "<artifact>\citizen\scripting\lua\*.lua"` (run it for `ExecuteCommand`, `SetHttpHandler` and `GetConvar` too; the file may be absent in lazy mode, then tell me). Compare with the `GetHashKey` candidates printed by the test. |

## exp04 - Does patching `debug.getupvalue` break the scheduler? (§7.4)

**Deferred to the wrapper step.** The side effects of patching `debug.getupvalue` (stack traces, boundaries
in `scheduler.lua`) and the proof that `@citizen:/…` functions are refused cannot be tested without writing
the patch itself, so they will be implemented together with their automated test right after your results.
Nothing to run now. One thing to note from exp03: the stub source names decide which prefixes the refusal
rule must cover, so exp03's output is the input for that test.

## exp05 - Escrowed (Cfx Asset Escrow) resources accept the injected line? (§7.5)

No code needed; it uses `exp01_provider`.

| | |
|---|---|
| Run | Take one **escrow-protected** resource you own (back it up first). Add as the first script line of its `fxmanifest.lua`: `shared_script '@exp01_provider/init.lua'`. Then `ensure exp01_provider`, `restart <that_resource>`. |
| Observe | whether the resource starts; whether the `[exp01] provider init.lua runs inside resource "<that_resource>"` line appears; any escrow/signature error |
| **Valid if** | the line appears and the resource works |
| **Invalid if** | the manifest edit is rejected, the resource refuses to start, or the line never appears. Then a large share of paid resources cannot be covered by the manifest approach. |
| Cleanup | restore your backup of the manifest |

## exp06 - Artifact build and the cross-resource write protection (§7.6)

| | |
|---|---|
| Run A | *(console)* `version` (send me the output), `ensure exp06_target`, `ensure exp06_writer`, `exp06_write` |
| Run B | add to `server.cfg` **before** the `ensure` lines: `add_filesystem_permission exp06_writer write exp06_target`; restart the server; `exp06_write` |
| Run C | *(console, server already running)* `add_filesystem_permission exp06_writer write exp06_target` |
| Observe | the `[exp06]` line; presence of the `from_writer_*.txt` files in `exp06_target/`; the message printed in run C |
| **Valid if** | run A: `own=true`, `cross=false`, `io.open cross write=false`; run B: both cross writes succeed; run C: a warning saying the command is only executable before the server finished initial configuration |
| **Invalid if** | cross writes succeed in run A → your artifact predates the protection (that is the answer I need for the version check). Tell me the build number. |
| Cleanup | delete `own.txt` and `from_writer_*.txt`; remove the `add_filesystem_permission` line |

## exp07 - How far can `io.open` read? (§7.7)

Prints only success/failure and whether the file starts with `CANARY`. Create harmless canary files only.

| | |
|---|---|
| Prepare | create `C:\torii_canary\canary.txt` (Linux: `/tmp/torii_canary/canary.txt`) containing `CANARY-OK`. `ensure exp07_ioread` |
| Run | *(console)* `exp07_read @exp07_ioread/canary.txt` · `exp07_read canary.txt` · `exp07_read ../exp07_ioread/canary.txt` · `exp07_read C:/torii_canary/canary.txt` (or the Linux path) · `exp07_read @exp06_target/fxmanifest.lua` (a file of another resource) |
| Observe | OK/FAILED and the error text for each |
| **Reads** | own-resource `@` path should work. Whether absolute host paths and other resources' files are readable decides how much `io.open` must be policed in v0.1 (it matters for reading secrets such as the server config). Do NOT test against real secret files. |

## exp08 - Overhead of a wrapper layer (§7.8)

| | |
|---|---|
| Run | `ensure exp08_bench`, then *(console)* `exp08_bench 1000000` (twice, ignore the first run) |
| Observe | three ns/call figures: direct stub, wrapper with table lookup, wrapper that also captures the call site |
| **Valid if** | the lookup wrapper adds well under ~1 µs per call. Call-site capture is expected to be much slower, which is why the design only captures it when a decision is logged, never on the fast path. |
| **Invalid if** | even the simple wrapper costs several µs per call: then interception of every native is too heavy and we restrict wrapping to the sensitive natives only. |

## exp10 - Does the HTTP native follow redirects? (§3 / your addition 3)

Localhost only; requires Python 3.

| | |
|---|---|
| Run | in a terminal: `python redirect_server.py` (from `exp10_redirect/`). In the server console: `ensure exp10_redirect`, `exp10_run`, then `exp10_raw` |
| Observe | the `[exp10]` status lines and the python console `HIT` lines |
| **Valid if (redirects followed by default)** | `/start (default options)` and `followLocation=true` return `status=200 body=FINAL`; `followLocation=false` returns `status=302`; `/loop` ends with an error/non-200 status (tells us a redirect cap exists). Then a policy that checks only the first URL can be bypassed by redirects, and enforce mode must force `followLocation=false` or check each hop. |
| `/cross` | a `HIT localhost:8099 /final` line proves a redirect to a different hostname is followed. |
| `exp10_raw` | a `/final` HIT means the raw native follows redirects even without the key; no `/final` HIT means the native's own default is "no follow" and only the Lua wrapper in `scheduler.lua` turns it on. |

---

## Results template

```text
Artifact build:
exp01 A/B/C:
exp02 A/B:
exp03:
exp05:
exp06 A/B/C:
exp07:
exp08:
exp10:
```
