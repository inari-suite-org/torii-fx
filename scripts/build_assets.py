#!/usr/bin/env python3
"""Generates the torii logo, banner, animated demo and PNG exports into assets/.

    python scripts/build_assets.py            # SVGs only
    python scripts/build_assets.py --png      # also PNGs (needs `pip install pymupdf`)

The mark is derived from the group's logo (circle, kasagi, red pillars, kitsune eyes): same palette,
same proportions, with the fox reduced to the two eyes that watch the gate.
"""
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / 'assets'
LOGO = OUT / 'logo'

INK, PAPER, VERMILION = '#131B19', '#F5F2E8', '#C8442B'
MUTED_ON_DARK, MUTED_ON_LIGHT = '#9AA39F', '#5B6662'

LIGHT = dict(bg=PAPER, ring=INK, kasagi=INK, gate=VERMILION, eyes=VERMILION, ground=INK)
DARK = dict(bg=INK, ring=PAPER, kasagi=PAPER, gate=VERMILION, eyes=VERMILION, ground=PAPER)
MONO = dict(bg=None, ring=INK, kasagi=INK, gate=INK, eyes=INK, ground=INK, mono=True)
TRANSPARENT_LIGHT = dict(LIGHT, bg=None)


def mark_body(c, eyes=True, detail=True):
    """Drawing of the mark on a 1024x1024 canvas (no <svg> wrapper)."""
    parts = []
    parts.append(f'<circle cx="512" cy="512" r="400" fill="none" stroke="{c["ring"]}" stroke-width="28"/>')
    # knock the ring out behind the kasagi so the beam reads as one shape (as in the group logo)
    if c['bg']:
        parts.append(f'<path d="M142 208 Q512 318 882 208 L862 250 Q512 360 164 250 Z" fill="none" stroke="{c["bg"]}" stroke-width="30" stroke-linejoin="round"/>')
    parts.append(f'<rect x="198" y="270" width="628" height="32" fill="{c["gate"]}"/>')  # shimaki (red band under the beam)
    parts.append(f'<path d="M142 208 Q512 318 882 208 L862 250 Q512 360 164 250 Z" fill="{c["kasagi"]}"/>')  # kasagi
    if not c.get('mono') and eyes:
        parts.append(f'<rect x="320" y="410" width="384" height="382" fill="{INK}"/>')  # the dark behind the gate
    parts.append(f'<polygon points="282,300 332,300 332,792 264,792" fill="{c["gate"]}"/>')  # left pillar
    parts.append(f'<polygon points="692,300 742,300 760,792 692,792" fill="{c["gate"]}"/>')  # right pillar
    parts.append(f'<rect x="212" y="384" width="600" height="26" fill="{c["gate"]}"/>')  # nuki (tie beam)
    parts.append(f'<rect x="488" y="310" width="48" height="76" fill="{c["gate"]}"/>')  # gakuzuka (centre strut)
    parts.append(f'<rect x="252" y="792" width="520" height="12" fill="{c["ground"]}"/>')
    if detail:
        parts.append(f'<rect x="268" y="816" width="488" height="8" fill="{c["ground"]}"/>')
    left_eye = 'M392 540 C420 548 456 562 480 588 C444 592 408 578 392 540 Z'
    right_eye = 'M632 540 C604 548 568 562 544 588 C580 592 616 578 632 540 Z'
    if eyes and c.get('mono'):
        # one colour only: a solid panel with the eyes cut out of it
        parts.append(f'<path fill-rule="evenodd" fill="{c["ring"]}" d="M334 410 H690 V792 H334 Z {left_eye} {right_eye}"/>')
    elif eyes:
        # the gate opens on the dark; a faint fox head watches from inside it
        head = 'M392 520 L418 440 L470 500 Q512 488 554 500 L606 440 L632 520 Q640 600 560 680 L512 720 L464 680 Q384 600 392 520 Z'
        parts.append(f'<path d="{head}" fill="#212E2A"/>')
        parts.append(f'<path d="{left_eye}" fill="{c["eyes"]}"/>')
        parts.append(f'<path d="{right_eye}" fill="{c["eyes"]}"/>')
    return '\n  '.join(parts)


def mark_svg(c, size=1024, eyes=True, detail=True, title='torii'):
    bg = f'<rect width="1024" height="1024" fill="{c["bg"]}"/>\n  ' if c['bg'] else ''
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="{size}" height="{size}" role="img" aria-label="{title}">\n'
        f'  <title>{title}</title>\n  {bg}{mark_body(c, eyes, detail)}\n</svg>\n'
    )


def favicon_svg():
    """Simplified for 16-64 px: heavier strokes, no ground lines."""
    c = dict(LIGHT)
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" role="img" aria-label="torii">\n'
        f'  <rect width="1024" height="1024" rx="200" fill="{INK}"/>\n'
        f'  <path d="M120 232 Q512 372 904 232 L880 292 Q512 432 144 292 Z" fill="{PAPER}"/>\n'
        f'  <polygon points="262,330 352,330 352,830 240,830" fill="{VERMILION}"/>\n'
        f'  <polygon points="672,330 762,330 784,830 672,830" fill="{VERMILION}"/>\n'
        f'  <rect x="190" y="440" width="644" height="48" fill="{VERMILION}"/>\n'
        f'  <path d="M404 600 C436 610 470 626 494 656 C456 662 416 646 404 600 Z" fill="{PAPER}"/>\n'
        f'  <path d="M620 600 C588 610 554 626 530 656 C568 662 608 646 620 600 Z" fill="{PAPER}"/>\n'
        '</svg>\n'
    )


def horizontal_svg(dark):
    c = DARK if dark else TRANSPARENT_LIGHT
    text = PAPER if dark else INK
    sub = MUTED_ON_DARK if dark else MUTED_ON_LIGHT
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1180 300" width="1180" height="300" role="img" aria-label="torii">\n'
        '  <title>torii</title>\n'
        f'  <g transform="translate(10 10) scale(0.2734)">\n  {mark_body(c)}\n  </g>\n'
        f'  <text x="330" y="182" font-family="Inter, \'Segoe UI\', system-ui, Helvetica, Arial, sans-serif" font-size="150" font-weight="800" letter-spacing="-3" fill="{text}">torii</text>\n'
        f'  <text x="334" y="236" font-family="Inter, \'Segoe UI\', system-ui, Helvetica, Arial, sans-serif" font-size="30" font-weight="500" letter-spacing="6" fill="{sub}">PERMISSION FIREWALL FOR FIVEM LUA</text>\n'
        '</svg>\n'
    )


MONO_FONT = "ui-monospace, SFMono-Regular, Menlo, Consolas, 'Liberation Mono', monospace"
SANS_FONT = "Inter, 'Segoe UI', system-ui, Helvetica, Arial, sans-serif"


def banner_svg(dark):
    bg = INK if dark else PAPER
    text = PAPER if dark else INK
    sub = MUTED_ON_DARK if dark else MUTED_ON_LIGHT
    c = DARK if dark else TRANSPARENT_LIGHT
    card = '#0C1211' if dark else '#1B2523'
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1280 420" width="1280" height="420" role="img" aria-label="torii: a runtime permission firewall for FiveM server-side Lua resources">
  <title>torii: a runtime permission firewall for FiveM server-side Lua resources</title>
  <rect width="1280" height="420" rx="28" fill="{bg}"/>
  <rect x="0" y="392" width="1280" height="28" fill="{VERMILION}" opacity="0.95"/>
  <g transform="translate(46 56) scale(0.3125)">
  {mark_body(c)}
  </g>
  <text x="400" y="178" font-family="{SANS_FONT}" font-size="112" font-weight="800" letter-spacing="-3" fill="{text}">torii</text>
  <text x="404" y="226" font-family="{SANS_FONT}" font-size="25" font-weight="700" fill="{text}">Least privilege for FiveM resources.</text>
  <text x="404" y="266" font-family="{SANS_FONT}" font-size="19" fill="{sub}">Declare. Approve. Enforce. Backdoors have to knock.</text>
  <g font-family="{SANS_FONT}" font-size="18" font-weight="700">
    <rect x="404" y="298" width="132" height="40" rx="20" fill="{VERMILION}"/><text x="470" y="324" text-anchor="middle" fill="{PAPER}">observe</text>
    <rect x="548" y="298" width="132" height="40" rx="20" fill="none" stroke="{VERMILION}" stroke-width="2"/><text x="614" y="324" text-anchor="middle" fill="{VERMILION}">enforce</text>
    <rect x="692" y="298" width="132" height="40" rx="20" fill="none" stroke="{sub}" stroke-width="2"/><text x="758" y="324" text-anchor="middle" fill="{sub}">MIT</text>
  </g>
  <g transform="translate(900 62)">
    <rect width="340" height="268" rx="16" fill="{card}"/>
    <circle cx="26" cy="26" r="7" fill="#FF5F57"/><circle cx="48" cy="26" r="7" fill="#FEBC2E"/><circle cx="70" cy="26" r="7" fill="#28C840"/>
    <g font-family="{MONO_FONT}" font-size="13.5">
      <text x="22" y="72" fill="#7F8A86">$ ensure shop_v2</text>
      <text x="22" y="104" fill="#E8B04A">WOULD BLOCK</text>
      <text x="128" y="104" fill="#D9DDDB">http -&gt; cipher-panel.example</text>
      <text x="22" y="136" fill="#7F8A86">$ set torii_mode "enforce"</text>
      <text x="22" y="168" fill="#FF6B57" font-weight="700">BLOCKED</text>
      <text x="104" y="168" fill="#D9DDDB">http -&gt; cipher-panel.example</text>
      <text x="22" y="198" fill="#FF6B57" font-weight="700">BLOCKED</text>
      <text x="104" y="198" fill="#D9DDDB">load() of downloaded text</text>
      <text x="22" y="228" fill="#6FCF97">ALLOWED</text>
      <text x="104" y="228" fill="#D9DDDB">api.weather.example/v1</text>
    </g>
  </g>
</svg>
'''


# Animated terminal (CSS animation inside an SVG <img>): replays a REAL console transcript from FXServer
# build 36897 running demo/torii_demo_backdoor (see docs/demo.md).
TRANSCRIPT = [
    ('cmd', '> ensure torii'),
    ('cmd', '> ensure torii_demo_backdoor'),
    ('note', '# observe mode (default): nothing is blocked, everything is reported'),
    ('demo', '[demo]  attempt 1: PerformHttpRequest + load  (the classic loader)'),
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
    ('bad', '[torii] BLOCKED  manifest_write  SaveResourceFile -> returned false'),
]
LINE_COLORS = {'cmd': '#D9DDDB', 'note': '#7F8A86', 'demo': '#B49CF0', 'warn': '#E8B04A', 'bad': '#FF6B57'}


def demo_svg():
    line_h, top, left = 26, 74, 28
    height = top + line_h * len(TRANSCRIPT) + 34
    total = 2.0 + 1.55 * len(TRANSCRIPT) + 4.0  # seconds per loop
    rules, nodes = [], []
    for i, (kind, text) in enumerate(TRANSCRIPT):
        start = 1.0 + 1.55 * i
        p0, p1 = start / total * 100, (start + 0.25) / total * 100
        rules.append(
            f'@keyframes l{i}{{0%{{opacity:0}}{p0:.2f}%{{opacity:0}}{p1:.2f}%{{opacity:1}}96%{{opacity:1}}100%{{opacity:0}}}}'
            f'.l{i}{{animation:l{i} {total:.1f}s linear infinite;opacity:0}}'
        )
        weight = ' font-weight="700"' if kind == 'bad' else ''
        escaped = text.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')
        nodes.append(f'<text class="l{i}" x="{left}" y="{top + line_h * i}" fill="{LINE_COLORS[kind]}"{weight}>{escaped}</text>')
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1000 {height}" width="1000" height="{height}" role="img" aria-label="Replay of a real console session: torii first reports, then blocks, a demo remote-code loader">
  <title>torii demo: observe mode, then enforce mode</title>
  <style>text{{font-family:{MONO_FONT};font-size:14.5px;white-space:pre}}{''.join(rules)}</style>
  <rect width="1000" height="{height}" rx="16" fill="#0C1211"/>
  <rect width="1000" height="44" rx="16" fill="#18201E"/><rect y="28" width="1000" height="16" fill="#18201E"/>
  <circle cx="26" cy="22" r="7" fill="#FF5F57"/><circle cx="48" cy="22" r="7" fill="#FEBC2E"/><circle cx="70" cy="22" r="7" fill="#28C840"/>
  <text x="500" y="27" text-anchor="middle" fill="#7F8A86" style="font-family:{SANS_FONT};font-size:13px">FXServer console, build 36897: demo/torii_demo_backdoor (abridged replay of the real output in docs/demo.md)</text>
  {chr(10).join('  ' + n for n in nodes)}
</svg>
'''


def social_svg():
    """1280x640 social preview (GitHub repository card)."""
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1280 640" width="1280" height="640">
  <rect width="1280" height="640" fill="{INK}"/>
  <rect y="600" width="1280" height="40" fill="{VERMILION}"/>
  <g transform="translate(90 96) scale(0.4)">{mark_body(DARK)}</g>
  <text x="560" y="300" font-family="{SANS_FONT}" font-size="150" font-weight="800" letter-spacing="-4" fill="{PAPER}">torii</text>
  <text x="566" y="368" font-family="{SANS_FONT}" font-size="36" font-weight="600" fill="{PAPER}">Least privilege for FiveM resources.</text>
  <text x="566" y="424" font-family="{SANS_FONT}" font-size="28" fill="{MUTED_ON_DARK}">Runtime permission firewall for server-side Lua.</text>
  <text x="566" y="474" font-family="{SANS_FONT}" font-size="28" fill="{MUTED_ON_DARK}">Declare. Approve. Enforce.  MIT.</text>
</svg>
'''


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding='utf-8', newline='\n')


def main():
    write(LOGO / 'torii-mark.svg', mark_svg(LIGHT))
    write(LOGO / 'torii-mark-transparent.svg', mark_svg(TRANSPARENT_LIGHT))
    write(LOGO / 'torii-mark-dark.svg', mark_svg(DARK))
    write(LOGO / 'torii-mark-mono.svg', mark_svg(MONO))
    write(LOGO / 'torii-favicon.svg', favicon_svg())
    write(LOGO / 'torii-logo-horizontal.svg', horizontal_svg(False))
    write(LOGO / 'torii-logo-horizontal-dark.svg', horizontal_svg(True))
    write(OUT / 'banner-light.svg', banner_svg(False))
    write(OUT / 'banner-dark.svg', banner_svg(True))
    write(OUT / 'demo.svg', demo_svg())
    write(OUT / 'social-preview.svg', social_svg())

    if '--png' in sys.argv:
        import fitz  # PyMuPDF

        def png(svg_path, png_path, width):
            doc = fitz.open(str(svg_path))
            page = doc[0]
            zoom = width / page.rect.width
            page.get_pixmap(matrix=fitz.Matrix(zoom, zoom), alpha=True).save(str(png_path))

        png(LOGO / 'torii-mark.svg', LOGO / 'torii-mark-512.png', 512)
        png(LOGO / 'torii-mark-dark.svg', LOGO / 'torii-mark-dark-512.png', 512)
        png(LOGO / 'torii-mark-transparent.svg', LOGO / 'torii-mark-transparent-512.png', 512)
        png(LOGO / 'torii-favicon.svg', LOGO / 'torii-favicon-128.png', 128)
        png(OUT / 'social-preview.svg', OUT / 'social-preview.png', 1280)
    print('assets written to', OUT)


if __name__ == '__main__':
    main()
