#!/bin/bash
export GALLIUM_DRIVER=virpipe LIBGL_ALWAYS_SOFTWARE=1
cd /tmp && blender --factory-startup > /mnt/mac/Desktop/MSL-Project/fflogs/blender-gpu.txt 2>&1
echo "exit=$?" >> /mnt/mac/Desktop/MSL-Project/fflogs/blender-gpu.txt
