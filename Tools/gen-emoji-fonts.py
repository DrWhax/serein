# Converts Signal's emoji fonts (trusted build inputs) from CBDT/CBLC colour bitmaps, which
# CoreText does not draw, to Apple's sbix: the same PNG strikes and glyph metrics in the table
# CoreText reads. Inputs: Signal-Desktop/fonts/emoji.woff2 ("Signal Emoji Small", 32ppem) and
# Signal's large font (desktop-32-64-v2.0.4.woff2, 32 + 64ppem; fetched by gen-fonts.sh, pinned
# by SHA-256). Run with the fontTools venv: .cache/pyenv/bin/python -I Tools/gen-emoji-fonts.py
import sys
from fontTools.ttLib import TTFont, newTable
from fontTools.ttLib.tables._s_b_i_x import table__s_b_i_x
from fontTools.ttLib.tables.sbixStrike import Strike
from fontTools.ttLib.tables.sbixGlyph import Glyph

def convert(src, dst, family):
    font = TTFont(src)
    font.flavor = None
    cblc, cbdt = font['CBLC'], font['CBDT']
    sbix = newTable('sbix')
    sbix.version = 1
    sbix.flags = 1
    sbix.strikes = {}
    order = font.getGlyphOrder()
    for strike, data in zip(cblc.strikes, cbdt.strikeData):
        ppem = strike.bitmapSizeTable.ppemY
        s = Strike(ppem=ppem, resolution=72)
        for name in order:
            s.glyphs[name] = Glyph(glyphName=name)    # empty entry for glyphs without a bitmap
        for name, g in data.items():
            g.decompile()
            m = g.metrics
            # CBDT: BearingX / BearingY from the glyph origin to the bitmap's top-left.
            # sbix: originOffset from the glyph origin to the bitmap's bottom-left.
            s.glyphs[name] = Glyph(glyphName=name, graphicType='png ', imageData=g.imageData,
                                   originOffsetX=m.BearingX, originOffsetY=m.BearingY - m.height)
        sbix.strikes[ppem] = s
    del font['CBLC']
    del font['CBDT']
    font['sbix'] = sbix
    # A distinct family name so CoreText does not confuse the two fonts.
    for rec in font['name'].names:
        if rec.nameID in (1, 4, 16):
            rec.string = family
        elif rec.nameID == 6:
            rec.string = family.replace(' ', '')
    font.save(dst)

out = sys.argv[1] if len(sys.argv) > 1 else 'Packages/SignalUI/Sources/SignalUI/Resources/Fonts'
convert('Signal-Desktop/fonts/emoji.woff2', f'{out}/SignalEmojiSmall.ttf', 'Signal Emoji Small')
convert('.cache/emoji-font/desktop-32-64-v2.0.4.woff2', f'{out}/SignalEmojiLarge.ttf', 'Signal Emoji Large')
print('emoji fonts: ok')
