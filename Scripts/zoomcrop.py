#!/usr/bin/env python3
"""Crop a region of a screenshot and blow it up with NO smoothing.

For looking at tiny rendering defects (a cursor, a 1px outline) where a
normal resample would blur exactly the pixels in question.

Usage: zoomcrop.py SCREENSHOT.png CX CY [HALF=24] [SCALE=12] [OUT]
  CX, CY are macOS screen POINTS (what input_sim.py uses); the screenshot is
  assumed Retina (2 px per point).
"""
import sys
import Quartz
from Foundation import NSURL

src, cx, cy = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
half = int(sys.argv[4]) if len(sys.argv) > 4 else 24
scale = int(sys.argv[5]) if len(sys.argv) > 5 else 12
out = sys.argv[6] if len(sys.argv) > 6 else src.replace(".png", f"_zoom_{int(cx)}_{int(cy)}.png")

isrc = Quartz.CGImageSourceCreateWithURL(NSURL.fileURLWithPath_(src), None)
img = Quartz.CGImageSourceCreateImageAtIndex(isrc, 0, None)
px = 2  # Retina
rect = Quartz.CGRectMake((cx - half) * px, (cy - half) * px, 2 * half * px, 2 * half * px)
crop = Quartz.CGImageCreateWithImageInRect(img, rect)
w, h = Quartz.CGImageGetWidth(crop), Quartz.CGImageGetHeight(crop)
cs = Quartz.CGColorSpaceCreateDeviceRGB()
ctx = Quartz.CGBitmapContextCreate(None, w * scale, h * scale, 8, 0, cs,
                                   Quartz.kCGImageAlphaPremultipliedLast)
Quartz.CGContextSetInterpolationQuality(ctx, Quartz.kCGInterpolationNone)
Quartz.CGContextDrawImage(ctx, Quartz.CGRectMake(0, 0, w * scale, h * scale), crop)
big = Quartz.CGBitmapContextCreateImage(ctx)
dest = Quartz.CGImageDestinationCreateWithURL(NSURL.fileURLWithPath_(out), "public.png", 1, None)
Quartz.CGImageDestinationAddImage(dest, big, None)
Quartz.CGImageDestinationFinalize(dest)
print(out)
