#!/bin/sh
# The container half of build-kernel.sh. Runs as root in alpine:<version>
# with /build (this folder, read-only) and /out mounted.
set -eu

log() { echo "kernel-inner: $*"; }

apk add --no-cache "linux-$FLAVOR" mkinitfs kmod >/dev/null
KVER=$(ls /lib/modules | grep -- "-$FLAVOR\$")
log "kernel $KVER"
printf '%s\n' "$KVER" > /out/kernel-release
cp "/boot/config-$KVER" /out/config

# ------------------------------------------------------------- the Image
#
# Alpine's arm64 vmlinuz is an EFI zboot image: a small PE stub wrapping a
# compressed raw Image. Virtualization's VZLinuxBootLoader wants the raw
# Image. The zboot header says where the payload is: "zimg" at offset 4,
# payload offset (le32) at 8, payload size (le32) at 12, compression name at
# 24. Same layout GuestImageTools.extractZbootImage parses on the host.
V="/boot/vmlinuz-$FLAVOR"
magic=$(dd if="$V" bs=1 skip=4 count=4 2>/dev/null)
if [ "$magic" = zimg ]; then
    off=$(od -An -tu4 -j8 -N4 "$V" | tr -d ' ')
    size=$(od -An -tu4 -j12 -N4 "$V" | tr -d ' ')
    comp=$(dd if="$V" bs=1 skip=24 count=4 2>/dev/null)
    log "zboot payload: offset=$off size=$size compression=$comp"
    [ "$comp" = gzip ] || { echo "kernel-inner: unexpected zboot compression '$comp'" >&2; exit 1; }
    tail -c +"$((off + 1))" "$V" | head -c "$size" | gunzip > /out/Image
else
    log "vmlinuz is not zboot-wrapped, copying as-is"
    cp "$V" /out/Image
fi
# A raw arm64 Image carries "ARM\x64" at offset 56.
arm=$(dd if=/out/Image bs=1 skip=56 count=3 2>/dev/null)
[ "$arm" = ARM ] || { echo "kernel-inner: /out/Image has no arm64 Image magic" >&2; exit 1; }
log "Image: $(wc -c < /out/Image) bytes"

# ------------------------------------------------------------- initramfs
#
# Only what finding and mounting root needs: ext4, the NVMe controller MSL
# now attaches the disk to, and virtio (virtio-blk for older configurations,
# plus virtio_console so console=hvc0 has somewhere to write). Alpine's
# default feature list pulls in ata/scsi/usb/mmc/kms/raid and produces a
# 161 MB initramfs; this is a few MB.
printf 'features="base ext4 nvme virtio"\n' > /etc/mkinitfs/mkinitfs.conf
mkinitfs -o /out/initramfs "$KVER"
log "initramfs: $(wc -c < /out/initramfs) bytes"
if ! gunzip -c /out/initramfs 2>/dev/null | cpio -t 2>/dev/null | grep -q 'drivers/nvme/host/nvme.ko'; then
    echo "kernel-inner: the initramfs has no nvme.ko - root on NVMe would not mount" >&2
    exit 1
fi

# ------------------------------------------------------------- modules
#
# Every distro disk gets its own copy of the module tree (nothing installs a
# kernel package inside the Docker-derived rootfs). The full lts tree is
# ~110 MB gzipped, most of it drivers for hardware a VM never has. Keep
# what can matter inside a VM - filesystems, networking (containers need
# netfilter, bridges, veth, tun), crypto, dm, virtio, NVMe, vgem, USB/IP -
# and drop physical-hardware drivers, wireless, bluetooth and sound.
W=/work/lib/modules/$KVER
mkdir -p /work/lib/modules
cp -a "/lib/modules/$KVER" /work/lib/modules/
before=$(du -sk "$W" | cut -f1)

K=$W/kernel
rm -rf "$K/sound" \
       "$K/net/bluetooth" "$K/net/wireless" "$K/net/mac80211" "$K/net/nfc" \
       "$K/net/ieee802154" "$K/net/mac802154" "$K/net/6lowpan" "$K/net/can" \
       "$K/net/rfkill"
# i2c and cdrom are not hardware anyone attaches to a VM, but drm (which
# vgem needs) links against i2c core, and isofs against the cdrom layer.
# hwmon: nvme-core registers a temperature sensor through it. tee and char/tpm:
# trusted-keys needs both, and dm-crypt and ecryptfs need trusted/encrypted keys.
keep_drivers="block cdrom char virtio nvme net md gpu i2c hwmon usb hid input scsi dax crypto ptp pps tty tee"
for d in "$K"/drivers/*; do
    name=$(basename "$d")
    case " $keep_drivers " in *" $name "*) ;; *) rm -rf "$d" ;; esac
done
# Within the kept driver trees, drop the hardware.
rm -rf "$K/drivers/net/wireless" "$K/drivers/net/ethernet" "$K/drivers/net/usb" \
       "$K/drivers/net/wwan" "$K/drivers/net/can" "$K/drivers/net/ieee802154" \
       "$K/drivers/net/dsa" "$K/drivers/net/hamradio" "$K/drivers/net/arcnet" \
       "$K/drivers/net/fddi" "$K/drivers/net/phy" "$K/drivers/net/pcs" \
       "$K/drivers/net/mdio" "$K/drivers/net/wan" \
       "$K/drivers/i2c/busses" "$K/drivers/i2c/muxes" "$K/drivers/nvme/target"
# drm: the core, its shared helpers (ttm, the in-kernel clients, display
# helpers, the scheduler), and the two drivers a VM can use.
for d in "$K"/drivers/gpu/drm/*/; do
    name=$(basename "$d")
    case "$name" in vgem|virtio|tiny|ttm|clients|display|scheduler) ;; *) rm -rf "$d" ;; esac
done
for d in "$K"/drivers/usb/*/; do
    name=$(basename "$d")
    case "$name" in core|common|usbip|storage|class|serial) ;; *) rm -rf "$d" ;; esac
done
for d in "$K"/drivers/crypto/*/; do
    name=$(basename "$d")
    case "$name" in virtio) ;; *) rm -rf "$d" ;; esac
done
for d in "$K"/drivers/hid/*/; do
    name=$(basename "$d")
    case "$name" in usbhid) ;; *) rm -rf "$d" ;; esac
done
rm -rf "$K/drivers/input/touchscreen" "$K/drivers/input/joystick" \
       "$K/drivers/input/tablet" "$K/drivers/input/keyboard" "$K/drivers/input/mouse" \
       "$K/drivers/input/rmi4" "$K/drivers/input/misc" "$K/drivers/scsi/"*/ \
       "$K/drivers/char/ipmi" "$K/drivers/md/bcache"

# Decompressed, because not every distro's kmod is built with gzip support
# (Debian's was not - "Invalid ELF header magic: != ELF"). The disk image is
# compressed as a whole for download anyway.
find "$W" -name '*.ko.gz' -exec gunzip {} +
rm -f "$W"/modules.*

# Anything left that links against a module the trim removed - Hyper-V,
# RDMA, parallel-port and Thunderbolt drivers, mostly - would refuse to load
# inside a guest, so it goes too. Repeated until nothing is unresolved,
# because removing one can strand another. The required-module check below
# catches the case where this takes out something that matters.
: > /out/pruned-modules.txt
pass=0
while :; do
    pass=$((pass + 1))
    depmod -e -F "/boot/System.map-$KVER" -b /work "$KVER" 2>&1 \
        | sed -n 's#^depmod: WARNING: \(/work/lib/modules/[^ ]*\.ko\) needs unknown symbol.*#\1#p' \
        | sort -u > /tmp/unresolved
    [ -s /tmp/unresolved ] || break
    [ "$pass" -le 10 ] || { echo "kernel-inner: still unresolved after 10 passes" >&2; exit 1; }
    sed "s#^$W/kernel/##" /tmp/unresolved >> /out/pruned-modules.txt
    xargs rm -f < /tmp/unresolved
done
depmod -b /work "$KVER"
after=$(du -sk "$W" | cut -f1)
log "pruned $(wc -l < /out/pruned-modules.txt) modules with unresolved symbols (pruned-modules.txt)"
log "modules: $(find "$W" -name '*.ko' | wc -l) kept, ${before} KiB gzipped -> ${after} KiB decompressed and trimmed"

# The modules MSL itself, or ordinary guest workloads, cannot do without.
# No ip_tables/iptable_nat: Alpine's 6.18 kernels build nftables only
# (CONFIG_IP_NF_IPTABLES_LEGACY is off), so iptables in a guest has to be
# the iptables-nft flavour, which rides on nft_compat.
missing=0
for m in vmw_vsock_virtio_transport vsock virtio_net virtio_balloon virtio_rng \
         virtio_console nvme ext4 virtiofs fuse overlay loop squashfs isofs vfat \
         btrfs xfs nf_tables nft_chain_nat nft_compat nft_masq nf_nat bridge \
         br_netfilter veth tun macvlan vxlan wireguard xt_MASQUERADE dm_mod \
         dm_crypt vgem virtio_gpu vhci_hcd usb_storage usbhid binfmt_misc \
         9pnet_virtio nfs cifs; do
    if out=$(modprobe -d /work -S "$KVER" --show-depends "$m" 2>&1); then
        case "$out" in *builtin*|*insmod*) ;; *) echo "  ?? $m: $out";; esac
    else
        echo "  MISSING $m: $out"; missing=$((missing + 1))
    fi
done
[ "$missing" = 0 ] || { echo "kernel-inner: $missing required modules missing after trimming" >&2; exit 1; }
log "all required modules resolve"

tar -C /work -cf /out/modules.tar "lib/modules/$KVER"
log "modules.tar: $(wc -c < /out/modules.tar) bytes"
