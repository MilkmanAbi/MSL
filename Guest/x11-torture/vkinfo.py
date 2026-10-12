#!/usr/bin/env python3
"""vkinfo.py - what Vulkan does the guest get? (ctypes, no vulkan-tools needed)

    VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/virtio_icd.json python3 vkinfo.py
"""
import ctypes, sys

vk = ctypes.CDLL("libvulkan.so.1")

class AppInfo(ctypes.Structure):
    _fields_ = [("sType", ctypes.c_int), ("pNext", ctypes.c_void_p),
                ("pApplicationName", ctypes.c_char_p), ("applicationVersion", ctypes.c_uint32),
                ("pEngineName", ctypes.c_char_p), ("engineVersion", ctypes.c_uint32),
                ("apiVersion", ctypes.c_uint32)]

class InstInfo(ctypes.Structure):
    _fields_ = [("sType", ctypes.c_int), ("pNext", ctypes.c_void_p), ("flags", ctypes.c_uint32),
                ("pApplicationInfo", ctypes.POINTER(AppInfo)),
                ("enabledLayerCount", ctypes.c_uint32), ("ppEnabledLayerNames", ctypes.c_void_p),
                ("enabledExtensionCount", ctypes.c_uint32), ("ppEnabledExtensionNames", ctypes.c_void_p)]

def version(v):
    return "%d.%d.%d" % ((v >> 22) & 0x7F, (v >> 12) & 0x3FF, v & 0xFFF)

app = AppInfo(0, None, b"vkinfo", 0, b"none", 0, (1 << 22) | (3 << 12))  # ask for 1.3
info = InstInfo(1, None, 0, ctypes.pointer(app), 0, None, 0, None)
inst = ctypes.c_void_p()
r = vk.vkCreateInstance(ctypes.byref(info), None, ctypes.byref(inst))
if r != 0:
    # Retry at 1.0 - a driver that cannot do 1.3 refuses the instance outright.
    app.apiVersion = 1 << 22
    r = vk.vkCreateInstance(ctypes.byref(info), None, ctypes.byref(inst))
if r != 0:
    sys.exit("vkCreateInstance failed: %d" % r)

count = ctypes.c_uint32(0)
vk.vkEnumeratePhysicalDevices(inst, ctypes.byref(count), None)
if not count.value:
    sys.exit("no Vulkan devices")
devices = (ctypes.c_void_p * count.value)()
vk.vkEnumeratePhysicalDevices(inst, ctypes.byref(count), devices)
print("physical devices: %d" % count.value)
props = (ctypes.c_uint8 * 824)()
for d in devices[:count.value]:
    vk.vkGetPhysicalDeviceProperties(ctypes.c_void_p(d), props)
    api = int.from_bytes(bytes(props[0:4]), "little")
    driver = int.from_bytes(bytes(props[4:8]), "little")
    name = bytes(props[16:16 + 256]).split(b"\0")[0].decode(errors="replace")
    print("  %-40s Vulkan %s (driver %d)" % (name, version(api), driver))
