#!/bin/bash
# glxprobe.sh [app] - GLX info / an app, output to the shared folder
O=/mnt/mac/Desktop/MSL-Project/fflogs/glx-${1:-info}.txt
{ echo "== glxinfo -B"; glxinfo -B 2>&1 | head -25; echo; echo "== glxinfo full (head)"; glxinfo 2>&1 | head -12; } > $O 2>&1
