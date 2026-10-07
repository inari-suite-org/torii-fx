# Presets for known libraries

`torii approve` knows what a few widely used libraries legitimately need, so the first approval does not start from
a blank page. It is a suggestion, never a default.

```bash
node cli/torii.mjs approve /path/to/resources                  # describes what it recognised, proposes nothing
node cli/torii.mjs approve /path/to/resources --use-presets    # adds the suggestions to the proposal
```

## What a preset contains

| Field | Meaning |
|---|---|
| `resources` | the folder names it applies to |
| `origin` | the repository the folder is supposed to come from |
| `originHint` | text that must appear in the resource's manifest, otherwise the preset is not applied |
| `checked` | the commit and date it was read at, which files, and what was searched for |
| `grants` | the permissions suggested (`dynamic_code`, `http` entries with a path prefix) |
| `why`, `youProvide`, `alsoSeen` | the evidence, what only the admin can fill in (a webhook, a logging endpoint), and other behaviour that torii logs but does not restrict |

## Why a name match is not enough

A hostile resource can be called `ox_lib`. So a preset:

* is only applied with `--use-presets`;
* is not applied when the manifest lacks the origin hint (an author or repository the real library declares);
* never contains a bare shared host: `api.github.com` is only suggested as `api.github.com/repos/overextended`;
* is always printed with the commit it was checked at, so you can compare with the source.

The hint is a partial guard: a manifest can be copied. Check that the folder really comes from the repository the
preset names before you write the lockfile.

## Libraries covered

`ox_lib`, `ox_inventory`, `ox_target`, `es_extended`, `esx_lib`, `qb-core`. `oxmysql` is recognised but gets no
grant: it runs in the JavaScript runtime, which torii does not inspect.

## Adding or updating one

1. Check out the library at a specific commit.
2. Search every tracked Lua file for `PerformHttpRequest`, `load`, `loadstring`, `SaveResourceFile`,
   `SetHttpHandler` and `ExecuteCommand`, and read each hit.
3. Record the commit, the date and what you searched for under `checked`.
4. Suggest only what the hits justify. Anything the admin configures (webhooks, log destinations) goes in
   `youProvide`, never in `grants`.
5. Add the origin hint, and run `npm test` and `busted`: both check the file.
