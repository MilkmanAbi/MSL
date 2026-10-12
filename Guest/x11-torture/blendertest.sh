#!/bin/bash
# Blender startup under mslgd, with Mesa/GLX diagnostics, to the shared folder
export LIBGL_DEBUG=verbose MESA_DEBUG=1 EGL_LOG_LEVEL=debug
cd /tmp && blender --factory-startup > /mnt/mac/Desktop/MSL-Project/fflogs/blender.txt 2>&1
echo "exit=$?" >> /mnt/mac/Desktop/MSL-Project/fflogs/blender.txt
