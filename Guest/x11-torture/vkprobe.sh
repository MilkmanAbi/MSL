#!/bin/bash
# Can Venus talk to a vtest server (no virtio-gpu device exists under
# Virtualization.framework), and what Vulkan does the guest actually get?
O=/mnt/mac/Desktop/MSL-Project/fflogs/vkprobe.txt
L=/usr/lib/aarch64-linux-gnu/libvulkan_virtio.so
{
echo "== venus: vtest transport strings"; strings $L | grep -iE "vtest|VTEST_SOCKET" | sort -u | head -8
echo "== venus: what it opens instead"; strings $L | grep -E "renderD|/dev/dri" | sort -u | head -4
echo "== ICDs"; ls /usr/share/vulkan/icd.d/
echo "== zink present?"; ls /usr/lib/aarch64-linux-gnu/dri/zink_dri.so 2>&1
} > $O 2>&1
