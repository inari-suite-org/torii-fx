# torii

**A runtime permission firewall for FiveM server-side Lua resources.**
Every resource declares what it needs (which web hosts it talks to, whether it runs dynamic code). The server admin
approves it once. Everything else is blocked, or logged first while you get comfortable.

```text
[torii] BLOCKED  shop_v2  http PerformHttpRequestInternalEx -> https://cipher-panel.example/payload.lua  (resource_not_in_lockfile)  at shop_v2/server/main.lua:48
```

<!-- Demo GIF goes here: docs/demo.gif (record `ensure torii_demo_backdoor` in observe, then in enforce mode). -->
<p align="center"><em>demo GIF: <code>docs/demo.gif</code> (to be recorded)</em></p>

## The problem

FiveM servers install third-party resources: bought, free, or "leaked". Some carry a backdoor such as the
Cipher family or the 2026 Blum panel loader: a few obfuscated lines that download code from a remote server and
run it with `load` (or `eval` in JavaScript), steal `rcon_password`, or hand an attacker admin rights.

Most existing tools are static scanners that look for known patterns. A backdoor with an obfuscation they have
not seen yet walks past them.

torii turns the problem around, like Android permissions or Deno's `--allow-net`: it does not try to recognise
bad code, it controls what code is *allowed to do*. However well it is obfuscated, a remote loader has to
contact a host and execute what it receives, and those are the two things torii gates.

## How it works

```text
              server.cfg                                       resources/shop_v2/fxmanifest.lua
   ensure torii  (first)                                       shared_script '@torii/init.lua'   <- added by `torii install`
        │                                                      torii_http 'api.shop.example/v1'  <- what the author asks for
        ▼
 ┌──────────────┐   exports.torii:report()   ┌───────────────────────────────────────────────┐
 │ torii (core) │ ◄───────────────────────── │ Lua state of shop_v2: init.lua runs FIRST and │
 │ log, alerts, │                            │ wraps HTTP, load, InvokeNative, SaveResource- │
 │ manifest gate│                            │ File, debug.getupvalue... using policy.lock   │
 └──────────────┘                            └───────────────────────────────────────────────┘
```

* Each resource has its own Lua state, so interception happens **inside** each protected resource.
  `shared_script '@torii/init.lua'` runs before any other script of that resource (verified, see
  [docs/experiments-results.md](docs/experiments-results.md)).
* The manifest only **asks**. The admin-owned lockfile `torii/policy.lock.json` **grants**, and stores a hash of
  the declaration that was reviewed. If a resource update changes its declaration, torii reports it.
* The core resource refuses (enforce) or flags (observe) resources that have server code but no torii line,
  and resources that run JavaScript/C# server code torii cannot inspect.

## Install (3 steps)

Requirements: Node.js 18+ for the CLI, and a recent FXServer artifact (developed and tested on build 36897; older
builds are untested and may lack the cross-resource file-write protection torii relies on to protect its own files).

1. **Copy the `torii/` folder into `resources/`** and put `ensure torii` **first** in `server.cfg`.
2. **Protect your resources**:
   ```bash
   node cli/torii.mjs install /path/to/resources      # adds one line per manifest, keeps *.torii.bak backups
   ```
   (`npx torii-fx install ...` once the package is published. `torii uninstall` restores everything.)
3. **Restart in observe mode** (the default: nothing is blocked). Use the server normally for a while, then:
   ```bash
   node cli/torii.mjs approve /path/to/resources --from-logs resources/torii/logs/torii.jsonl
   ```
   Read the diff. If it looks right, add `--write`, restart, and turn enforcement on in `server.cfg`:
   ```text
   set torii_mode "enforce"
   ```

Try it safely first: `ensure torii_demo_backdoor` ([demo/](demo/torii_demo_backdoor)) imitates a remote loader
against a `.invalid` domain and shows what torii does in each mode.

## Permissions

Declared by the resource author in `fxmanifest.lua` (a *request*, nothing more):

```lua
torii_http 'api.weather.example'                        -- a host (https by default)
torii_http 'discord.com/api/webhooks/1234567890'        -- a path prefix (matched on segment boundaries)
torii_http 'http://legacy.example.com:8080'             -- plain http / explicit port must be written out
torii_dynamic_code 'yes'                                -- may run load() on text (many libraries do)
torii_follow_redirects 'yes'                            -- keep following HTTP redirects (off by default in enforce)
```

Granted by the admin in `torii/policy.lock.json` (written by `torii approve --write`):

```json
{
  "version": 1,
  "exempt": ["my_trusted_js_resource"],
  "resources": {
    "weather": {
      "http": ["api.weather.example/v1"],
      "dynamic_code": false,
      "follow_redirects": false,
      "declaration_hash": "1529d180165a4ed687b671ddcf294eb70ddf5878b2ddda8e7edbe89e1951720d"
    }
  }
}
```

HTTP rules, all enforced by a strict URL parser (see [url_spec.lua](spec/url_spec.lua)):

* Host match is exact (no wildcards in v0.1). Lower-cased, trailing dot removed, default ports implied.
* Refused whatever the lockfile says: `localhost`, private/link-local/loopback ranges (IPv4 in every spelling,
  IPv6, IPv4 hidden in IPv6), `*.users.cfx.re` (FXServer rewrites it to localhost), single-label hosts, URLs with
  user info, backslashes, odd percent-encoding or non-ASCII hosts. For local development: `set torii_allow_private 1`.
* In enforce mode redirects are **not followed** unless granted (an allowed host that redirects would otherwise
  be a way out). A denied request looks like a network failure (`PerformHttpRequest` calls back with status 0).
* Hosts where anybody can publish content (`pastebin.com`, `*.github.io`, `*.workers.dev`...) or that receive data
  from any account (`discord.com`, `api.telegram.org`...) trigger a warning; scope them with a path prefix.

`load`: text chunks need `dynamic_code`; binary chunks (Lua bytecode) are **always** refused, in every mode.
A denied `load` returns `nil, message`, like a syntax error.

Other natives (`GetConvar` on secret-looking names, `ExecuteCommand`, `SetHttpHandler`, writes to code files) are
logged. Rewriting any `fxmanifest.lua` / `__resource.lua` through `SaveResourceFile` is blocked in enforce mode.

## Modes and logs

| `set torii_mode` | Behaviour |
|---|---|
| `observe` (default) | Nothing is blocked. Everything that *would* be blocked is logged as `WOULD BLOCK`. |
| `enforce` | Denials are real. Resources without the torii line, or with JS/C# server code, are not started unless listed in `exempt`. |

Console: one line per event (resource, API, target, reason, file:line). File: `torii/logs/torii.jsonl`, one JSON
object per line:

```json
{"ts":"2026-10-07T07:53:39Z","resource":"shop_v2","type":"http","api":"PerformHttpRequestInternalEx","decision":"would_deny","mode":"observe","reason":"not_in_allow_list","target":"https://evil.example/payload.lua","src":"shop_v2/server.lua:14","level":"warn"}
```

torii never logs request bodies, headers, query strings, long path segments (tokens), convar values or command
arguments. Only convar *names* and command *names*.

## Limits (read this)

torii is a seatbelt, not a vault. The full analysis is in **[docs/threat-model.md](docs/threat-model.md)**. In short:

* **Server-side Lua only.** JavaScript and C# server scripts are *flagged*, not inspected, and the most recent
  public backdoor family is JavaScript. Pair torii with an OS-level egress firewall.
* A resource can do harm with no network and no `load` (hidden admin commands, economy exploits). torii does not see that.
* Data can leave through channels other than HTTP (client events, trusted resources' exports).
* An approved host that is itself malicious or compromised stays approved.
* torii runs inside the same Lua VM as the code it guards. It closes the bypasses we know of
  (`Citizen.InvokeNative`, lazily loaded native stubs, `debug.getupvalue`, bytecode, `require`'d libraries,
  redirects, table metamethods...), each with a test, but it is not a hard sandbox.
* The manifest approach fails open (a missing line is only noticed by the core's gate). Escrow-protected
  (`.fxap`) resources are untested.

## Development

```bash
luarocks install busted luacheck       # Lua 5.4
busted                                 # unit tests with simulated natives
luacheck .  &&  stylua --check torii spec
npm test                               # CLI tests (node:test, no dependencies)
```

See [CONTRIBUTING.md](CONTRIBUTING.md). Report vulnerabilities as described in [SECURITY.md](SECURITY.md).
Design record: [docs/feasibility.md](docs/feasibility.md), [docs/experiments-results.md](docs/experiments-results.md).

## License

MIT, see [LICENSE](LICENSE).
