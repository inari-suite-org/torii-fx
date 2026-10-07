# Demo transcript

Real console output from FXServer build 36897 running `demo/torii_demo_backdoor`, a harmless resource that
imitates a remote-code-loader (reserved `.invalid` domain, no payload). A GIF of this session goes in
`docs/demo.gif` (not recorded yet).

## Observe mode (default): nothing blocked, everything reported

```text
[demo]  --- attempt 1: the classic loader: PerformHttpRequest + load ---
[torii] WOULD BLOCK  torii_demo_backdoor  http PerformHttpRequestInternalEx -> https://cipher-demo.invalid/payload.lua  (resource_not_in_lockfile)  at torii_demo_backdoor/server.lua:14
[demo]  --- attempt 2: run a string of code received from "somewhere" ---
[torii] WOULD BLOCK  torii_demo_backdoor  dynamic_code load -> chunk  (resource_not_in_lockfile)  at torii_demo_backdoor/server.lua:26
[demo]  load returned:	the dynamic code ran
[demo]  --- attempt 3: skip PerformHttpRequest and call the HTTP native by its hash ---
[torii] WOULD BLOCK  torii_demo_backdoor  http InvokeNative(PerformHttpRequestInternalEx) -> https://cipher-demo.invalid/via-invoke-native  (resource_not_in_lockfile)  at torii_demo_backdoor/server.lua:32
[demo]  --- attempt 4: read a secret convar ---
[torii] NOTICE  torii_demo_backdoor  convar GetConvar -> rcon_password  (sensitive_name)  at torii_demo_backdoor/server.lua:37
[demo]  --- attempt 5: rewrite my own manifest to drop the protection ---
[torii] WOULD BLOCK  torii_demo_backdoor  manifest_write SaveResourceFile -> torii_demo_backdoor  (manifest_write)  at torii_demo_backdoor/server.lua:44
```

## Enforce mode (`set torii_mode "enforce"`)

```text
[torii] BLOCKED  torii_demo_backdoor  http PerformHttpRequestInternalEx -> https://cipher-demo.invalid/payload.lua  (resource_not_in_lockfile)  at torii_demo_backdoor/server.lua:14
[demo]  callback received status=0 body=nil
[torii] BLOCKED  torii_demo_backdoor  dynamic_code load -> chunk  (resource_not_in_lockfile)  at torii_demo_backdoor/server.lua:26
[demo]  load returned:	refused: torii: dynamic code execution is not permitted for resource torii_demo_backdoor
[torii] BLOCKED  torii_demo_backdoor  http InvokeNative(PerformHttpRequestInternalEx) -> https://cipher-demo.invalid/via-invoke-native  (resource_not_in_lockfile)  at torii_demo_backdoor/server.lua:32
[demo]  InvokeNative returned request id	-1
[torii] BLOCKED  torii_demo_backdoor  manifest_write SaveResourceFile -> torii_demo_backdoor  (manifest_write)  at torii_demo_backdoor/server.lua:44
[demo]  SaveResourceFile(fxmanifest.lua) returned	false
```

## A resource without the torii line (enforce mode)

```text
[torii] BLOCKED  torii  manifest_gate onResourceStarting -> tmp_errtest2  (missing_torii_init_line)
[citizen-server-impl] Couldn't start resource tmp_errtest2.
```

## Approving what a legitimate resource needs

```text
$ node cli/torii.mjs approve resources --from-logs resources/torii/logs/torii.jsonl
Proposed changes to resources/torii/policy.lock.json

+ e2e_weather
    + http              example.com
    + dynamic_code      true   (resource may run load() on text)
    ~ declaration_hash  - -> 0c3f78047594

! e2e_weather
    dynamic_code lets this resource run any text as Lua (many libraries need it; a backdoor does too)

Nothing was written. Review the diff, then re-run with --write.
```
