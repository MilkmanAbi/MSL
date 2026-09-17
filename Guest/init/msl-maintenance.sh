#!/bin/sh
# msl-maintenance
#
# The guest half of MSL's maintenance tools. Installed at
# /usr/sbin/msl-maintenance by the image build. Two ways in:
#
#   As a utility, in a normal running guest. mslhd runs it as root over the
#   internal command channel:
#       msl-maintenance fix-packages           repair the package manager
#       msl-maintenance free-space             clear caches inside the guest
#       msl-maintenance disk-errors            report disk errors the kernel logged
#   (Clock sync isn't here. mslhd sets the time with plain `date`, which is
#   what lets it work on images built before this script existed.)
#
#   As PID 1, in a maintenance boot. mslhd boots the guest with
#       init=/usr/sbin/msl-maintenance msl.action=fsck-check|fsck-repair
#   The initramfs mounts root read-only and hands straight over to this
#   script, so nothing else is running and nothing has the filesystem open
#   for writing. It checks (or repairs) root with the guest's own e2fsck,
#   prints the result on the console, and powers off. This is the repair
#   path for a Mac without e2fsprogs installed.
#
# Output contract. Utilities end with exactly one line:
#       MSL-RESULT <ok|fail|skip> <one-line summary>
# A maintenance boot prints:
#       MSL-MAINTENANCE-BEGIN <action>
#       ...e2fsck's own output...
#       MSL-MAINTENANCE-DONE <e2fsck exit status>
# The status is e2fsck's raw bitmask. The host turns it into a verdict
# (FsckVerdict), so that mapping exists in exactly one place.
#
# POSIX sh only: Alpine's /bin/sh is busybox ash and a minimal image has no
# bash. tests/msl-maintenance_test.sh runs this under dash, which is stricter.

set -u

# As init= the script inherits whatever PATH the initramfs left, which on a
# maintenance boot didn't include `sync` (Debian printed "sync: not found"
# twice, before and after e2fsck - 2026-09-14). Set one that covers every
# layout these images use.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

MSL_SCRIPT_PATH=/usr/sbin/msl-maintenance

# Flushes to disk by whatever means the image has: coreutils' sync, busybox's,
# or the kernel's emergency sync - some images have no sync binary at all.
msl_sync() {
    if command -v sync >/dev/null 2>&1; then
        sync
    elif command -v busybox >/dev/null 2>&1; then
        busybox sync
    else
        echo s > /proc/sysrq-trigger 2>/dev/null
        sleep 1
    fi
}

# ------------------------------------------------------------------ helpers
#
# Every helper takes its inputs as arguments or file paths instead of reading
# the live system, so the test harness can feed it fixtures.

msl_result() {  # status summary...
    msl_status=$1
    shift
    printf 'MSL-RESULT %s %s\n' "$msl_status" "$*"
}

# The package manager, from an os-release file. ID first, then ID_LIKE, so a
# derivative (Mint: ID=linuxmint ID_LIKE="ubuntu debian") still resolves.
msl_detect_pm() {  # [os-release-path]
    msl_file=${1:-/etc/os-release}
    if [ ! -r "$msl_file" ]; then
        echo unknown
        return
    fi
    msl_id=$(sed -n 's/^ID=//p' "$msl_file" | tr -d '"' | head -n 1)
    msl_like=$(sed -n 's/^ID_LIKE=//p' "$msl_file" | tr -d '"' | head -n 1)
    set -f
    for msl_word in $msl_id $msl_like; do
        case $msl_word in
            alpine)             set +f; echo apk; return ;;
            debian|ubuntu)      set +f; echo apt; return ;;
            arch|archarm)       set +f; echo pacman; return ;;
            fedora|rhel|centos) set +f; echo dnf; return ;;
            nixos)              set +f; echo nix; return ;;
        esac
    done
    set +f
    echo unknown
}

# The value of key=... in a kernel command line. Whole-key match only, so
# msl.action never matches msl.actionx. Globbing is off while splitting: a
# command line is untrusted text and `*` in it must not expand to filenames.
msl_cmdline_value() {  # key cmdline-string
    msl_key=$1
    msl_found=1
    msl_value=
    set -f
    for msl_word in $2; do
        case $msl_word in
            "$msl_key="*)
                msl_value=${msl_word#"$msl_key"=}
                msl_found=0
                break
                ;;
        esac
    done
    set +f
    [ "$msl_found" -eq 0 ] && printf '%s\n' "$msl_value"
    return "$msl_found"
}

# Whether a process with exactly this name is running. Scans /proc rather
# than calling pgrep, which is missing from some minimal images.
msl_process_running() {  # name [proc-root]
    msl_name=$1
    msl_proc=${2:-/proc}
    for msl_comm in "$msl_proc"/[0-9]*/comm; do
        [ -r "$msl_comm" ] || continue
        [ "$(cat "$msl_comm" 2>/dev/null)" = "$msl_name" ] && return 0
    done
    return 1
}

# Kernel log lines that mean the disk or its filesystem is in trouble.
# Deliberately excludes routine EXT4 chatter like "mounted filesystem".
msl_filter_disk_errors() {  # dmesg-text-file
    grep -iE 'EXT4-fs (error|warning)|I/O error|blk_update_request|JBD2: .*error|remounting filesystem read-only' "$1" 2>/dev/null || true
}

# Whether any mount of / is read-write, from a mounts table.
msl_root_is_writable() {  # [mounts-file]
    awk '$2 == "/" { n = split($4, o, ","); for (i = 1; i <= n; i++) if (o[i] == "rw") found = 1 }
         END { exit !found }' "${1:-/proc/mounts}"
}

msl_free_kb() {  # mount-point
    df -Pk "$1" 2>/dev/null | awk 'NR == 2 { print $4 }'
}

# ------------------------------------------------------------------ utilities

msl_action_fix_packages() {
    msl_pm=$(msl_detect_pm)
    case $msl_pm in
        apt)
            # Locks are fcntl locks here, released when their owner dies, so
            # a leftover lock *file* is harmless and is left alone.
            DEBIAN_FRONTEND=noninteractive dpkg --configure -a &&
                DEBIAN_FRONTEND=noninteractive apt-get -f install -y
            msl_code=$?
            ;;
        pacman)
            # pacman's lock is presence-based: a crash mid-transaction leaves
            # db.lck behind and pacman refuses to run ever again. Removed only
            # when no pacman is actually running.
            if [ -e /var/lib/pacman/db.lck ] && ! msl_process_running pacman; then
                rm -f /var/lib/pacman/db.lck
                echo "removed a stale pacman lock left by an interrupted run"
            fi
            pacman -Dk
            msl_code=$?
            ;;
        apk)
            apk fix
            msl_code=$?
            ;;
        dnf)
            dnf check
            msl_code=$?
            ;;
        nix)
            nix-store --verify
            msl_code=$?
            ;;
        *)
            msl_result skip "don't know how to repair packages on this distro"
            return 0
            ;;
    esac
    if [ "$msl_code" -eq 0 ]; then
        msl_result ok "$msl_pm reports no remaining problems"
    else
        msl_result fail "$msl_pm exited with status $msl_code - see the output above"
        return 1
    fi
}

msl_action_free_space() {
    msl_before=$(msl_free_kb /)
    case $(msl_detect_pm) in
        apt)    apt-get clean ;;
        pacman) pacman -Sc --noconfirm ;;          # keeps installed versions' packages
        apk)    rm -rf /var/cache/apk/* ;;
        dnf)    dnf clean all ;;
        nix)    nix-collect-garbage ;;             # never -d: that deletes rollback generations
    esac
    if command -v journalctl >/dev/null 2>&1; then
        journalctl --vacuum-size=64M >/dev/null 2>&1 || true
    fi
    msl_after=$(msl_free_kb /)
    if [ -n "$msl_before" ] && [ -n "$msl_after" ]; then
        msl_freed=$(( (msl_after - msl_before) / 1024 ))
        [ "$msl_freed" -lt 0 ] && msl_freed=0
        msl_result ok "freed ${msl_freed} MB inside the guest"
    else
        msl_result ok "caches cleared"
    fi
}

msl_action_disk_errors() {
    msl_log=$(mktemp 2>/dev/null || echo "/tmp/msl-dmesg.$$")
    if ! dmesg > "$msl_log" 2>/dev/null; then
        rm -f "$msl_log"
        msl_result fail "couldn't read the kernel log"
        return 1
    fi
    msl_errors=$(msl_filter_disk_errors "$msl_log")
    rm -f "$msl_log"
    if [ -z "$msl_errors" ]; then
        msl_result ok "no disk or filesystem errors in the kernel log"
        return 0
    fi
    msl_count=$(printf '%s\n' "$msl_errors" | wc -l | tr -d ' ')
    printf '%s\n' "$msl_errors" | tail -n 20
    msl_result fail "$msl_count disk or filesystem error(s) logged - a filesystem check is worth running"
    return 1
}

# ------------------------------------------------------------------ maintenance boot

# PID 1 must never return: init exiting panics the kernel. So this powers off
# by every means available, and if all of them fail it waits forever - mslhd
# stops the VM itself once it has seen the DONE marker.
msl_power_off() {
    msl_sync
    echo o > /proc/sysrq-trigger 2>/dev/null
    poweroff -f 2>/dev/null || busybox poweroff -f 2>/dev/null
    while :; do sleep 60; done
}

msl_maintenance_boot() {
    [ -r /proc/cmdline ] || mount -t proc proc /proc 2>/dev/null
    [ -d /sys/kernel ] || mount -t sysfs sysfs /sys 2>/dev/null

    msl_cmdline=$(cat /proc/cmdline 2>/dev/null)
    msl_action=$(msl_cmdline_value msl.action "$msl_cmdline") || msl_action=
    msl_root=$(msl_cmdline_value root "$msl_cmdline") || msl_root=/dev/nvme0n1

    echo "MSL-MAINTENANCE-BEGIN ${msl_action:-none}"
    case $msl_action in
        fsck-check)  msl_flags="-f -n" ;;
        fsck-repair) msl_flags="-f -y" ;;
        *)
            echo "no recognised msl.action on the kernel command line"
            echo "MSL-MAINTENANCE-DONE 16"
            msl_power_off
            ;;
    esac

    # The initramfs mounts root read-only. If anything has made it writable,
    # stop: repairing a live, writable filesystem is how disks get destroyed.
    if [ "$msl_action" = fsck-repair ] && msl_root_is_writable; then
        echo "root is mounted read-write - refusing to repair a live filesystem"
        echo "MSL-MAINTENANCE-DONE 8"
        msl_power_off
    fi

    if ! command -v e2fsck >/dev/null 2>&1; then
        echo "e2fsck isn't installed in this image"
        echo "MSL-MAINTENANCE-DONE 8"
        msl_power_off
    fi

    # shellcheck disable=SC2086 # two flags, split on purpose
    e2fsck $msl_flags "$msl_root" </dev/null 2>&1
    msl_code=$?
    msl_sync
    echo "MSL-MAINTENANCE-DONE $msl_code"
    msl_power_off
}

# ------------------------------------------------------------------ entry

msl_main() {
    if [ "$$" -eq 1 ]; then
        msl_maintenance_boot
    fi
    if [ "$(id -u)" -ne 0 ]; then
        msl_result fail "must run as root"
        exit 1
    fi
    msl_command=${1:-}
    [ $# -gt 0 ] && shift
    case $msl_command in
        fix-packages) msl_action_fix_packages ;;
        free-space)   msl_action_free_space ;;
        disk-errors)  msl_action_disk_errors ;;
        *)
            msl_result fail "unknown utility '$msl_command'"
            exit 16
            ;;
    esac
}

if [ -z "${MSL_MAINT_NO_MAIN:-}" ]; then
    msl_main "$@"
fi
