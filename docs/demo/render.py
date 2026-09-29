#!/usr/bin/env python3
"""Turn tmux `capture-pane -e` frames into a looping animated SVG.

Input: a log of frames, each introduced by a line `@@frame <milliseconds>`.
Every distinct screen line is defined once and frames reference it with <use>, so the
sidebar and other static rows cost nothing per frame. Text runs carry textLength, so the
grid stays exact whatever monospace font the viewer has.
"""
import html
import re
import sys
import unicodedata

COLS, ROWS = int(sys.argv[3]), int(sys.argv[4])
CW, LH, FS = 8.4, 18, 14  # cell width, line height, font size (px)
PAD, TOP = 14, 36  # window padding and title bar height
HOLD_END = 3000  # ms the last frame stays up before the loop restarts
FG, BG = "#cdd6f4", "#11111b"  # Catppuccin Mocha text on crust: Herdr draws dividers in base (#1e1e2e)

BASE16 = ["#45475a", "#f38ba8", "#a6e3a1", "#f9e2af", "#89b4fa", "#f5c2e7", "#94e2d5", "#bac2de",
          "#585b70", "#f38ba8", "#a6e3a1", "#f9e2af", "#89b4fa", "#f5c2e7", "#94e2d5", "#a6adc8"]


def xterm256(n):
    if n < 16:
        return BASE16[n]
    if n < 232:
        n -= 16
        steps = [0, 95, 135, 175, 215, 255]
        return "#%02x%02x%02x" % (steps[n // 36], steps[n // 6 % 6], steps[n % 6])
    v = 8 + (n - 232) * 10
    return "#%02x%02x%02x" % (v, v, v)


def apply_sgr(style, params):
    fg, bg, bold, dim, italic, under, rev = style
    ps = [int(p) if p else 0 for p in params.split(";")] if params else [0]
    i = 0
    while i < len(ps):
        p = ps[i]
        if p == 0:
            fg, bg, bold, dim, italic, under, rev = None, None, False, False, False, False, False
        elif p == 1: bold = True
        elif p == 2: dim = True
        elif p == 3: italic = True
        elif p == 4: under = True
        elif p == 7: rev = True
        elif p == 22: bold = dim = False
        elif p == 23: italic = False
        elif p == 24: under = False
        elif p == 27: rev = False
        elif 30 <= p <= 37: fg = BASE16[p - 30]
        elif 90 <= p <= 97: fg = BASE16[p - 90 + 8]
        elif 40 <= p <= 47: bg = BASE16[p - 40]
        elif 100 <= p <= 107: bg = BASE16[p - 100 + 8]
        elif p == 39: fg = None
        elif p == 49: bg = None
        elif p in (38, 48) and i + 1 < len(ps):
            if ps[i + 1] == 5 and i + 2 < len(ps):
                c, i = xterm256(ps[i + 2]), i + 2
            elif ps[i + 1] == 2 and i + 4 < len(ps):
                c, i = "#%02x%02x%02x" % tuple(ps[i + 2:i + 5]), i + 4
            else:
                c = None
            if p == 38: fg = c
            else: bg = c
        i += 1
    return (fg, bg, bold, dim, italic, under, rev)


def parse_line(line):
    """Cells as (char, style); a wide char occupies its cell and an empty one after it."""
    style = (None,) * 2 + (False,) * 5
    cells = []
    for m in re.finditer(r"\x1b\[([0-9;]*)m|([^\x1b])", line):
        if m.group(1) is not None:
            style = apply_sgr(style, m.group(1))
            continue
        ch = m.group(2)
        cells.append((ch, style))
        if unicodedata.east_asian_width(ch) in "WF":
            cells.append(("", style))
    return cells[:COLS]


def render_line(cells):
    """SVG for one screen row at y=0: background runs, then text runs."""
    out = []
    col = 0
    runs = []  # (start col, width, fg, bg, bold, dim, italic, under, chars: one per cell)
    while col < len(cells):
        ch, (fg, bg, bold, dim, italic, under, rev) = cells[col]
        if rev:
            fg, bg = bg or BG, fg or FG
        key = (fg, bg, bold, dim, italic, under)
        start, chars = col, []
        while col < len(cells):
            c, s = cells[col]
            f, b = (s[1] or BG, s[0] or FG) if s[6] else (s[0], s[1])
            if (f, b) + s[2:6] != key:
                break
            chars.append(c)
            col += 1
        runs.append((start, col - start) + key + (chars,))
    for start, width, fg, bg, *_ in runs:
        if bg and bg != BG:
            out.append('<rect x="%g" width="%g" height="%d" fill="%s"/>' % (start * CW, width * CW, LH, bg))
    for start, width, fg, bg, bold, dim, italic, under, chars in runs:
      # One <text> per stretch of words, single blanks allowed: a run of blanks inside a text
      # element lets browsers that collapse whitespace squeeze its natural width, and
      # textLength then blows the glyphs up. chars has one entry per cell ("" for a wide
      # glyph's second cell), so match positions are cells.
      mask = "".join(" " if c == " " else "x" for c in chars)
      for m in re.finditer(r"x+(?: x+)*", mask):
        body = "".join(chars[m.start():m.end()])
        lead, span = m.start(), m.end() - m.start()
        attrs = ""
        if (fg or FG) != FG: attrs += ' fill="%s"' % (fg or FG)
        if bold: attrs += ' font-weight="bold"'
        if dim: attrs += ' fill-opacity=".55"'
        if italic: attrs += ' font-style="italic"'
        if under: attrs += ' text-decoration="underline"'
        out.append('<text x="%g" y="%g" textLength="%g" lengthAdjust="spacingAndGlyphs"%s>%s</text>'
                   % ((start + lead) * CW, LH - 5, span * CW, attrs, html.escape(body, quote=False)))
    return "".join(out)


def main(src, dst):
    frames = []  # (ms, [row strings])
    for block in open(src, encoding="utf-8", errors="replace").read().split("@@frame ")[1:]:
        head, _, body = block.partition("\n")
        rows = body.split("\n")[:ROWS]
        if not frames or frames[-1][1] != rows:
            frames.append((int(head), rows))
    t0 = frames[0][0]
    total = frames[-1][0] - t0 + HOLD_END

    defs, ids = [], {}
    film = []
    fh = ROWS * LH
    for i, (_, rows) in enumerate(frames):
        uses = []
        for r, row in enumerate(rows):
            svg = render_line(parse_line(row))
            if not svg:
                continue
            if svg not in ids:
                ids[svg] = "l%x" % len(ids)
                defs.append('<g id="%s">%s</g>' % (ids[svg], svg))
            uses.append('<use href="#%s" y="%d"/>' % (ids[svg], r * LH))
        film.append('<g transform="translate(0 %d)">%s</g>' % (i * fh, "".join(uses)))

    keys = "".join("%.3f%%{transform:translateY(%dpx)}" % ((ms - t0) * 100 / total, -i * fh)
                   for i, (ms, _) in enumerate(frames))
    w, h = COLS * CW + 2 * PAD, fh + TOP + PAD
    svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="{w:g}" height="{h}" viewBox="0 0 {w:g} {h}" font-family="ui-monospace,SFMono-Regular,Menlo,Consolas,'Liberation Mono',monospace" font-size="{FS}" fill="{FG}" xml:space="preserve">
<style>text{{white-space:pre}}.film{{animation:play {total}ms step-end infinite}}@keyframes play{{{keys}}}</style>
<defs>{"".join(defs)}</defs>
<rect width="{w:g}" height="{h}" rx="8" fill="{BG}"/>
<circle cx="20" cy="18" r="6" fill="#ff5f57"/><circle cx="40" cy="18" r="6" fill="#febc2e"/><circle cx="60" cy="18" r="6" fill="#28c840"/>
<svg x="{PAD}" y="{TOP}" width="{COLS * CW:g}" height="{fh}"><g class="film">{"".join(film)}</g></svg>
</svg>
'''
    open(dst, "w", encoding="utf-8").write(svg)
    print("%d frames, %d distinct lines, %.1fs" % (len(frames), len(ids), total / 1000))


main(sys.argv[1], sys.argv[2])
