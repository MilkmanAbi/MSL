#!/bin/bash
# What GL does the guest have? Output to the shared folder.
O=/mnt/mac/Desktop/MSL-Project/fflogs/glprobe.txt
{
echo "== drivers"; ls /usr/lib/aarch64-linux-gnu/dri/ | tr '\n' ' '; echo
echo "== gallium: vtest/virpipe symbols"; strings /usr/lib/aarch64-linux-gnu/libgallium-*.so | grep -iE "virpipe|VTEST_SOCKET|vtest" | sort -u | head -20
echo "== glxinfo (needs server GLX)"; command -v glxinfo || echo "no glxinfo"
glxinfo -B 2>&1 | head -15
echo "== eglinfo"; command -v eglinfo && eglinfo -B 2>&1 | head -30
} > $O 2>&1
