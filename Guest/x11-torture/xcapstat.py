#!/usr/bin/env python3
"""xcapstat - what do real apps actually send? Request histogram of captures.

    python3 xcapstat.py CAPTURE_DIRS...          # per (major, minor): apps using it, count

Extension majors are named from the QueryExtension replies mslgd gives
(fixed numbers, see X11Protocol.swift). Used to decide what xhell must
cover and what mslgd must implement: a request every GTK app sends at
startup matters more than one nothing uses.
"""
import os
import sys
from collections import defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import xreplay  # noqa: E402

CORE = {1: "CreateWindow", 2: "ChangeWindowAttributes", 3: "GetWindowAttributes", 4: "DestroyWindow",
        5: "DestroySubwindows", 6: "ChangeSaveSet", 7: "ReparentWindow", 8: "MapWindow", 9: "MapSubwindows",
        10: "UnmapWindow", 12: "ConfigureWindow", 13: "CirculateWindow", 14: "GetGeometry", 15: "QueryTree",
        16: "InternAtom", 17: "GetAtomName", 18: "ChangeProperty", 19: "DeleteProperty", 20: "GetProperty",
        21: "ListProperties", 22: "SetSelectionOwner", 23: "GetSelectionOwner", 24: "ConvertSelection",
        25: "SendEvent", 26: "GrabPointer", 27: "UngrabPointer", 28: "GrabButton", 29: "UngrabButton",
        31: "GrabKeyboard", 32: "UngrabKeyboard", 33: "GrabKey", 34: "UngrabKey", 35: "AllowEvents",
        36: "GrabServer", 37: "UngrabServer", 38: "QueryPointer", 39: "GetMotionEvents",
        40: "TranslateCoordinates", 41: "WarpPointer", 42: "SetInputFocus", 43: "GetInputFocus",
        44: "QueryKeymap", 45: "OpenFont", 46: "CloseFont", 47: "QueryFont", 48: "QueryTextExtents",
        49: "ListFonts", 50: "ListFontsWithInfo", 51: "SetFontPath", 52: "GetFontPath", 53: "CreatePixmap",
        54: "FreePixmap", 55: "CreateGC", 56: "ChangeGC", 57: "CopyGC", 58: "SetDashes",
        59: "SetClipRectangles", 60: "FreeGC", 61: "ClearArea", 62: "CopyArea", 63: "CopyPlane",
        64: "PolyPoint", 65: "PolyLine", 66: "PolySegment", 67: "PolyRectangle", 68: "PolyArc",
        69: "FillPoly", 70: "PolyFillRectangle", 71: "PolyFillArc", 72: "PutImage", 73: "GetImage",
        74: "PolyText8", 75: "PolyText16", 76: "ImageText8", 77: "ImageText16", 78: "CreateColormap",
        79: "FreeColormap", 84: "AllocColor", 85: "AllocNamedColor", 88: "FreeColors", 91: "QueryColors",
        92: "LookupColor", 93: "CreateCursor", 94: "CreateGlyphCursor", 95: "FreeCursor",
        96: "RecolorCursor", 97: "QueryBestSize", 98: "QueryExtension", 99: "ListExtensions",
        101: "GetKeyboardMapping", 102: "ChangeKeyboardControl", 103: "GetKeyboardControl", 104: "Bell",
        107: "SetScreenSaver", 108: "GetScreenSaver", 115: "ForceScreenSaver", 116: "SetPointerMapping",
        117: "GetPointerMapping", 119: "GetModifierMapping", 127: "NoOperation"}


def main():
    use = defaultdict(lambda: [0, set()])
    for d in sys.argv[1:]:
        app = os.path.basename(d.rstrip("/")).rsplit("-", 1)[0]
        for f in xreplay.session_files([d]):
            _, reqs = xreplay.read_capture(f)
            for q in reqs:
                major, minor = xreplay.key_of(q)
                k = (major, minor if minor is not None else -1)
                use[k][0] += 1
                use[k][1].add(app)
    for (major, minor), (n, apps) in sorted(use.items()):
        name = CORE.get(major, "") if minor < 0 else xreplay.EXT_NAMES.get(major, "ext%d" % major) + " %d" % minor
        print("%3d %3s %-26s %7d  %2d apps  %s" % (major, "" if minor < 0 else minor, name, n, len(apps),
                                                 ",".join(sorted(apps))[:90]))


if __name__ == "__main__":
    main()
