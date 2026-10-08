"""Summarises a compatibility run produced by run.sh: crashes, memory trend, blocks, script errors, load counters."""
import json
import pathlib
import re
import sys

out = pathlib.Path(sys.argv[1])
ANSI = re.compile(r"\x1b\[[0-9;]*m")
EXPECTED_BLOCKS = {("torii_compat_load", "https://not-approved.invalid/x")}


def slope(points):
    """Least-squares slope of memory over time, in MB per hour."""
    if len(points) < 3:
        return float("nan")
    xs = [p[0] / 3600 for p in points]
    ys = [p[1] / 1024 for p in points]
    mx, my = sum(xs) / len(xs), sum(ys) / len(ys)
    den = sum((x - mx) ** 2 for x in xs)
    return sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / den if den else float("nan")


print("# Compatibility run summary\n")
print("Development server, no players. This does not describe behaviour with real players.\n")
print("```")
print((out / "run.txt").read_text(encoding="utf-8").strip())
print("```\n")

rows = [line.split(",") for line in (out / "memory.csv").read_text(encoding="utf-8").split() if line]
print("| phase | samples | first MB | last MB | trend after 10 min (MB/hour) | exited early |")
print("|---|---|---|---|---|---|")
for phase in ("observe", "enforce"):
    pts = [(int(t), int(kb)) for t, p, kb in rows if p == phase and kb.isdigit()]
    dead = any(p == phase and kb == "DEAD" for t, p, kb in rows)
    if not pts:
        print(f"| {phase} | 0 | | | | {dead} |")
        continue
    t0 = pts[0][0]
    rel = [(t - t0, kb) for t, kb in pts]
    warm = [p for p in rel if p[0] >= 600]
    print(f"| {phase} | {len(pts)} | {pts[0][1] / 1024:.0f} | {pts[-1][1] / 1024:.0f} | {slope(warm):+.2f} | {dead} |")

for phase in ("observe", "enforce"):
    console = out / f"{phase}.console.log"
    if not console.exists():
        continue
    text = ANSI.sub("", console.read_text(encoding="utf-8", errors="replace"))
    errors = [l for l in text.splitlines() if "SCRIPT ERROR" in l]
    stats = [l for l in text.splitlines() if "[compat] STATS" in l]
    print(f"\n## {phase}\n")
    print(f"- SCRIPT ERROR lines: {len(errors)}")
    for line in sorted(set(errors))[:10]:
        print(f"  - `{line.strip()[:200]}`")
    if stats:
        print(f"- last load counters: `{stats[-1].split('STATS', 1)[1].strip()}`")
        print(f"- STATS lines (one per minute): {len(stats)}")

    log = out / f"{phase}.torii.jsonl"
    if log.exists():
        blocked, by = 0, {}
        for line in log.read_text(encoding="utf-8").splitlines():
            try:
                e = json.loads(line)
            except ValueError:
                continue
            if e.get("decision") in ("deny", "would_deny"):
                key = (e.get("resource"), e.get("type"), e.get("target"), e.get("reason"))
                by[key] = by.get(key, 0) + 1
                blocked += 1
        label = "blocked" if phase == "enforce" else "would block"
        print(f"- torii events ({label}), deduplicated per 30 s: {blocked}")
        for (res, typ, target, reason), n in sorted(by.items(), key=lambda kv: -kv[1])[:25]:
            expected = (res, target) in EXPECTED_BLOCKS
            note = " (expected)" if expected else (" **FALSE POSITIVE?**" if phase == "enforce" else "")
            print(f"  - {res} {typ} `{target}` ({reason}) x{n}{note}")
