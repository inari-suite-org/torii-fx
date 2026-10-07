#!/usr/bin/env python3
"""Builds assets/demo.svg: an animated replay of a real console session.

The lines come from docs/demo.md (FXServer build 36897 running demo/torii_demo_backdoor). Each line fades in
in sequence and the loop restarts. The other brand assets are produced by the group's logo kit, see docs/brand.md.

    python scripts/build_demo.py
"""
import pathlib

OUT = pathlib.Path(__file__).resolve().parent.parent / 'assets' / 'demo.svg'

MONO = "ui-monospace, SFMono-Regular, Menlo, Consolas, 'Liberation Mono', monospace"
SANS = "'Geist', 'Segoe UI', system-ui, Helvetica, Arial, sans-serif"

BG, BAR, MUTED = '#121A1A', '#1B2523', '#8C9792'
COLORS = {'cmd': '#F5F3EA', 'note': '#8C9792', 'demo': '#B8B4A4', 'warn': '#E8B04A', 'bad': '#E8664B'}

TRANSCRIPT = [
    ('cmd', '> ensure torii_demo_backdoor'),
    ('note', 'observe mode (default): nothing is blocked, everything is reported'),
    ('demo', '[demo]  attempt 1: PerformHttpRequest, then load  (the classic loader)'),
    ('warn', '[torii] WOULD BLOCK  torii_demo_backdoor  http -> https://cipher-demo.invalid/payload.lua'),
    ('demo', '[demo]  attempt 3: call the HTTP native by its hash'),
    ('warn', '[torii] WOULD BLOCK  torii_demo_backdoor  http InvokeNative(...) -> https://cipher-demo.invalid/via-invoke-native'),
    ('demo', '[demo]  attempt 5: rewrite my own manifest'),
    ('warn', '[torii] WOULD BLOCK  torii_demo_backdoor  manifest_write  at server.lua:44'),
    ('cmd', '> set torii_mode "enforce"'),
    ('cmd', '> restart torii_demo_backdoor'),
    ('bad', '[torii] BLOCKED  http -> https://cipher-demo.invalid/payload.lua  (resource_not_in_lockfile)'),
    ('demo', '[demo]  callback received status=0 body=nil'),
    ('bad', '[torii] BLOCKED  dynamic_code load -> chunk'),
    ('demo', '[demo]  load returned: refused: torii: dynamic code execution is not permitted'),
    ('bad', '[torii] BLOCKED  http InvokeNative(...) -> https://cipher-demo.invalid/via-invoke-native'),
    ('demo', '[demo]  InvokeNative returned request id -1'),
    ('bad', '[torii] BLOCKED  manifest_write  SaveResourceFile returned false'),
]


def esc(text):
    return text.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')


def build():
    line_h, top, left = 26, 78, 28
    height = top + line_h * len(TRANSCRIPT) + 30
    step, lead, tail = 1.5, 1.0, 4.0
    total = lead + step * len(TRANSCRIPT) + tail
    rules, nodes = [], []
    for i, (kind, text) in enumerate(TRANSCRIPT):
        start = lead + step * i
        p0, p1 = start / total * 100, (start + 0.25) / total * 100
        rules.append(
            f'@keyframes l{i}{{0%{{opacity:0}}{p0:.2f}%{{opacity:0}}{p1:.2f}%{{opacity:1}}96%{{opacity:1}}100%{{opacity:0}}}}'
            f'.l{i}{{animation:l{i} {total:.1f}s linear infinite;opacity:0}}'
        )
        weight = ' font-weight="700"' if kind == 'bad' else ''
        nodes.append(f'<text class="l{i}" x="{left}" y="{top + line_h * i}" fill="{COLORS[kind]}"{weight}>{esc(text)}</text>')
    # with reduced motion every line is simply visible
    still = '@media (prefers-reduced-motion:reduce){text{animation:none!important;opacity:1!important}}'
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1000 {height}" width="1000" height="{height}" role="img" aria-label="Replay of a real console session: torii first reports, then blocks, a demo remote-code loader">
  <title>torii demo: observe mode, then enforce mode</title>
  <style>text{{font-family:{MONO};font-size:14.5px;white-space:pre}}{''.join(rules)}{still}</style>
  <rect width="1000" height="{height}" rx="20" fill="{BG}"/>
  <path d="M0 20a20 20 0 0 1 20-20h960a20 20 0 0 1 20 20v26H0z" fill="{BAR}"/>
  <text x="28" y="29" fill="{MUTED}" style="font-family:{SANS};font-size:13px;animation:none;opacity:1">FXServer console, build 36897. Abridged replay of docs/demo.md</text>
  {chr(10).join('  ' + n for n in nodes)}
</svg>
'''


if __name__ == '__main__':
    OUT.write_text(build(), encoding='utf-8', newline='\n')
    print('wrote', OUT)
