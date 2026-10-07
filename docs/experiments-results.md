# Phase 1 experiment results

Server: `FXServer-master SERVER v1.0.0.36897 win32` (artifact build 36897), Windows 11, run 2026-10-07 on a local
dev server. Raw protocol: `experiments/README.md`. Exp 04 was deferred (see below) and exp 05 could not be run
(no escrow-protected resource available on the dev machine).

| # | Question | Result | Verdict |
|---|---|---|---|
| 01 | Does `@provider/init.lua` load with the provider stopped? | Yes. With the provider **stopped**, `init.lua` still ran inside the consumer (`provider state: stopped`). Order was `provider-init > late_shared > server` although `server_script` was declared first. | Confirmed |
| 01 | Provider missing | `Failed to load script @exp01_provider/init.lua.` is printed, the consumer **still starts** (`load order = late_shared > server`). | Confirmed: the manifest approach **fails open** |
| 01 | Side finding | `stop exp01_provider` also stopped the consumer (the `@` include creates a dependency), but `restart exp01_consumer` brought it back up with the provider stopped. | Note |
| 02 | Custom manifest keys readable in `onResourceStarting`? | Yes: `torii_http` count=2 with both values, `torii_dynamic_code` count=1, undeclared key count=0, `shared_script`/`server_script` listed. No warning for unknown keys. | Confirmed |
| 02 | `CancelEvent()` stops the start? | Yes: `Couldn't start resource exp02_victim.`, state `stopped` 2 s later, victim scripts never ran. | Confirmed |
| 03 | Natives mode | **Lazy mode** (`_G` has a metatable, `__index` is a function). Natives are absent before first access and appear after it. | Confirmed |
| 03 | Native stub chunk names | `@<NativeName>.lua` (e.g. `@PerformHttpRequestInternalEx.lua`), `what=Lua`. **They are not `@citizen:/…`.** The refusal rule planned for `debug.getupvalue` must therefore also cover this naming pattern, not only the `@citizen:/` prefix. | Changes the design |
| 03 | Invocation hashes | Hash = `GetHashKey` of the **upper-snake** native name. From `natives_server.lua`: `PerformHttpRequestInternalEx` = `0x6b171e87`, `PerformHttpRequestInternal` = `0x8e8cc653`, `ExecuteCommand` = `0x561c060b`, `SetHttpHandler` = `0xf5c6330c`, `GetConvar` = `0x6ccd2564`. The camel-case spelling gives a different, wrong hash. | Confirmed |
| 06 | Cross-resource writes without permission | `SaveResourceFile` own=ok, cross=**false**, `io.open` cross write=**false**. | Confirmed |
| 06 | With `add_filesystem_permission` in `server.cfg` | cross `SaveResourceFile`=ok, `io.open` write=ok (files created). | Confirmed |
| 06 | Permission added after boot | `Warning: add_filesystem_permission is only executable before the server finished execution.` and writes stay denied. | Confirmed. Build 36897 has the protection. |
| 07 | `io.open` reach | Own `@res/file`: OK. Another resource's `@res/file`: **OK (readable)**. Bare relative `canary.txt`, `../` relative and an **absolute host path** (`C:/…`, file existed): all **fail** with "No such file or directory". | Confirmed: reads go through the resource VFS only; other resources' files are readable (so `io.open` on `@other/…` is a data-exposure channel to log) |
| 08 | Wrapper overhead | Direct stub ≈ 500-535 ns/call; wrapper with table lookup + varargs ≈ 570-640 ns (about +70-140 ns); wrapper that also calls `debug.getinfo(2,"Sl")` ≈ 1330 ns (about +800 ns). | Confirmed: a lookup wrapper is cheap; call-site capture only on logged events, never on the fast path |
| 10 | Redirects | `PerformHttpRequest` with default options and `followLocation=true` follow redirects (200 FINAL); `followLocation=false` returns 302. A redirect to another hostname (`/cross` → `localhost`) **is followed**. | Confirmed: first-URL checks alone are bypassable |
| 10 | Raw native without the key | Only `/start` was requested; `/final` was **not** fetched. The native's own default is "do not follow"; it is `scheduler.lua` that sets `followLocation = true` by default. | Confirmed |
| 10 | Redirect cap | `/loop` (redirects to itself) produced about 6,000 requests in a few seconds, then failed with status 0. There is **no small hop cap**; the request ends by timeout. | Confirmed |

## Resolved during the build

- **Exp 04** (does the `debug.getupvalue` patch break the scheduler?): with the final guard installed, a resource
  that throws errors from a thread, an event handler and a timeout, calls an export, and catches an error with
  `pcall`, produced exactly the same `SCRIPT ERROR` lines as the same resource without torii. Exports, events and
  threads kept working. (Live run on build 36897; the unit tests in `spec/guard_spec.lua` prove the refusal itself.)
- **End to end** (build 36897): `torii install` on a resources folder, a resource calling `https://example.com/`,
  a fake host and `load`, observe mode (all logged as `WOULD BLOCK`, everything still works), `torii approve
  --from-logs` (diff, then `--write`), lockfile trimmed by hand, enforce mode: approved host answered 200, the other
  host was blocked and the callback saw status 0, `load` worked because it was granted, and no
  `declaration_changed` report appeared (the Lua and Node declaration hashes agree on a real manifest).
- **Demo** (`demo/torii_demo_backdoor`): in observe mode the 5 attempts are logged; in enforce mode they are
  blocked (including the direct `Citizen.InvokeNative` call and the manifest rewrite); the manifest gate cancels
  the start of a resource without the torii line (`Couldn't start resource`); the JSON-lines log is written
  through `io.open(..., 'a')` from the core.

## Not run

- **Exp 05** (escrow-protected resource accepts the injected line): needs an escrowed resource. Still open.

## Consequences for the design

1. **Fails open** is confirmed, so the manifest gate on `onResourceStarting` (which works, exp 02) is mandatory.
2. Policy parsing can read `torii_*` keys of a resource before it starts (exp 02).
3. In `enforce`, HTTP requests must set `followLocation=false` (or revalidate each hop). Default behaviour of
   `PerformHttpRequest` follows redirects across hosts, with no practical cap.
4. Hashes to filter in `Citizen.InvokeNative` come from upper-snake names (table above).
5. The upvalue-refusal rule must match both `@citizen:/…` and lazy-native stub chunk names (`@<Name>.lua`).
6. Wrappers must not capture call sites on the fast path (+800 ns/call).
7. Torii's own folder is protected from other resources on this build, but the protection is configured only
   in `server.cfg` before boot (exp 06): torii must warn when the artifact is older than the build that introduced it.
