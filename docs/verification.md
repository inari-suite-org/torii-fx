# Verification on a real server

What was checked on a running FXServer, and what is still open. Server: `FXServer-master SERVER v1.0.0.36897 win32`
(artifact build 36897), Windows 11, local development server. The test resources are in
[`research/`](../research/README.md), so any result below can be reproduced on another build.

## Results

| Question | Result |
|---|---|
| Does `@provider/init.lua` run when the provider resource is stopped? | Yes. It ran inside the consumer with `provider state: stopped`, and shared scripts ran before server scripts although `server_script` was declared first (`provider-init > late_shared > server`). |
| What happens when the included file is missing? | FXServer prints `Failed to load script @provider/init.lua.` and **starts the resource anyway**. Injection through manifests fails open. |
| Can custom manifest keys (`torii_http`, ...) be read before a resource starts? | Yes, in `onResourceStarting`: counts and values were correct, undeclared keys returned 0, and no warning was printed for unknown keys. |
| Does `CancelEvent()` in `onResourceStarting` stop a resource? | Yes: `Couldn't start resource ...`, the state stayed `stopped`, none of its scripts ran. |
| How are natives loaded? | Lazily: `_G` has a metatable whose `__index` is a function; natives are absent until first access. |
| What do native stubs look like? | Lua functions whose chunk name is `@<NativeName>.lua` (for example `@PerformHttpRequestInternalEx.lua`), not `@citizen:/...`. |
| Invocation hashes | `GetHashKey` of the upper-snake native name, read from `natives_server.lua`: `PerformHttpRequestInternalEx` `0x6b171e87`, `PerformHttpRequestInternal` `0x8e8cc653`, `ExecuteCommand` `0x561c060b`, `SetHttpHandler` `0xf5c6330c`, `GetConvar` `0x6ccd2564`, `SaveResourceFile` `0xa09e7e7b`. The camel-case spelling gives a different, wrong hash. |
| Cross-resource writes | Denied by default (`SaveResourceFile` returns false, `io.open` for write fails), allowed with `add_filesystem_permission` in `server.cfg`. The command is refused once the server has finished its initial configuration. Build 36897 has this protection. |
| How far does `io.open` read? | Files of its own resource and of other resources through `@resource/file`. Bare relative paths, `../` paths and absolute host paths fail. |
| Cost of a wrapper | Direct native stub about 500 to 535 ns per call. Wrapper with a table lookup and varargs about 570 to 640 ns (+70 to +140 ns). Wrapper that also calls `debug.getinfo(2, "Sl")` about 1330 ns (+800 ns), so call sites are captured only when an event is logged. |
| Does `PerformHttpRequest` follow redirects? | Yes by default, including to another host name. `followLocation=false` returns the 302. |
| Where does the default come from? | `scheduler.lua` sets `followLocation = true`. The raw native called without the key does not follow. |
| Is there a limit on redirect hops? | No practical one: a page redirecting to itself produced about 6,000 requests in a few seconds before the call failed with status 0. |
| Does patching `debug.getupvalue` disturb the scheduler? | No. A resource raising errors from a thread, an event handler and a timeout, calling an export, and catching an error with `pcall` printed the same `SCRIPT ERROR` lines with and without torii. |
| End to end | `torii install`, a resource calling an approved host, an unknown host and `load`: in observe mode everything worked and was logged as `WOULD BLOCK`; `torii approve --from-logs` printed a diff; in enforce mode the approved host answered 200, the other was blocked (callback status 0), `load` worked because it was granted, and the declaration hashes computed in Lua and in Node agreed. |
| Does torii read URLs the way libcurl does? | Differential test (`research/url-differential/`): about 6,000 generated URLs over two seeds, mixing schemes, user info, IPv4 and IPv6 spellings, ports, encodings and noise characters. Whenever torii accepts a URL, curl 8.22 reads the same scheme, host and port: 0 divergences. The first run found one class of divergence, IPv6 addresses kept as written instead of in canonical form; it failed closed (it could only refuse), and torii now uses the RFC 5952 form curl prints. No request left the machine: curl's connections were diverted to a closed local port. |
| Demo | `demo/torii_demo_backdoor`: five attempts logged in observe mode, blocked in enforce mode, including the direct `Citizen.InvokeNative` call and the manifest rewrite. The manifest gate refused to start a resource without the torii line. See [demo.md](demo.md). |

## Not verified yet

* Resources protected by Cfx Asset Escrow (`.fxap`). The protocol is in [`research/README.md`](../research/README.md);
  it needs an escrowed resource owned by the tester.
* Behaviour on artifact builds other than 36897. Builds older than the introduction of `add_filesystem_permission`
  (December 2024) lack the cross-resource write protection torii relies on to protect its own files.
* Known libraries are described from their source at the commit shown in `cli/presets/known-resources.json`, not
  from running them.
