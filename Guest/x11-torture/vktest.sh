#!/bin/bash
export VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/virtio_icd.json
export VTEST_SOCKET_NAME=/tmp/.virgl_test
export VN_DEBUG=vtest
timeout 30 python3 /mnt/mac/Desktop/MSL-Project/Actual-Project/MSL/Guest/x11-torture/vkinfo.py > /mnt/mac/Desktop/MSL-Project/fflogs/vk.txt 2>&1
echo "exit=$?" >> /mnt/mac/Desktop/MSL-Project/fflogs/vk.txt
