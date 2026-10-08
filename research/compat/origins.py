"""Where the text each resource passed to load() came from, from a torii v0.2 observe log.

    python research/compat/origins.py <torii.jsonl>

For each resource: how many dynamic_code events came from its files (the narrow torii_dynamic_code 'files' level is
enough) and how many from memory (it needs the full grant). The log is deduplicated per 30 s by torii, so counts are
events, not calls. Development server only: real servers may load other things.
"""
import collections
import json
import sys

counts = collections.defaultdict(collections.Counter)
names = collections.defaultdict(set)
with open(sys.argv[1], encoding="utf-8") as log:
    for line in log:
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if event.get("type") != "dynamic_code":
            continue
        resource = event.get("resource", "?")
        origin = event.get("origin", "unknown (v0.1 log)")
        counts[resource][origin] += 1
        if origin != "files":
            names[resource].add(str(event.get("target", ""))[:60])

print(f"{'resource':<24} {'files':>7} {'memory':>7} {'other':>7}  level needed")
for resource in sorted(counts):
    c = counts[resource]
    other = sum(n for origin, n in c.items() if origin not in ("files", "memory"))
    needed = "full" if c["memory"] or other else "'files'"
    print(f"{resource:<24} {c['files']:>7} {c['memory']:>7} {other:>7}  {needed}")
    for target in sorted(names[resource])[:5]:
        print(f"    not from files: {target}")
