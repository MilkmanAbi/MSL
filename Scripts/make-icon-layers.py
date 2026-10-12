#!/usr/bin/env python3
"""Makes the foreground layer for each Icon Composer icon (Resources/Icons/*.icon).

The logos stay exactly as drawn; this only trims them and centres them on the
1024-point icon canvas at Apple's recommended content size, so the system's
squircle, glass and dark/clear/tinted treatments frame them evenly. Run by hand
when a logo changes (needs Pillow); the build only needs the .icon folders.
"""
import sys
from PIL import Image

CANVAS = 1024
CONTENT = 700  # longest side of the logo on the canvas

def layer(source, dest, content=CONTENT, nudge=(0, 0)):
    logo = Image.open(source).convert("RGBA")
    logo = logo.crop(logo.getbbox())
    scale = content / max(logo.size)
    logo = logo.resize((round(logo.width * scale), round(logo.height * scale)), Image.LANCZOS)
    out = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    out.paste(logo, ((CANVAS - logo.width) // 2 + nudge[0], (CANVAS - logo.height) // 2 + nudge[1]), logo)
    out.save(dest)

if __name__ == "__main__":
    layer("Assets/App_Logo.png", "Resources/Icons/MSL.icon/Assets/melon.png")
    layer("Assets/MSL_Files_Logo.png", "Resources/Icons/MSLFiles.icon/Assets/folder.png", content=760)
