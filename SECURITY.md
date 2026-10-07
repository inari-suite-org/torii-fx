# Security policy

torii is a security tool, so its own flaws matter. In particular, **a way for a resource to bypass torii is a
vulnerability**, even if it is only possible from inside the Lua VM.

## Reporting

Please report privately and do not open a public issue:

* Use GitHub's **private vulnerability reporting** ("Security" tab, "Report a vulnerability") on this repository.
* Include: the FXServer build (`version` in the console), your `torii_mode`, a minimal resource that shows the
  bypass, and what you expected torii to do. A failing `busted` test is perfect.

You will get an acknowledgement within 7 days and a status update within 30 days. Please give us a reasonable
time to ship a fix before disclosing publicly; we will credit you in the release notes unless you prefer not to.

## Scope

In scope: bypasses of the HTTP or dynamic-code policy, ways to read the original natives, ways to remove or
disable torii from a protected resource, log forging or flooding, secrets leaking into logs, bugs in the URL
parser that make a denied URL pass, lockfile parsing problems, the CLI rewriting files outside the resources folder.

Out of scope (already documented in [docs/threat-model.md](docs/threat-model.md)): JavaScript / C# resources,
malicious logic that uses neither network nor dynamic code, attackers who already control the host or `server.cfg`.

## Supported versions

Only the latest release.
