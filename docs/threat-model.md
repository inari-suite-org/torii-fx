# Threat model

torii v0.1 protects a FiveM server against **third-party Lua resources that turn out to be hostile**. This page
says what it stops, what it only reports, and what it cannot see. Sources and tests for each claim are in
[design.md](design.md), [verification.md](verification.md) and `spec/`.

## Assets

The host machine; server secrets (`rcon_password`, `sv_licenseKey`, database connection strings, API keys, webhooks);
player data; the game economy and admin rights; the integrity of other resources.

## Attacker

The author (or re-packer) of a resource the admin installs knowingly. They control that resource's Lua code and
manifest, may obfuscate arbitrarily, know how torii works, and may run remote servers and a game client.
They do **not** control the server artifact, `server.cfg`, txAdmin, the host, or the `torii` folder.

## What torii (v0.1, enforce mode) stops

| Behaviour | How |
|---|---|
| Downloading code over HTTP from a host the admin did not approve (the Cipher pattern) | HTTP policy on the named natives and on `Citizen.InvokeNative` by hash |
| Sending data to an unapproved host | same |
| Reaching an approved host and being redirected elsewhere | redirects are not followed unless granted |
| Reaching localhost, the cloud metadata address or private ranges | refused whatever the lockfile says |
| Running text received by any channel (net event, HTTP handler, file, KVP) | `load` needs `dynamic_code`; others get `nil, message` |
| Running Lua bytecode | binary chunks refused in every mode |
| Recovering the real natives through `debug.getupvalue` on system scripts or native stubs | refused for `@citizen:/...` and `@Name.lua` sources, and for torii's own functions |
| Replacing a native by a fresh copy (`Citizen.LoadNative`) | returns the wrapper |
| Smuggling a different URL through a table with metamethods | the request is copied with `rawget`, each field read once |
| Removing torii by rewriting its own manifest at runtime | `SaveResourceFile` on `fxmanifest.lua` / `__resource.lua` refused (including trailing dot, space and `::$DATA` spellings) |
| Starting a resource that has server code but no torii line | manifest gate on `onResourceStarting` |

## What torii reports but does not stop

Reads of secret-looking convars (names only), `ExecuteCommand` (command name only), `SetHttpHandler`
registrations, writes to code files, direct `InvokeNative` use on sensitive hashes, declarations that were not
approved or changed after approval, protected resources that never reported in (attestation).

## What torii does NOT stop

* **JavaScript and C# server code.** Only flagged. FXServer's own Node sandbox restricts child processes, worker
  threads and file writes, but network access and `eval` remain open there.
* **Harm without network or dynamic code**: hidden admin commands, backdoored events, economy exploits, SQL through
  a trusted database export.
* **Exfiltration through other channels**: `TriggerClientEvent` to the attacker's own client, a trusted resource's
  exports (Discord logs, database).
* **Confused deputies**: calling a more privileged resource. If that resource is protected too, its own policy
  applies, but the log will name the deputy.
* **Approved hosts that are malicious or compromised**, and user-content hosts approved without care
  (torii warns, it cannot judge).
* **Anything outside the Lua VM boundary**: a memory-corruption bug in FXServer or Lua. torii runs in the same VM
  as the code it guards; it closes the bypasses listed above but is not a hard sandbox. A determined attacker who
  finds a new way to reach the original natives defeats the in-state wrappers.
* **Attackers with access to the host, `server.cfg`, txAdmin or the `torii` folder.** Cross-resource writes are
  denied by FXServer by default on current builds, but that protection is configured in `server.cfg`
  (`add_filesystem_permission`) and does not exist on old artifacts.
* **Resources installed without the torii line** while in observe mode (they are reported, not stopped).
* Disguises that need no tampering: a hostile resource may notice torii and stay dormant while it is present.

## Known weak spots and open questions

* **Reports are self-reported.** A protected resource reports about itself through an export; the core attributes
  it with `GetInvokingResource()`, so a resource cannot blame another one, but a hostile resource can forge its own
  events (for example fake "would block" lines for an attacker host). `torii approve --from-logs` therefore only
  *suggests* grants; the diff must be read line by line. Control characters are stripped before anything is logged
  or printed.

* The torii line is a *request to be protected*; a missing or unreadable `@torii/init.lua` makes FXServer print
  `Failed to load script` and start the resource anyway (verified). The manifest gate and the attestation check
  are what turn that into an alert (or a refusal in enforce mode).
* Differences between our URL parser and libcurl's would be a policy bypass. The parser is deliberately
  stricter than curl (it rejects instead of interpreting); `spec/url_spec.lua` lists the cases covered.
* Asset-escrow (`.fxap`) resources have not been tested with the manifest edit.
* Wildcard hosts, per-resource rate limits and export filtering are not in v0.1.
