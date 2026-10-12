#!/bin/bash
# gears.sh MODE PROGRAM - run a Mesa demo ~12 s; FPS lines to the shared folder
# MODE: cpu (llvmpipe) | gpu (virpipe -> Mac GPU)
O=/mnt/mac/Desktop/MSL-Project/fflogs/gears-$1-$(basename $2).txt
if [ "$1" = gpu ]; then export GALLIUM_DRIVER=virpipe LIBGL_ALWAYS_SOFTWARE=1; fi
timeout ${GEARS_SECS:-12} stdbuf -oL "$2" -info -geometry 800x600 > "$O" 2>&1
echo "exit=$?" >> "$O"
