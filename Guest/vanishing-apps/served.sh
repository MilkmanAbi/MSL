#!/bin/sh
# Alive is not enough - a wedged client is still a running process. This
# proves the server is ANSWERING: xdpyinfo completes, and gimp is present.
G=$(pgrep -c -x gimp)
timeout 12 xdpyinfo -display :1 >/dev/null 2>&1 && S=yes || S=NO
echo "gimp:$G served:$S deaths:$(grep -c DEATH /tmp/xspy.log 2>/dev/null)"
