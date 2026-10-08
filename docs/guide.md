# Step-by-step guide

For server owners who are not developers. You do not need to read code. Count about 20 minutes of work, then a few
days of waiting while torii observes. Version française : [guide-fr.md](guide-fr.md).

> [!WARNING]
> torii is **experimental**: it has not yet run on a server with real players. In **observe** mode (the default) it
> blocks nothing and cannot break your server. Stay in observe mode until you have done step 6.

## What torii does, in three sentences

Every script on your server can, today, contact any website and run any code it downloads. That is how backdoors
hidden in "free" or leaked scripts take over servers. torii gives each script a list of what it is allowed to do, and
reports (observe mode) or blocks (enforce mode) everything else.

## What you need

- Access to your server files: FTP, your host's file manager, or the machine itself.
- Access to `server.cfg` (txAdmin has a **CFG Editor** in its menu).
- A Windows, macOS or Linux computer with **Node.js 18 or newer** ([nodejs.org](https://nodejs.org), "LTS" version).
  Node runs the torii tool on **your computer**. Your server does not need it.
- torii itself: on the [GitHub page](https://github.com/inari-suite-org/torii-fx), click **Code**, then
  **Download ZIP**, and unzip it on your computer.

## 1. Make a backup

Download a copy of your whole `resources` folder to your computer, and keep it aside. If anything goes wrong, you put
it back.

Keep a second copy to work on in the next steps. In this guide it is called `C:\torii-work\resources` (use any folder
you like).

## 2. Add the torii resource

1. In the unzipped download, find the folder named `torii` (the one that contains `fxmanifest.lua` and `init.lua`).
2. Upload it into your server's `resources` folder, next to your other scripts.
3. In `server.cfg`, make `ensure torii` the **first** `ensure` line, above every other script:

```cfg
ensure torii
# ... your other ensure lines below
```

## 3. Protect your scripts

Each script needs one line in its `fxmanifest.lua` so that torii runs inside it. The tool adds it for you.

1. Open a terminal **on your computer**, in the unzipped torii folder (on Windows: open the folder, type `cmd` in the
   address bar and press Enter).
2. Run, with the path of your working copy:

```bash
node cli/torii.mjs install "C:\torii-work\resources"
```

3. The tool lists what it changed. Each changed manifest keeps a backup next to it (`fxmanifest.lua.torii.bak`).
4. Upload the changed `fxmanifest.lua` files back to the server (uploading the whole working copy also works). The
   `.torii.bak` files can stay on your computer.

What the line looks like, if you prefer to add it by hand: right after the `fx_version` line,

```lua
fx_version 'cerulean'
shared_script '@torii/init.lua'
```

Scripts with no server code are skipped: torii only protects server-side Lua.

## 4. Restart and check

Restart the server (txAdmin: **Restart**). In the console, look for:

```text
[torii] core started in observe mode
[torii] mode=observe  protected=42  unprotected=0  js/c#=3  exempt=0  no-server-code=17
```

| Word | Meaning | What to do |
|---|---|---|
| `protected` | scripts torii watches | nothing |
| `unprotected` | scripts with server code but without the torii line | redo step 3 for them (their names are listed on the next line) |
| `js/c#` | scripts written in JavaScript or C#, which torii cannot inspect | see step 7 |
| `no-server-code` | scripts that only run on players' computers | nothing |

You can print this again at any time by typing `torii_status` in the txAdmin live console.

## 5. Let it observe

Leave the server running normally for **at least three days, including a weekend**, so that every script gets used.

You will see lines like this in the console:

```text
[torii] WOULD BLOCK  weather_sync  http PerformHttpRequestInternalEx -> https://api.weather.example/v1  (resource_not_in_lockfile)  at weather_sync/server.lua:12
```

Read it as: *"the script `weather_sync` contacted `api.weather.example`; in enforce mode this would be blocked,
because you have not allowed it yet."* Nothing is blocked right now. Everything is also written to
`resources/torii/logs/torii.jsonl`.

You do not have to watch the console. At start, and at most once an hour, torii prints a summary such as
`3 request(s) to review (1 suspicious). Type "torii review".` Type these in the txAdmin live console:

| Command | What it shows |
|---|---|
| `torii` | how many requests wait for a decision, and whether enforce mode looks safe yet |
| `torii review` | the numbered list, worst first: what each script tried, why it matters, what to do |
| `torii explain 2` | request 2 in detail: how many times, since when, from which file and line |

To see the messages in French, add `set torii_lang "fr"` to `server.cfg`.

## 6. Decide what each script may do

1. Download `resources/torii/logs/torii.jsonl` from the server to your computer, for example into `C:\torii-work`.
2. Run:

```bash
node cli/torii.mjs approve "C:\torii-work\resources" --from-logs "C:\torii-work\torii.jsonl" --use-presets --ask
```

3. The tool starts with a **review**: every request gets a verdict and one sentence on what to do.

| Verdict | Meaning |
|---|---|
| 🟢 common | usual for this kind of script (a version check, a library checked against its source). Not asked. |
| 🟠 check | torii cannot tell: an unknown site, a Discord webhook. Read the advice, then answer `y` to allow or press Enter to refuse. |
| 🔴 suspicious | what backdoors do: a raw IP address, a name imitating a known site, a paste site, code run from memory. Refused unless you type `yes` in full. |

4. When torii asks `allow? [y/N]`, use the advice on screen. In short:
   - a Discord webhook: allow it **only if it is yours** (Discord, *Server Settings > Integrations > Webhooks*, the
     number must match one of yours). A backdoor sends your server's secrets to the attacker's webhook;
   - a site mentioned in the script's documentation, or obviously linked to what it does (weather script, weather
     site): allow;
   - anything else: **ask the script's author** first. Pressing Enter refuses it for now; you can approve it later.
   - a script you do not know that runs code from memory **and** contacts a site torii cannot vouch for is the exact
     shape of a backdoor: refuse, and remove the script.
5. torii shows what it will write and asks for a last confirmation. Answer `y`.
6. Upload `C:\torii-work\resources\torii\policy.lock.json` to `resources/torii/` on the server.

## 7. JavaScript and C# scripts

torii cannot look inside them. In enforce mode it **refuses to start** them, unless you list them as exempt. Common
ones are `oxmysql`, `pma-voice` and `screenshot-basic`. To see which ones you have:

```bash
node cli/torii.mjs exempt "C:\torii-work\resources"
```

To exempt one (then upload `policy.lock.json` again):

```bash
node cli/torii.mjs exempt "C:\torii-work\resources" oxmysql --write
```

Exempt means "torii does not check this script at all". Only exempt scripts you trust, from their official source.
`--remove` takes a name off the list again.

## 8. Switch to enforce mode

1. In `server.cfg`, above `ensure torii`, add:

```cfg
set torii_mode "enforce"
ensure torii
```

2. Restart. Lines now say `BLOCKED` instead of `WOULD BLOCK`.
3. Watch the console for a day. If a script you trust stops working because of a `BLOCKED` line, set the mode back to
   `observe`, restart, and redo step 6 with the new log.

## Later: when you update or add a script

After an update, torii may print `declaration_changed_since_approval` or `declaration_not_approved`: the script now
asks for something you did not review. Redo steps 3 and 6 for it. A script you just added has no permissions until
you approve it, so in enforce mode its network calls are blocked.

## Removing torii

```bash
node cli/torii.mjs uninstall "C:\torii-work\resources"
```

Upload the manifests again, remove `ensure torii` (and `set torii_mode`) from `server.cfg`, restart. Or put back the
backup from step 1.

## If something goes wrong

| You see | It means | Do this |
|---|---|---|
| `Couldn't start resource X` just after a torii `BLOCKED ... manifest_gate` line | in enforce mode, X has server code but no torii line | add the line (step 3), or exempt it (step 7) |
| `policy.lock.json is not valid JSON` | the file has a typing mistake | check commas and quotes (an online JSON validator helps), or upload the version the tool wrote |
| A script you trust says it cannot reach its website | its site is not allowed yet | go back to `observe`, then step 6 |
| Nothing from torii in the console | `ensure torii` is missing or not first | step 2 |

Still stuck, or think you found a backdoor? Open an issue on GitHub (never paste secrets, tokens or passwords). If you
found a way **around** torii, report it privately instead: see [SECURITY.md](../SECURITY.md).
