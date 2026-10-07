# Contributing

Thanks for helping. torii is a security tool: **honesty about limits matters more than features**. If a change
makes a claim in the README or the threat model untrue, update those too.

## Setup

* Lua 5.4, `busted`, `luacheck` (`luarocks install busted luacheck`), [StyLua](https://github.com/JohnnyMorganz/StyLua).
* Node.js 18+ (CLI tests use the built-in `node:test`; there are no runtime dependencies).

```bash
busted                       # Lua unit tests, natives are simulated
luacheck . && stylua --check torii spec
npm test                     # CLI tests
```

## Rules

* Code and comments in English. Small commits with clear messages.
* Every behaviour change in `torii/src` needs a `busted` test, and every bypass fix needs a test that **fails
  without the fix**.
* `torii/src/*.lua` run inside a hostile Lua state: capture the standard functions you use in locals at load time
  (`local find = string.find`), never call methods on strings (`s:find`), and never raise errors from reporting.
* Never log secrets (bodies, headers, query strings, long path segments, convar values, command arguments).
* New FXServer behaviour claims must be checked against FXServer source or on a real server first. Record what you
  verified in `docs/experiments-results.md`; label anything else as an assumption.
* The declaration hash is implemented twice (`torii/src/policy.lua`, `cli/lib/declaration.mjs`); a shared test
  vector keeps them in sync.

## Demo and test resources

`demo/torii_demo_backdoor` must stay harmless: reserved `.invalid` domain, no real payload. Never add real
malicious code to this repository, not even for tests.
