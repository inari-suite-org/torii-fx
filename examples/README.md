# Examples

| File | What it shows |
|---|---|
| [`weather_sync/fxmanifest.lua`](weather_sync/fxmanifest.lua) | a resource manifest with the torii include and the permissions it asks for, commented line by line |
| [`policy.lock.json`](policy.lock.json) | what the admin's lockfile looks like once those permissions are approved |

You do not write the lockfile by hand: `torii approve` builds it from the manifests and from what resources did in
observe mode, shows it as a diff, and writes it only with `--write`. The demo resource in
[`../demo/torii_demo_backdoor`](../demo/torii_demo_backdoor) shows torii reacting to a fake remote-code loader.
