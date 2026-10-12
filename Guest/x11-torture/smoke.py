import sys; sys.path.insert(0, "/mnt/mac/Desktop/MSL-Project/Actual-Project/MSL/Guest/x11-torture")
from xwire import *
c = Conn()
print("root=0x%x depth=%d size=%dx%d id_base=0x%x mask=0x%x formats=%s visuals=%s" % (
    c.root, c.root_depth, c.width, c.height, c.id_base, c.id_mask, c.formats, {d: len(v) for d, v in c.visuals.items()}))
print("sync errors:", c.sync())
p = c.create_pixmap(8, 8)
g = c.create_gc(p, {GCv.Foreground: 0x112233})
c.fill_rects(p, g, [(0, 0, 8, 8)])
c.change_gc(g, {GCv.Foreground: 0xFF0000})
c.fill_rects(p, g, [(2, 2, 2, 2)])
rows = c.pixels24(p, 0, 0, 8, 8)
print("pixel(0,0)=%06x pixel(2,2)=%06x pixel(4,4)=%06x" % (rows[0][0], rows[2][2], rows[4][4]))
print("errors:", c.sync(), "big-requests:", c.enable_big_requests())
