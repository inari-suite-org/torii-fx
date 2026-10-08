# Design notes

How torii works inside FXServer, what it can intercept, what a hostile resource can try, and the choices that
follow. Everything here was read in the FXServer and Cfx Lua sources or measured on a real server (see
[verification.md](verification.md) for the measurements).

Sources, pinned: `citizenfx/fivem@e34d12c` (2026-09-30) and `citizenfx/lua@4b086dc` (branch `luaglm-548`).
Paths below are relative to those repositories.

## 1. Each resource has its own Lua state

`LuaScriptRuntime` is created per resource and owns its `lua_State`
(`code/components/citizen-scripting-lua/src/LuaScriptRuntime.cpp`, `Create()`). A state boots in this order:

1. standard libraries: base, `table`, `string`, `math`, `coroutine`, `utf8`, `debug`, and on the server the Cfx
   versions of `io` and `os`, plus `msgpack` and `json`;
2. the `Citizen` table (`InvokeNative`, `LoadNative`, `CreateThread`, ...);
3. the natives, either a full `natives_*.lua` file or the lazy `natives_loader.lua`;
4. `deferred.lua`, `scheduler.lua`, `graph.lua` from `citizen:/scripting/lua/`;
5. `dofile` and `loadfile` are set to `nil`, `print` and `require` are replaced by C functions.

Consequences:

* A resource cannot see or change the globals of another. They only share events, exports (built on events),
  function references, commands, convars, state bags, KVP and the file system.
* **A torii "core" resource cannot intercept calls made inside other resources.** The guard has to run inside each
  protected state.

## 2. Running before the resource's own code

`ResourceScriptingComponent.cpp` loads all `shared_script` entries first, then all `server_script` entries, each
list in manifest order. So `shared_script '@torii/init.lua'` placed first is the first piece of resource code to run
in that state, wherever `server_script` sits in the manifest. Only the system files above run earlier, and they come
from the server artifact, not from the resource.

* `@other/file.lua` is resolved as a file of another resource and runs in the including resource's state. This is how
  `@ox_lib/init.lua` works.
* If the included file cannot be loaded, FXServer prints `Failed to load script ...` and **starts the resource
  anyway**. Injection through manifests fails open, so torii adds a check at start (section 6).
* There is no convar, preload hook or `package.preload` to inject code into every resource: `package` is not opened,
  and `require` only knows `lmprof` and `glm`.

| Way to protect every resource | Result |
|---|---|
| A convar or preload script | does not exist |
| A guard resource started first | cannot reach other states |
| `shared_script '@torii/init.lua'` in each manifest | works, and is what torii uses |
| Patching `citizen/scripting/lua/scheduler.lua` in the artifact | would work for every resource, but is unsupported and overwritten by each artifact update |

## 3. What can be intercepted

A Lua function can be replaced, but the C function behind it stays reachable from any reference kept elsewhere.
The question for each target is whether every reference reachable from resource code can be replaced.

Facts that shape the whole list:

* Natives are resolved lazily through a metatable on `_G` whose `__index` calls `Citizen.LoadNative(name)` and caches
  the result with `rawset` (`data/shared/citizen/scripting/lua/natives_loader.lua`). Native stubs are compiled with a
  private environment that holds the original `Citizen.InvokeNative` as `_in`.
* `require(name)` returns `registry._LOADED[name]`, so `require('debug')` returns the original library table.
  Libraries must be patched **in place**, never replaced.
* `scheduler.lua` captured `debug`, `Citizen` and `InvokeNative` in locals before any resource code runs. They are
  the same tables, so in-place patches are seen by the scheduler too.

| Target | What it gives an attacker | Handling |
|---|---|---|
| `PerformHttpRequest`, `PerformHttpRequestInternal[Ex]` | outbound HTTP (C2, exfiltration) | wrapped on `_G`; the scheduler calls the global at call time |
| `Citizen.InvokeNative(hash, ...)` | any native by hash | wrapped in place; the hash is normalised the way `lua_tointeger` does |
| `Citizen.LoadNative(name)` | a fresh unwrapped stub | wrapped in place, returns our wrapper for protected names |
| `load` | dynamic code | wrapped; text mode forced (`LUA_NO_BYTECODE` is not set in the Cfx build) |
| `dofile`, `loadfile` | file-based code execution | removed by FXServer |
| `SaveResourceFile` | file writes | cross-resource writes already denied by FXServer; torii also guards manifest rewrites |
| `LoadResourceFile` | reads any resource's files | no permission check in FXServer; logged at most |
| `io`, `os` (Cfx versions) | files, process | `os.execute` always fails, `os.getenv` answers only `os`, `io.popen` accepts only `dir` and `ls`, writes use the same permission check |
| `debug` | recover originals from wrappers | Cfx builds Lua with `LUA_SANDBOX`: only `getinfo`, `getmetatable`, `setmetatable`, `getupvalue`, `traceback` remain. `getupvalue` is the main tool for bypasses, so torii patches it |
| `ExecuteCommand` | console commands | runs as principal `resource.<name>` and needs the ACE `command.<name>`; torii logs it |
| `GetConvar` | read secrets | logged by name for secret-looking convars |
| `SetHttpHandler` | inbound HTTP endpoint | logged |

## 4. Bypasses considered

Attacker model: controls the Lua code and manifest of one resource, runs after `init.lua` in the same state, and
knows how torii works.

| Attempt | Outcome |
|---|---|
| call the HTTP native by hash through `Citizen.InvokeNative` | blocked: `InvokeNative` is wrapped and filtered by hash |
| `Citizen.LoadNative` to obtain a fresh stub | blocked: returns the wrapper |
| read the original `_in` from any native stub through `debug.getupvalue` | blocked: refused for `@citizen:/...` and `@Name.lua` chunks and for torii's own functions |
| `require('debug')`, `require('io')` for untouched libraries | blocked: libraries are patched in place |
| `load` of a binary chunk (memory corruption, escape from the Lua VM) | blocked: binary chunks refused in every mode |
| table with metamethods answering differently to the check and to the native | blocked: the request is copied with `rawget`, each field read once |
| an approved host that redirects elsewhere | blocked: redirects are not followed unless granted |
| drop the torii line from the manifest at run time | blocked: manifest rewrites through `SaveResourceFile` are refused |
| ship without the torii line | detected by the manifest gate at start |
| write the payload in JavaScript or C# | **not covered**: flagged, not inspected |
| harmful logic needing neither network nor `load` | **not covered** |
| exfiltrate through client events or another resource's exports | **not covered** |
| detect torii and stay dormant | not preventable; the resource does nothing while torii is present |

The full list of what torii stops, reports and cannot see is in [threat-model.md](threat-model.md).

## 5. Other runtimes

* **JavaScript.** Since early 2026 FXServer installs a Node permission handler covering the file system, child
  processes, worker threads and WASI (`code/components/citizen-scripting-node/src/NodeScriptRuntime.cpp`). Network
  access is not in that list, and `eval` and `new Function` are explicitly allowed. A JavaScript backdoor can still
  contact a host and run downloaded code. The most recent public family (Blum panel loader, reported July 2026) is
  JavaScript, so a Lua-only tool must say so loudly.
* **C#.** Full .NET class library, so sockets and HTTP are available. Not studied in the source.
* What torii does about it today: the manifest gate lists resources with `.js` or `.dll` server scripts and, in
  enforce mode, refuses them unless the admin exempts them on purpose.

## 6. Architecture

1. **`torii/init.lua`** runs in every protected state. It captures the originals, reads the approved policy for the
   resource, installs the wrappers and patches the libraries in place, then reports through the core.
2. **`torii` core resource** (own state): manifest gate on `onResourceStarting`, attestation check after start,
   JSON-lines log writer, console alerts, rate limiting, coverage report.
3. **CLI** (outside the server): `install`, `uninstall`, `status`, `approve`.

Choices made:

| Question | Decision | Why |
|---|---|---|
| Where do permissions live? | the manifest **asks**, an admin-owned lockfile **grants**, with the hash of the reviewed declaration | a hostile manifest can request its own command-and-control host; only the lockfile is trusted |
| `load` policy | a per-resource grant `dynamic_code`: `'files'` (only text exactly as `LoadResourceFile` returned it, minus anything the resource wrote) or full; bytecode never | chunk names such as `@@ox_lib/...` can be reproduced by any code that calls `load`, so a name-based exception can be forged; the identity of the text itself cannot |
| CLI language | Node.js with no dependencies | quick to test, no runtime beyond what server admins usually have |
| Injection | a manifest line, plus a check at start | supported by Cfx, reversible, and fails visibly instead of silently |
| HTTP redirects | not followed in enforce mode unless granted | `PerformHttpRequest` follows redirects across hosts by default, with no practical hop limit |
| Cost | wrap only sensitive natives, never capture the call site on the fast path | measured: about 70 to 140 ns per wrapped call, about 800 ns more to capture `file:line` |

## 7. Open questions

* Resources protected by Cfx Asset Escrow (`.fxap`) have not been tested with the manifest edit.
* The URL parser is stricter than libcurl on purpose. Any difference between how torii and curl read a URL would be
  a bypass, so the parser rejects instead of interpreting. A differential test against curl would reduce that risk.
* JavaScript coverage would be a separate project: Node has many more sinks (`https`, `net`, `dgram`, `fetch`,
  dynamic `import()`), and its permission model differs.
