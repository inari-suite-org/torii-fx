# Roadmap and improvement ideas

Ordered by value for the effort, with the reason behind the order. Everything here is *not* in v0.1.

## 1. Close the gaps that matter most

| Idea | Why | Effort |
|---|---|---|
| **JavaScript runtime coverage** | The newest public backdoor family is JavaScript (`require('https')`, `eval`). A Lua-only tool is easy to sidestep. Node has many more sinks (`net`, `dgram`, `fetch`, `import()`), so this is a separate project, but it is where the threat is moving. | high |
| **Known-library presets** | `approve` could pre-fill the *typical* grants of ox_lib, oxmysql, es_extended... (dynamic code, no HTTP) and only warn when a resource asks for more. Removes the main friction of the first install. | low |
| **Manifest gate for hash changes** | Today a changed declaration is reported. In enforce mode it could also drop the resource back to "no grants" until re-approved. | low |
| **Escrow (`.fxap`) test** | A large share of paid resources are escrowed; we have not verified the manifest edit works on them. | low (needs a resource) |

## 2. Make the guarantees stronger

| Idea | Why | Effort |
|---|---|---|
| **Export and event filtering** | Closes the "confused deputy" and exfiltration-through-another-resource gaps listed in the threat model. | high |
| **Signed or chained lockfile** | Detect tampering of `policy.lock.json` by something that can write the folder. | medium |
| **Hardened mode through the artifact** | Patching `scheduler.lua` would protect every resource without touching manifests. Unsupported by Cfx.re and overwritten by updates, so only as an opt-in. | medium |
| **More natives** | `GetConvarInt`/`GetConvarBool`, `io.open` on other resources' files (we measured that it is readable), `LoadResourceFile` policy. | low-medium |
| **Wildcard hosts** | `*.example.com` is convenient but widens the parser's attack surface; only with strict rules and tests. | medium |

## 3. Make it pleasant to run

| Idea | Why | Effort |
|---|---|---|
| **Alerts to a webhook** (through an allow-listed host of torii itself) | Be told about a block without watching the console. | low |
| **txAdmin integration** | Show coverage and pending approvals in the panel. | medium |
| **`torii doctor`** | One command that checks the artifact build, the `ensure` order, `add_filesystem_permission` and the lockfile, and explains what is missing. | low |
| **Log rotation and retention** | The JSON-lines file grows forever. | low |
| **Published npm package + GitHub release** | `npx torii-fx` instead of `node cli/torii.mjs`. | low |

## 4. Reputation work (not code)

* A recorded GIF/video of the demo, and a short write-up: *"What about 2,000 lines of Lua can and cannot do against FiveM backdoors"*.
* A public list of every bypass attempted and the test that stops it (the README already promises one test per bypass).
* Invite bypass reports: a documented, fixed bypass builds more trust than a silent claim of safety.
