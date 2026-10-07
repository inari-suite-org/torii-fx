# torii - Phase 0 feasibility study

> This is the study written before any code. Several [A] assumptions were later tested; see
> [experiments-results.md](experiments-results.md) for what held and what changed, and
> [threat-model.md](threat-model.md) for the current threat model.

> Status: draft for review. No production code has been written.
> Date: 2026-10-07.
> FXServer source pinned to `citizenfx/fivem@e34d12c` (master, 2026-09-30) and
> `citizenfx/lua@4b086dc` (branch `luaglm-548`). Line numbers below refer to these commits.

## How to read this document

Every claim carries one of these tags:

| Tag | Meaning |
|-----|---------|
| **[V]** | Verified by reading FXServer / Cfx Lua source code (link given). |
| **[D]** | Taken from official docs, the Cfx.re forum or a third-party project. Not checked in source. |
| **[A]** | Assumption or inference. **Must be tested on a real server in Phase 1** before we rely on it. |

Short links used below:

- `F/…` = `https://github.com/citizenfx/fivem/blob/e34d12cd9a39cc223548a5be1ab09f60e9183051/…`
- `L/…` = `https://github.com/citizenfx/lua/blob/4b086dc082da96a8e21aaa38ef7c0f4a7697f2a4/…`

---

## TL;DR

1. **Feasible for server-side Lua, with real limits.** Each resource has its own Lua state [V], and
   `shared_script '@torii/init.lua'` runs before all of the resource's own scripts [V]. Inside that state we
   can wrap every Lua path to outbound HTTP and to dynamic code, *provided* we also harden `debug`,
   `require`, `Citizen.LoadNative`, `Citizen.InvokeNative` and the global metatable. Wrapping only
   `PerformHttpRequest` and `load` is trivially bypassable (see §3).
2. **There is no official way to inject code into every resource** without editing manifests [V]. The only
   alternatives are editing each `fxmanifest.lua` (supported, fragile against manifest edits) or patching the
   server artifact's `citizen/scripting/lua/*.lua` files (global, but unsupported and wiped by every update).
3. **A separate "guard" resource cannot hook other resources.** States are isolated [V]. Several existing
   "anti-backdoor" resources that tell you to "start it first" therefore only protect themselves. This is a
   useful point for the README.
4. **Cfx.re has shipped part of this already.** Since Dec 2024, cross-resource file writes are denied by default
   (`add_filesystem_permission`) [V]. Since Feb 2026, Node.js resources need explicit permission for
   `child_process` and worker threads, and their file access goes through the same check [V]. **Outbound network
   access and `eval`/`load` are still unrestricted in every runtime** [V]. That is exactly the gap torii fills.
5. **Lua-only is a big gap.** The most recent public backdoor family (Blum / Warden panel, July 2026) is
   **JavaScript** and uses `require("https")` + `eval` [D]. v0.1 must at least *detect and flag* JS/C# server
   scripts at resource start, and the README must say clearly that they are not covered.
6. **The permissions must not be trusted just because they are in the manifest.** The attacker writes the
   malicious resource's manifest, so they can declare `cipher-panel.me` as allowed. Declarations need an
   **admin approval step** (a lockfile owned by torii). This is the most important design decision; see §7.
7. **Name**: no FiveM project called `torii` found. The name is crowded in general (including a security
   reverse proxy), so publish the repo under a qualified name (e.g. `torii-fx`) and keep `torii` as the
   resource name. See §0.

---

## 0. Name check

- GitHub repo search `torii fivem`: **0 results**. Code search `torii` in `fxmanifest.lua` files: **0 results**.
  Web search: no FiveM resource or tool named torii. [D, 2026-10-07]
- The word is crowded outside FiveM: `cmackenzie1/torii-rs` (Rust auth, ~460★), `Qovery/Torii` (developer
  portal), `nunoOliveiraqwe/torii` (**a security reverse proxy with honeypots**, the closest in spirit),
  Dojo's Torii indexer, the Ember `torii` OAuth library. [D]
- Recommendation: keep **`torii`** as the resource folder name (it is what admins type in `ensure`), and name the
  repository / package **`torii-fx`** (or `fx-torii`) for searchability. If you prefer a fully unique name,
  candidates in the same theme: `sekisho` (関所, checkpoint), `kekkai` (結界, protective barrier),
  `bansho` (番所, guard post). `sekisho` already has a few unrelated GitHub repos; the other two were **not**
  checked. [A]

---

## 1. Runtime isolation and injection

### 1.1 One Lua state per resource - yes

- `LuaScriptRuntime` is created per resource and owns its own `lua_State` (`m_state`) [V]
  (`F/code/components/citizen-scripting-lua/src/LuaScriptRuntime.cpp`, `Create()` around L1300-1425).
- Per-state boot order [V] (same file, L1360-1422):
  1. Standard libs: `_G` (base), `table`, `string`, `math`, `coroutine`, `utf8`, `debug`, and **server only**
     the Cfx versions of `io` and `os`, plus `msgpack` and `json` (L163-178).
  2. The `Citizen` table (C functions: `InvokeNative`, `LoadNative`, `CreateThread`, … L1167-1209).
  3. Natives: either a full `natives_*.lua` file or `natives_loader.lua` (lazy natives) (L1430-1452).
  4. `deferred.lua`, `scheduler.lua`, `graph.lua` (system files from `citizen:/scripting/lua/`).
  5. `dofile` and `loadfile` are set to `nil`; `print` and `require` are replaced by C functions (L1411-1421).
- Consequence: code in resource A **cannot** see or change globals of resource B. The only links between states
  are events, exports (built on events), function references, commands, convars, state bags, KVP, and the
  file system. [V for events/exports in `scheduler.lua`; others A]
- Consequence 2: **a torii "core" resource cannot intercept calls made in other resources.** Any guard must run
  *inside* each protected state.

### 1.2 Running code before the resource's own code

- Script load order inside a resource [V] (`F/code/components/citizen-scripting-core/src/ResourceScriptingComponent.cpp`
  L309-340): all `shared_script` entries first, then all `server_script` entries, each list in manifest order,
  each file dispatched to the runtime that handles its extension.
- So `shared_script '@torii/init.lua'`, placed **before any other script directive**, is the first piece of
  *resource* code to run in that Lua state. Only the system files above (natives, scheduler) run earlier, and
  those come from the server artifact, not from the resource. [V]
- `@other_resource/file.lua` is resolved as a file of another resource and runs in the *including*
  resource's state; this is exactly how `@ox_lib/init.lua` works [D, ox_lib `init.lua`]. ox_lib checks
  `GetResourceState('ox_lib') == 'started'` in Lua, which suggests the file can be loaded even if the provider is
  not started. [A]
- If `@torii/init.lua` cannot be loaded (torii missing or renamed), FXServer prints
  `Failed to load script …` and **continues starting the resource** [V] (same file, L334-338).
  **The per-manifest approach fails open.** We need an independent check (§7, "manifest gate").

### 1.3 Injecting into every resource without editing manifests

| Option | Works? | Notes |
|---|---|---|
| A convar or "preload" script | **No** [V] | `LuaScriptRuntime::Create` loads a fixed list of system files. No convar, no hook, no `package.preload` (`package` is not even opened). `require` only knows `lmprof` and `glm` (L758-785). |
| A "guard" resource started first | **No** [V] | Separate states (§1.1). It can only observe *events* and *manifests*, not calls. |
| `shared_script '@torii/init.lua'` in each manifest | **Yes** [V] | Official mechanism, same as ox_lib. Needs a tool to edit manifests; an attacker can remove the line from their own manifest (§3). |
| Patch `citizen/scripting/lua/scheduler.lua` (or `deferred.lua`) in the server artifact | **Probably** [A] | It runs in every Lua state before any resource code, so nothing to add to manifests and nothing for the attacker to remove. **But**: unsupported by Cfx.re, overwritten by every artifact update (txAdmin updates often), and it means shipping a modified copy of Cfx code. The file is loaded through `citizen:/` VFS; whether it is a plain file in the Windows/Linux artifacts must be checked. |

---

## 2. Interception surface (server-side Lua)

General rule in this runtime: **a Lua function can be replaced, but the C function it points to stays reachable
from any place that kept a reference to it.** So for each item the question is "can we replace *every*
reference reachable from resource code?".

Important facts that shape the whole list:

- Natives are looked up lazily through a **metatable on `_G`** whose `__index` calls `Citizen.LoadNative(name)`
  and caches the result with `rawset` [V] (`F/data/shared/citizen/scripting/lua/natives_loader.lua` L74-101).
  Native stubs are compiled with a private environment `nativeEnv` that holds the **original**
  `Citizen.InvokeNative` as `_in` (L45-70). If we `rawset` our wrapper on `_G` first, normal lookups hit the
  wrapper.
- `require(name)` returns `registry._LOADED[name]` [V] (L758-767). So `require('debug')`, `require('io')`,
  `require('os')` return the **original library tables**. Replacing the global `debug` is useless: library
  tables must be **patched in place**.
- `scheduler.lua` captured `debug`, `Citizen` and `Citizen.InvokeNative` in locals before torii runs [V]
  (L1-42). Because they are the *same tables*, in-place patches are also seen by the scheduler.

| Target | What it gives an attacker | Wrappable? | How / caveats |
|---|---|---|---|
| `PerformHttpRequest`, `PerformHttpRequestAwait` | Outbound HTTP (C2, exfiltration) | **Yes** | Defined in `scheduler.lua`; they call the global `PerformHttpRequestInternalEx` at call time [V] (L380-410). Wrapping the internal natives (next row) covers them. We can still wrap them to get a better call site. |
| `PerformHttpRequestInternal`, `PerformHttpRequestInternalEx` | Same, lower level | **Yes** | Natives `PERFORM_HTTP_REQUEST_INTERNAL[_EX]` [V] (`F/code/components/citizen-server-impl/src/HttpScriptFunctions.cpp` L225-226). `rawset` wrappers on `_G`. Parse the URL (JSON string for the non-Ex variant, table for Ex). |
| `Citizen.InvokeNative(hash, …)` | Call **any** native by hash, bypassing named wrappers | **Yes, in place** | C function; hash read with `lua_tointeger` [V] (`F/.../LuaScriptNatives.cpp` L278-284), so `"0x…"` strings and integral floats also work. Our filter must normalise exactly the same way, then deny/allow by hash. Replace the field in the `Citizen` table and in `nativeEnv._in` (see §3). |
| `Citizen.LoadNative(name)` | Get a fresh, unwrapped native stub | **Yes, in place** | C function [V] (L379+). Wrapper returns our wrapper for protected names. |
| `load` | Dynamic code execution | **Yes** | Base library. Default mode is `"bt"` [V] (`L/lbaselib.c` L466-470) and Cfx did **not** enable `LUA_NO_BYTECODE` [V] (`F/code/vendor/lua.lua` L36). Wrapper must **force text mode** (malicious bytecode is a known way to corrupt Lua memory and escape any in-Lua sandbox). Legit libraries use `load` heavily (ox_lib loads its modules with `LoadResourceFile` + `load` [D]), so a plain "deny" is not usable; see §7. |
| `loadstring` | Same | n/a | Not in Lua 5.4. A resource could define it as an alias; it ends up calling `load`. |
| `dofile`, `loadfile` | File-based code exec | n/a | Removed by FXServer [V] (L1411-1415). |
| `string.dump` | Turns a function into bytecode | **Yes** | Harmless alone; only dangerous with binary `load`, which we block. Optional wrapper. |
| `LoadResourceFile(res, path)` | Read files of **any** resource | **Yes** | No permission check on reads; path traversal and absolute paths are blocked [V] (`F/.../MetadataScriptFunctions.cpp` L146-215). Mostly a confidentiality issue (read other resources' config). Log in v0.1, maybe no blocking. |
| `SaveResourceFile(res, path, …)` | Write files | **Yes** | Cross-resource writes already denied by FXServer unless `add_filesystem_permission` [V] (L255-270, `F/.../FilesystemPermissions.cpp` L84-130). Still important for torii: a resource can **rewrite its own manifest** to drop `@torii/init.lua` (persistence / un-protection). Guard writes to `fxmanifest.lua`, `__resource.lua` and code files. |
| `io` (Cfx version) | Files | **Yes, in place** | `io.open` checks writes with the same Cfx filesystem permission [V] (`F/.../LuaIO.cpp` L312). `io.popen` only accepts `dir`/`ls` commands [V] (L353-380). Reads of non-`@` paths: unclear [A]. Patch in place (`require('io')`). |
| `os` (Cfx version) | Process / FS | **Mostly neutralised by Cfx** | `os.execute` always returns "Permission denied" [V] (`F/.../LuaOS.cpp` L131-140); `os.getenv` only answers `"os"` [V] (L325-340); `os.remove`/`os.rename` go through the FS permission check [V]. Nothing critical left to wrap in v0.1. |
| `debug` | Recover originals from wrappers | **Must be patched in place** | Cfx builds Lua with `LUA_SANDBOX`: only `getinfo`, `getmetatable` (honours `__metatable`), `setmetatable` (not on userdata), `getupvalue` (Lua functions only) and `traceback` remain [V] (`L/ldblib.c` L56-69, L281, L484-503). **`getupvalue` is the main bypass tool** (§3). |
| `ExecuteCommand(cmd)` | Run console commands | **Yes** | Runs under principal `resource.<name>` and every command checks ACE `command.<name>` [V] (`F/.../ResourceScriptFunctions.cpp` L103-120, `F/code/client/citicore/console/Console.Commands.cpp` L114). By default only `system.console` has `command` and everyone has `command.help` [V] (`F/.../GameServer.cpp` L74-75). Real risk exists where `server.cfg` grants `add_ace resource.X command allow` (common for frameworks) [A]. Log in v0.1. |
| `GetConvar` | Read secrets (`rcon_password`, `mysql_connection_string`, keys) | **Yes** | Cipher-style backdoors read convars [D, forum]. Cheap, high value: log reads of a sensitive-name list. |
| `SetHttpHandler` | **Inbound** HTTP endpoint on the server port (C2 without any outbound call) | **Yes** | Native documented by Cfx [D]. Log in v0.1, permission in v0.2. |
| Exports / `TriggerEvent` to other resources | Confused deputy (use a trusted resource's power) | Partially | Exports are events named `__cfx_export_<res>_<name>`, triggered from the caller's own state [V] (`scheduler.lua` L626-735). We *could* filter them in the caller. Out of scope for v0.1. |

---

## 3. Bypasses

Assumed attacker: controls the Lua code of one resource (and its manifest), runs **after** `init.lua` in the
same state, knows torii's source code.

| # | Bypass | Blockable? | How |
|---|---|---|---|
| B1 | Call the HTTP native by hash: `Citizen.InvokeNative(0x…, …)` | **Yes** | Wrap `Citizen.InvokeNative` in place; normalise the hash like `lua_tointeger` (`tonumber` then `math.tointeger`), deny the HTTP hashes (and later others). Hash values to be read from the native DB [A]. |
| B2 | `Citizen.LoadNative("PerformHttpRequestInternalEx")` to get a fresh stub | **Yes** | Wrap `LoadNative` in place. |
| B3 | Read the original `_in` from **any** native stub: `debug.getupvalue(GetPlayerName, 1)` → `nativeEnv` → `nativeEnv._in` | **Yes, but subtle** | Either replace `nativeEnv._in` by our filter (every native call then goes through it, small cost), or make `debug.getupvalue` refuse functions whose source is not resource code. We plan both (defence in depth). |
| B4 | `debug.getupvalue(torii_wrapper, i)` to read the original function kept by the wrapper | **Yes** | Patch `debug.getupvalue` *in place* so it returns `nil` for torii functions, runtime/system functions (`@citizen:/…`, native stubs) and our own patched `getupvalue`. Same for `debug.getinfo(…, 'f')`? It returns the function itself, not upvalues, so no leak [A, to re-check]. |
| B5 | `require('debug')`, `require('io')` to get untouched libraries | **Yes** | Patch library tables in place, never replace them [V: `require` reads `_LOADED`]. |
| B6 | `getmetatable(_G).__index` to reach the lazy native loader and its upvalues (`_ln`, `_in`) | **Yes** | B3/B4 fix covers upvalues. We can also set `__metatable` on `_G`'s metatable to hide it [A: check nothing legit calls `setmetatable(_G, …)` later]. |
| B7 | `load(bytecode)` with a crafted binary chunk → memory corruption → native code execution, which bypasses everything | **Yes** | Force mode `"t"` in our `load` wrapper. Without this the whole sandbox is theoretical. |
| B8 | `rawget(_G, 'PerformHttpRequestInternalEx')` | **Yes** | Returns our wrapper because we `rawset` it. |
| B9 | Run **before** `init.lua` | **Only partly** | Inside one resource it is impossible as long as `@torii/init.lua` is the first script directive [V, §1.2]. But the attacker owns the manifest: they can put their own `shared_script` first, or delete our line, or rewrite it at runtime with `SaveResourceFile` (effective on next restart). Fix: a **manifest gate** in the torii core resource that, on `onResourceStarting` (cancellable [D]), reads `GetResourceMetadata(res, 'shared_script', 0)` and refuses/alerts if it is not `@torii/init.lua`. Plus a post-start attestation (init.lua reports in; missing report = alert). |
| B10 | Ship the payload in **JavaScript or C#** in the same resource | **No** (v0.1) | Different runtime, different VM. Detect and flag at start (manifest gate lists `.js` / `.dll` server scripts). See §4. |
| B11 | **Inbound** C2: `RegisterNetEvent` or `SetHttpHandler` + `load` | **Yes for the `load` part** | The `load` gate is what catches it; this is why `load` matters even with HTTP fully blocked. |
| B12 | Inbound C2 **without** `load` (hard-coded "give admin / give money / run SQL" handler) | **No** | Indistinguishable from game logic. Honest limit. |
| B13 | Exfiltration without HTTP: send data to the attacker's game client (`TriggerClientEvent`), or through another resource (Discord log exports, DB) | **No** (v0.1) | Honest limit. Export filtering (v0.2+) reduces the second one. |
| B14 | Confused deputy: call an export/event/command of a trusted resource that has more power | **Partly** | If the deputy is also protected, the deputy's own policy applies. The attribution in logs will point at the deputy, not the caller. |
| B15 | Declare the malicious domain in its own manifest | **Yes, by design** | Manifest declarations are *requests*; the admin approves them into a torii-owned lockfile (§7). |
| B16 | Detect torii and stay dormant (check `GetResourceState('torii')`, compare functions) | **No** | Expected with any defensive tool. While dormant it does nothing, but it will act if torii is removed. Mention in threat model. |
| B17 | Tamper with torii's policy file / code | **Yes on recent artifacts** | Cross-resource writes need `add_filesystem_permission` [V], which can only be set in `server.cfg` before boot ends [V] (`FilesystemPermissions.cpp` L177-230). On artifacts older than Dec 2024 this protection does not exist [A: exact build]. torii must check the artifact version and warn. |
| B18 | `ExecuteCommand('stop torii')` / `ensure` tricks | **Mostly by Cfx ACL** | Denied by default [V]. Dangerous only on servers that grant `command` to resources. torii should log all `ExecuteCommand` calls. |
| B19 | Spoof torii's log events to flood or forge reports | **Yes** | Core resource attributes reports with `GetInvokingResource()` [D], never with a field in the payload. Rate-limit. |
| B20 | Long dormancy, time bombs, payload split across resources | **Partly** | Runtime interception does not care about delay or split; obfuscation does not matter. It only matters *which* sink is finally reached. |

---

## 4. Other runtimes (JavaScript, C#)

- **JavaScript (Node.js)** [V] (`F/code/components/citizen-scripting-node/src/NodeScriptRuntime.cpp` L51-70, L464, L498):
  since Feb 2026 FXServer installs a Node permission handler covering **file system** (`fs.read` / `fs.write`,
  mapped onto the same resource FS permissions), **child processes** and **worker threads** (opt-in with
  `add_unsafe_child_process_permission` / `add_unsafe_worker_permission`), and WASI. **Network is not in the list**
  and `eval` / `new Function` are explicitly allowed ("required by some fivem scripts"). A JS backdoor on an
  up-to-date server can therefore still phone home and run downloaded JS, but can no longer spawn shell commands
  without the admin's consent. Older artifacts: no restriction at all [A on exact build].
- **Real-world relevance**: the Blum / Warden panel backdoor (reported July 2026) is a JS loader that waits ~20 s,
  downloads a second stage with `require("https")` and runs it with `eval()` [D, Cfx.re forum]. A Lua-only torii
  would **not** see it.
- **C# (Mono)**: full .NET class library, so `System.Net` sockets/HTTP are available. Not studied in source here [A].
- **Risk of a Lua-only v0.1**: high if we oversell it. An attacker who knows torii simply writes the backdoor in JS.
  Mitigations that fit in v0.1:
  1. The manifest gate lists every resource that has `.js` or `.dll` **server** scripts (including in
     `shared_script` and glob patterns) and, in `enforce`, refuses to start them unless the admin allow-lists them
     ("this resource runs code torii cannot inspect").
  2. README: say plainly "torii v0.1 inspects Lua only".
  3. Recommend an OS-level egress firewall as the runtime-agnostic complement (it cannot tell resources apart,
     torii can).
- **Later**: a JS shim is technically similar (the JS runtime also loads platform scripts first, and a
  `shared_script '@torii/init.js'` would run in the resource's V8 context) [A]. But Node has many more sinks
  (`require('https')`, `net`, `dgram`, `fetch`, `process.binding`, dynamic `import()`), so it is a separate project.

---

## 5. Installation experience

Constraints found during the study:

- A torii resource **cannot edit other resources' manifests at runtime** without one
  `add_filesystem_permission torii write <res>` line per resource [V]. So installation must be done **outside**
  the server process, by a CLI.
- Both `fxmanifest.lua` and the legacy `__resource.lua` must be handled; manifests use `shared_script 'x'`,
  `shared_scripts { … }`, trailing commas, comments, etc. Inserting a **new standalone line** right after
  `fx_version` / `game` (before any other directive) is the least fragile edit: no need to parse the
  existing tables, and order is guaranteed [V, §1.2].
- Escrowed (Cfx Asset Escrow) resources: the manifest is believed to be plain text and editable, and their code
  runs in the same Lua state, so torii should apply [A - **must be tested**; if escrow rejects manifest edits,
  a large part of paid resources would be out of reach].

Proposed flow (3 steps, matches the README goal):

```text
1. Drop the `torii` folder in resources/ and put `ensure torii` as the FIRST ensure in server.cfg.
2. Run: torii install ./resources      (adds the line to every manifest, writes .torii.bak backups,
                                         idempotent; `torii uninstall` restores the backups)
3. Restart. torii starts in observe mode and prints a coverage report:
   "52/54 Lua resources protected, 2 resources run JS server code (not covered): …"
```

CLI subcommands worth having from v0.1: `install`, `uninstall`, `status` (coverage), `approve`
(turn manifest permission requests into the lockfile, showing a diff like a package manager would).

Language for the CLI is an open decision (§7, D3).

---

## 6. Threat model

### Assets
Host machine; server credentials (`rcon_password`, `sv_licenseKey`, DB connection string, API keys, webhooks);
player data (identifiers, IPs); game economy and admin rights; the integrity of other resources.

### Attacker
The author (or re-packer) of a third-party resource that the admin installs knowingly. They control that
resource's code and manifest, may obfuscate arbitrarily, know torii, and may control a game client and remote
servers. They do **not** control the server artifact, `server.cfg`, or the torii resource.

### What torii (v0.1, Lua, enforce mode) stops
- Remote code download over HTTP from a non-approved domain, whatever the obfuscation (Cipher pattern
  `PerformHttpRequest(url, function(_, d) load(d)() end)`): the HTTP call is denied.
- Exfiltration through outbound HTTP to a non-approved domain.
- Execution of code received by any channel (net event, HTTP handler, KVP, file) through `load`, in resources
  not approved for dynamic code; execution of Lua bytecode in **all** resources.
- The known in-state bypasses listed in §3 (B1-B8).
- Silent self-removal of the injection line (detected at next start by the manifest gate).

### What it detects but does not stop (observe-level signals)
- Reads of sensitive convars, `ExecuteCommand` calls, `SetHttpHandler` registrations, reads of other resources'
  files, resources running JS/C# server code.

### What it does **not** stop
- Anything in **JavaScript or C#** server scripts (only flagged).
- Malicious logic that needs no network and no dynamic code (B12): hidden admin commands, backdoored events,
  economy exploits, SQL through a trusted DB export.
- Exfiltration through non-HTTP channels (B13) and through trusted deputies (B14).
- Approved domains that are themselves malicious or compromised (if you approve `pastebin.com`, a backdoor can use it).
- Client-side code (out of scope).
- Attackers with access to the host, `server.cfg`, txAdmin, or the torii folder.
- Servers on artifacts without Cfx's filesystem permission sandbox (torii's own files could be modified).
- A resource that is installed **after** torii but without the injection line, when the manifest gate is
  disabled or torii is in observe mode.
- Bugs in FXServer, Lua or torii itself. torii is defence in depth, not a substitute for not running leaked
  resources, reviewing code, OS-level egress filtering and backups.

---

## 7. Architecture recommendation

### Components
1. **`torii/init.lua`** (runs in every protected state). On load: capture originals in locals, read the approved
   policy for `GetCurrentResourceName()` from `torii/policy.lock.json` via `LoadResourceFile` (synchronous, read
   only), then:
   - `rawset` wrappers for `PerformHttpRequest*`, `PerformHttpRequestInternal*`, `SaveResourceFile`,
     `ExecuteCommand`, `GetConvar`, `SetHttpHandler`;
   - patch **in place**: `Citizen.InvokeNative`, `Citizen.LoadNative`, `nativeEnv._in`, `debug.getupvalue`,
     `io.open`, `load` in `_G`;
   - report each event (resource, API, target, `short_src:currentline` from `debug.getinfo`, mode, decision) to
     the core with a local event/export.
2. **`torii` core resource** (its own state): manifest gate on `onResourceStarting`, coverage report on boot,
   attestation check after start, JSON-lines log writer (`io.open('@torii/logs/…', 'a')`, allowed because it is
   its own folder [V]), console alerts, rate limiting.
3. **CLI** (outside the server): `install` / `uninstall` / `status` / `approve`.

### Decisions I need from you (with trade-offs)

**D1 - Where do permissions live? (most important)**
| Option | Pros | Cons |
|---|---|---|
| a) Only in the resource manifest (`torii_http 'api.example.com'`, `torii_dynamic_code 'yes'`) | Simple, close to your brief, travels with the resource | **Attacker-controlled**: a backdoor declares its own C2 domain. Defeats the purpose. |
| b) Only in a torii config file owned by the admin | Attacker cannot touch it [V on recent artifacts] | No "the author declares what it needs" story; admins must write everything by hand. |
| c) **Manifest = request, lockfile = approval** (recommended) | Best of both: authors document needs, `torii approve` shows them, admin accepts; any *new* or changed request after an update is flagged and not granted until re-approved (like Android permission changes) | One more file and one more CLI step. |

Custom keys such as `torii_http` are allowed in manifests and readable with `GetResourceMetadata` (the ox
ecosystem uses its own keys) [D/A, to confirm no warning is printed].

**D2 - Policy for `load`**: it is everywhere in legit code (ox_lib).
- a) Per-resource boolean `dynamic_code` (simple, coarse).
- b) Boolean + automatic allowance when the caller's source is an approved library chunk such as
  `@@ox_lib/…` [A: chunk names can be spoofed only by code that already passed `load`].
- c) Provenance check: allow `load` only on strings that came out of `LoadResourceFile` (exact match)
  - breaks with ox_lib, which concatenates two files.
Recommendation: **b**, with bytecode always denied.

**D3 - CLI language**
- a) Node.js (`npx torii-fx install`): quick to write and test, but admins need Node.
- b) Go / Rust single binary: best for admins (download and run, Windows + Linux), adds a second language to the repo.
- c) Lua script: same language as the project, but admins rarely have a Lua interpreter.
Recommendation: **a** for v0.1, with a single-binary build later if people adopt it.

**D4 - Injection method**
- a) Manifest line + manifest gate (recommended for v0.1: supported, reversible).
- b) Artifact patch of `scheduler.lua` as an optional "hardened" mode later, once tested [A].

**D5 - v0.1 scope** (your brief + what this study found indispensable)
- Must: HTTP (all four paths, B1-B2), `load` (+ forced text mode), `debug.getupvalue` / `nativeEnv` hardening
  (B3-B6), self-manifest write guard, manifest gate with JS/C# flagging, observe/enforce, console + JSON lines.
- Should (observe only, cheap): `GetConvar` on sensitive names, `ExecuteCommand`, `SetHttpHandler`.
- Later: exports filtering, `LoadResourceFile` policy, JS runtime, artifact-patch mode.

### Phase 1 experiments (to turn [A] into [V] before writing much code)
1. `@torii/init.lua` loads when torii is stopped / not yet started.
2. Custom manifest keys produce no warning; `GetResourceMetadata` reads them on a not-yet-started resource inside
   `onResourceStarting`, and `CancelEvent()` really stops the start on the server.
3. Server native hashes of `PERFORM_HTTP_REQUEST_INTERNAL[_EX]`, `EXECUTE_COMMAND`, `SET_HTTP_HANDLER`,
   `GET_CONVAR`, and whether the server is in lazy-natives mode (`natives_loader.lua`) or full-file mode.
4. Patching `debug.getupvalue` does not break scheduler stack traces.
5. Escrowed resources accept the injected line.
6. Artifact build that introduced `add_filesystem_permission` (for the version warning).
7. Whether `io.open` can read absolute host paths (e.g. `server.cfg`).
8. Overhead of routing all natives through the `InvokeNative` filter (benchmark).

---

## 8. Sources

FXServer (`citizenfx/fivem@e34d12c`):
- `code/components/citizen-scripting-lua/src/LuaScriptRuntime.cpp`, `LuaScriptNatives.cpp`, `LuaIO.cpp`, `LuaOS.cpp`
- `data/shared/citizen/scripting/lua/scheduler.lua`, `natives_loader.lua`
- `code/components/citizen-scripting-core/src/ResourceScriptingComponent.cpp`, `FilesystemPermissions.cpp`,
  `MetadataScriptFunctions.cpp`, `ResourceScriptFunctions.cpp`
- `code/components/citizen-scripting-node/src/NodeScriptRuntime.cpp`
- `code/components/citizen-server-impl/src/HttpScriptFunctions.cpp`, `GameServer.cpp`
- `code/client/citicore/console/Console.Commands.cpp`, `code/client/citicore/se/Security.cpp`
- `code/vendor/lua.lua`; git history of `FilesystemPermissions.cpp` (2024-12-16 first commit, 2026-02-17 Node sandboxing)

Cfx Lua fork (`citizenfx/lua@4b086dc`, branch `luaglm-548`): `lbaselib.c`, `ldblib.c`, `ldo.c`.

Docs and community:
- Cfx docs, `onResourceStarting` ("can be canceled to prevent this resource from starting"):
  https://docs.fivem.net/docs/scripting-reference/events/list/onResourceStarting/
- Cfx native doc `EXECUTE_COMMAND` (`ext/native-decls/ExecuteCommand.md`)
- ox_lib `init.lua`: https://github.com/overextended/ox_lib/blob/master/init.lua
- Blum / Warden panel warning (2026-07-21): https://forum.cfx.re/t/warning-blum-panel-blum-panel-me-warden-panel-me-is-a-malicious-backdoor-remote-code-loader-hidden-in-resources/5415839
- Anti-backdoor / anti-cipher panel (2023, example of a "start it first" approach): https://forum.cfx.re/t/fivem-anti-backdoor-anti-cipher-panel/5179430
- Cipher pattern description: https://fivemx.com/free/anti-backdoor-script/
