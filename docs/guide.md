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

## 6. Decide what each script may do

1. Download `resources/torii/logs/torii.jsonl` from the server to your computer, for example into `C:\torii-work`.
2. Run:

```bash
node cli/torii.mjs approve "C:\torii-work\resources" --from-logs "C:\torii-work\torii.jsonl" --use-presets
```

3. The tool prints what it **proposes** to allow, script by script. Nothing is saved yet.

```text
+ weather_sync
    + http              pastebin.com/raw
    + http              api.weather.example/v1
    ~ declaration_hash  - -> 0c3f78047594

! weather_sync
    pastebin.com serves or receives user content: anybody can host a payload there, a path prefix does not make it safe; drop it if you can
```

The `~ declaration_hash` line is bookkeeping, you can ignore it. The block starting with `!` lists the tool's
warnings: read every one.

Go through each `+ http` line and ask yourself:

| Question | If yes | If no |
|---|---|---|
| Is the address only numbers (`45.133.1.20`)? | **Do not allow.** Real services use names. | next question |
| Does the name imitate a known site (`discordd.app`, `githubb.com`, odd letters)? | **Do not allow.** | next question |
| Is it a site where anyone can post text (`pastebin.com`, `hastebin`, raw GitHub files)? | **Do not allow** unless the script's author explains why. Backdoors download their code from there. | next question |
| Is it a Discord webhook (`discord.com/api/webhooks/...`)? | Allow it **only if it is yours**: in Discord, *Server Settings > Integrations > Webhooks*, the number in the address must match one of your webhooks. A backdoor sends your server's secrets to the attacker's webhook. | next question |
| Is the site mentioned in the script's documentation, or obviously linked to what the script does (weather script → weather site)? | Allow. | **Ask the author** before allowing. Until then, leave it out. |

For `dynamic_code` lines (the script wants to run code it builds or downloads): scripts that use `ox_lib` need it,
which `--use-presets` handles for the library itself. A script you do not know that asks for `dynamic_code` **and**
contacts an unknown site is the exact shape of a backdoor: do not allow it, and remove the script.

4. When the proposal is right, run the same command again with `--write` at the end. If you decided to leave
   something out, you can instead edit `C:\torii-work\resources\torii\policy.lock.json` by hand afterwards and delete
   that line.
5. Upload `C:\torii-work\resources\torii\policy.lock.json` to `resources/torii/` on the server.

## 7. JavaScript and C# scripts

torii cannot look inside them. In enforce mode it **refuses to start** them, unless you list them as exempt. Common
ones are `oxmysql`, `pma-voice` and `screenshot-basic`.

Open `policy.lock.json` and add their names to `exempt`:

```json
{
  "version": 1,
  "exempt": ["oxmysql", "pma-voice"],
  "resources": { ... }
}
```

Exempt means "torii does not check this script at all". Only exempt scripts you trust, from their official source.

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
