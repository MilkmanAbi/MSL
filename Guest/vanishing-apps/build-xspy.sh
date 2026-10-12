#!/bin/sh
cd /tmp
cp /mnt/mac/msl-debug/xspy.c /tmp/
gcc -shared -fPIC -O1 -g -o /tmp/xspy.so /tmp/xspy.c -ldl 2>&1 | head -15
ls -l /tmp/xspy.so 2>/dev/null && echo "BUILT"
