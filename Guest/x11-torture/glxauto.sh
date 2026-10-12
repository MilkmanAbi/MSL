#!/bin/bash
glxinfo -B > /mnt/mac/Desktop/MSL-Project/fflogs/glx-auto.txt 2>&1
echo "GALLIUM_DRIVER=$GALLIUM_DRIVER  socket=$([ -S /tmp/.virgl_test ] && echo yes || echo no)" >> /mnt/mac/Desktop/MSL-Project/fflogs/glx-auto.txt
