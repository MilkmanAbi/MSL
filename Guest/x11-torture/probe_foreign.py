import sys, struct; sys.path.insert(0, "/mnt/mac/Desktop/MSL-Project/Actual-Project/MSL/Guest/x11-torture")
from xwire import *
c = Conn(timeout=4)
own_stale = c.id_base | 0x1234
for name, op, body in [("GetGeometry", Op.GetGeometry, struct.pack("<I", 0x7FFFFFF0)),
                       ("GetGeometry(own stale)", Op.GetGeometry, struct.pack("<I", own_stale)),
                       ("QueryTree", Op.QueryTree, struct.pack("<I", 0x7FFFFFF0)),
                       ("GetProperty", Op.GetProperty, struct.pack("<IIIII", 0x7FFFFFF0, 1, 0, 0, 10)),
                       ("GetWindowAttributes", Op.GetWindowAttributes, struct.pack("<I", 0x7FFFFFF0)),
                       ("GetAtomName(0)", Op.GetAtomName, struct.pack("<I", 0)),
                       ("TranslateCoordinates", Op.TranslateCoordinates, struct.pack("<IIhh", 0x7FFFFFF0, c.root, 0, 0)),
                       ("GetImage", Op.GetImage, struct.pack("<IhhHHI", 0x7FFFFFF0, 0, 0, 1, 1, 0xFFFFFFFF))]:
    try:
        seq = c.request(op, body, detail=2 if op == Op.GetImage else 0)
        r = c.wait_reply(seq)
        print("%-24s REPLY (%d bytes)" % (name, len(r)))
    except XError as e:
        print("%-24s ERROR %s" % (name, e.err.name))
    except Hang:
        print("%-24s *** NO ANSWER (a real client would block forever) ***" % name)
        c = Conn(timeout=4)
