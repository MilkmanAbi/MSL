#!/bin/sh
# Fixture tests for msl-maintenance's helpers.
#
# The helpers are where the bugs would be, and none of them can be exercised
# on a real guest from the host. Run under the strictest shell available -
# dash is closer to Alpine's busybox ash than bash is:
#   dash Guest/init/tests/msl-maintenance_test.sh
#   sh   Guest/init/tests/msl-maintenance_test.sh

set -u
here=$(cd "$(dirname "$0")" && pwd)
# Exported, not merely set: the negative checks below run in `sh -c`
# subshells, which only inherit exported variables. Unexported, each of them
# sourced the script, ran msl_main, died on its root check, and the `!` turned
# that into a pass - every negative test passing without testing anything.
export MSL_MAINT_NO_MAIN=1
. "$here/../msl-maintenance.sh"

failures=0
check() {  # description, then a command that must succeed
    what=$1
    shift
    if "$@"; then
        echo "  ok   $what"
    else
        echo "  FAIL $what"
        failures=$((failures + 1))
    fi
}
eq() { [ "$1" = "$2" ]; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

osr() { printf '%s\n' "$@" > "$work/os-release"; msl_detect_pm "$work/os-release"; }

echo "distro detection"
check "alpine -> apk"                 eq "$(osr 'ID=alpine')" apk
check "debian -> apt"                 eq "$(osr 'ID=debian')" apt
check "ubuntu -> apt"                 eq "$(osr 'ID=ubuntu' 'ID_LIKE=debian')" apt
check "quoted fedora -> dnf"          eq "$(osr 'ID="fedora"')" dnf
check "arch -> pacman"                eq "$(osr 'ID=arch')" pacman
check "archarm via ID_LIKE -> pacman" eq "$(osr 'ID=archarm' 'ID_LIKE=arch')" pacman
check "nixos -> nix"                  eq "$(osr 'ID=nixos')" nix
check "mint resolves via ID_LIKE"     eq "$(osr 'ID=linuxmint' 'ID_LIKE="ubuntu debian"')" apt
check "unknown distro -> unknown"     eq "$(osr 'ID=gentoo')" unknown
# ID outranks ID_LIKE. (An earlier check here expected ID=gentoo plus
# ID_LIKE=debian to be "unknown" - but a Debian-like distro genuinely does use
# apt, so that was the test being wrong, not the script.)
check "ID outranks ID_LIKE"           eq "$(osr 'ID=alpine' 'ID_LIKE=debian')" apk
check "missing file -> unknown"       eq "$(msl_detect_pm "$work/nope")" unknown

echo "kernel command line"
line='console=hvc0 root=/dev/vda rootfstype=ext4 ro init=/usr/sbin/msl-maintenance msl.action=fsck-repair'
check "reads msl.action"              eq "$(msl_cmdline_value msl.action "$line")" fsck-repair
check "reads root"                    eq "$(msl_cmdline_value root "$line")" /dev/vda
check "missing key fails"             sh -c '! (. "$1"; msl_cmdline_value nothere "$2" >/dev/null)' _ "$here/../msl-maintenance.sh" "$line"
check "whole-key match only"          eq "$(msl_cmdline_value msl.action 'msl.actionx=bad msl.action=good')" good
touch "$work/should-not-expand"
check "no glob expansion"             eq "$(cd "$work" && msl_cmdline_value k 'k=* other=1')" '*'
check "value may contain ="           eq "$(msl_cmdline_value root 'root=UUID=ab-cd')" UUID=ab-cd

echo "process scan"
mkdir -p "$work/proc/12" "$work/proc/34" "$work/proc/self"
echo pacman > "$work/proc/12/comm"
echo bash   > "$work/proc/34/comm"
echo pacman > "$work/proc/self/comm"
check "finds a running pacman"        msl_process_running pacman "$work/proc"
check "no apt-get running"            sh -c '! (. "$1"; msl_process_running apt-get "$2")' _ "$here/../msl-maintenance.sh" "$work/proc"
check "exact name, not substring"     sh -c '! (. "$1"; msl_process_running pac "$2")' _ "$here/../msl-maintenance.sh" "$work/proc"
rm "$work/proc/12/comm"
check "ignores non-numeric dirs"      sh -c '! (. "$1"; msl_process_running pacman "$2")' _ "$here/../msl-maintenance.sh" "$work/proc"

echo "kernel log filter"
cat > "$work/dmesg" <<'LOG'
[    1.234] EXT4-fs (vda): mounted filesystem with ordered data mode. Quota mode: none.
[   55.100] EXT4-fs error (device vda): ext4_lookup:1855: inode #1234: comm bash: deleted inode referenced: 5678
[   55.200] blk_update_request: I/O error, dev vda, sector 123456 op 0x0:(READ)
[   55.300] Buffer I/O error on dev vda, logical block 15432, async page read
[   56.000] EXT4-fs (vda): Remounting filesystem read-only
[   60.000] random: crng init done
LOG
check "four real errors"              eq "$(msl_filter_disk_errors "$work/dmesg" | wc -l | tr -d ' ')" 4
check "routine mount line excluded"   sh -c '! (. "$1"; msl_filter_disk_errors "$2" | grep -q "mounted filesystem")' _ "$here/../msl-maintenance.sh" "$work/dmesg"
printf '[ 1.0] all quiet\n' > "$work/quiet"
check "a clean log yields nothing"    eq "$(msl_filter_disk_errors "$work/quiet")" ""

echo "read-only root check"
printf '/dev/vda / ext4 ro,relatime 0 0\nproc /proc proc rw 0 0\n' > "$work/mounts-ro"
printf '/dev/vda / ext4 rw,relatime 0 0\n' > "$work/mounts-rw"
printf 'rootfs / rootfs ro 0 0\n/dev/vda / ext4 rw,noatime 0 0\n' > "$work/mounts-mixed"
printf '/dev/vda / ext4 ro,errors=remount-rw 0 0\n' > "$work/mounts-tricky"
check "ro root is not writable"       sh -c '! (. "$1"; msl_root_is_writable "$2")' _ "$here/../msl-maintenance.sh" "$work/mounts-ro"
check "rw root is writable"           msl_root_is_writable "$work/mounts-rw"
check "any rw mount of / counts"      msl_root_is_writable "$work/mounts-mixed"
check "'remount-rw' is not 'rw'"      sh -c '! (. "$1"; msl_root_is_writable "$2")' _ "$here/../msl-maintenance.sh" "$work/mounts-tricky"
check "/proc being rw is irrelevant"  sh -c '! (. "$1"; msl_root_is_writable "$2")' _ "$here/../msl-maintenance.sh" "$work/mounts-ro"

echo
if [ "$failures" -eq 0 ]; then echo "all passed"; else echo "$failures FAILED"; fi
[ "$failures" -eq 0 ]
