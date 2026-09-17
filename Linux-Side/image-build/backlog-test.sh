#!/bin/bash
# The READMEs' remaining "needs a guest" checks, driven through the real app
# daemon against the built images. One instance at a time; each section starts
# from a freshly installed image, because several of them damage one on
# purpose.
#
#   image-build/backlog-test.sh IMAGES_DIR KERNEL_DIR [SECTION...]
#
# Sections: maintenance fixpackages accounts ssh-reboot sandbox-hibernate
# put-kill deep-path memory. With none, runs them all.
set -u

[ $# -ge 2 ] || { echo "usage: $0 IMAGES_DIR KERNEL_DIR [SECTION...]" >&2; exit 2; }
IMAGES=$1; KERNEL=$2; shift 2
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
A="$HOME/Library/Application Support/MSL"
M="$A/bin/msl"
SOCK="$A/mslhd.sock"
LOG="$HOME/Library/Logs/MSL/mslhd.log"
[ $# -gt 0 ] || set -- maintenance accounts ssh-reboot sandbox-hibernate put-kill deep-path memory fixpackages

fifo=$(mktemp -u "${TMPDIR:-/tmp}/msl-backlog.XXXXXX")
mkfifo "$fifo"
sleep 36000 > "$fifo" &
holder=$!
trap 'kill $holder 2>/dev/null; rm -f "$fifo"' EXIT

pass=0; fail=0
ok()  { echo "  ok    $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1${2:+ - $2}"; fail=$((fail + 1)); }
note() { echo "  info  $1"; }
q() { printf '%s\n' "$1" | nc -U -w "${2:-60}" "$SOCK"; }
g() { "$M" "$1" -u root "$2" < "$fifo" 2>&1 | tr -d '\r'; }
wait_state() { for _ in $(seq 1 90); do [ "$("$M" status "$1" 2>&1)" = "OK $2" ] && return 0; sleep 1; done; return 1; }
fresh() {   # fresh DISTRO: pristine image installed, instance gone
    bash "$HERE/smoke-test.sh" "$1" "$IMAGES" "$KERNEL" > "/tmp/msl-backlog-smoke-$1.log" 2>&1 \
        || { bad "$1: fresh install boots (smoke test)" "$(tail -2 /tmp/msl-backlog-smoke-$1.log | tr '\n' ' ')"; return 1; }
    # smoke-test unregisters the instance when it's done, and MAINTENANCE
    # only answers for registered ones. CREATE registers without booting.
    q "CREATE $1 $1" >/dev/null
}
image_of() { [ "$1" = alpine ] && echo "$A/rootfs.img" || echo "$A/rootfs-$1.img"; }
debugfs_w() {  # debugfs_w IMAGE_PATH COMMAND - edits a stopped image from the Mac
    local dir; dir=$(dirname "$1")
    docker run --rm -v "$dir:/d" alpine:3.24 sh -c "apk add -q e2fsprogs-extra >/dev/null 2>&1; debugfs -w -R '$2' '/d/$(basename "$1")'" >/dev/null 2>&1
}
webdav_port() { # webdav_port INSTANCE - the bridge serving that guest
    local want p; want=$(g "$1" 'cat /etc/hostname' | tail -1)
    for p in $(lsof -nP -iTCP -sTCP:LISTEN -a -p "$(pgrep -f 'bin/mslhd')" 2>/dev/null | awk 'NR>1 {sub(/.*:/, "", $9); print $9}'); do
        [ "$(curl -s -m 20 "http://127.0.0.1:$p/etc/hostname" | head -1)" = "$want" ] && { echo "$p"; return; }
    done
}

# ---------------------------------------------------------------- maintenance
section_maintenance() {
    echo "maintenance"
    local d=debian img; img=$(image_of $d)
    fresh $d || return

    # Repair boot keeps a backup beside the image.
    r=$(q "MAINTENANCE $d boot-fsck-repair" 900)
    case "$r" in OK*) ok "maintenance boot repair ran: $(echo "$r" | cut -c1-80)" ;; *) bad "maintenance boot repair ran" "$r" ;; esac
    [ -f "$img.pre-repair" ] && ok "repair left a pre-repair backup beside the image" || bad "repair left a pre-repair backup beside the image"
    q "MAINTENANCE $d backup-discard" 120 >/dev/null
    [ -f "$img.pre-repair" ] && bad "backup-discard removes the backup" || ok "backup-discard removes the backup"

    # A maintenance boot on an image without the script says so, quickly.
    debugfs_w "$img" "rm /usr/sbin/msl-maintenance"
    started=$(date +%s)
    r=$(q "MAINTENANCE $d boot-fsck-check" 900)
    took=$(( $(date +%s) - started ))
    title=$(echo "$r" | sed -n 's/.*title=\([^ ]*\).*/\1/p' | base64 -d 2>/dev/null)
    if [ "$title" = "Needs a rebuilt image" ] && [ "$took" -lt 120 ]; then
        ok "maintenance boot without the script: \"$title\" in ${took}s"
    else
        bad "maintenance boot without the script says it needs a rebuilt image, quickly" "title='$title' after ${took}s: $(echo "$r" | cut -c1-100)"
    fi
    [ "$(pgrep -f com.apple.Virtualization.VirtualMachine | wc -l | tr -d ' ')" = 0 ] \
        && ok "that maintenance VM was powered off" || bad "that maintenance VM was powered off"
    fresh $d || return

    # Check-at-start refuses a damaged disk.
    debugfs_w "$img" "set_inode_field /etc/hostname links_count 7"
    q "MAINTENANCE $d check-at-start-on" >/dev/null
    out=$(g $d 'echo BOOTED-A-DAMAGED-DISK')
    if echo "$out" | grep -q "filesystem check at start found a problem"; then
        ok "check-at-start refuses a damaged disk"
    elif echo "$out" | grep -q "e2fsck isn't installed"; then
        bad "check-at-start refuses a damaged disk" "e2fsck not found on this Mac"
    else
        bad "check-at-start refuses a damaged disk" "$(echo "$out" | tail -2 | tr '\n' ' ')"
    fi
    q "MAINTENANCE $d check-at-start-off" >/dev/null
    fresh $d || return

    # The shared-disk rule, both ways. A maintenance boot on a healthy disk
    # is over in about four seconds, so a fixed sleep can miss it entirely -
    # each direction waits for the thing actually holding the disk.
    q "CREATE ${d}2 $d" >/dev/null

    # 1. Another instance on the disk is running: maintenance is refused.
    g "${d}2" 'echo up' >/dev/null
    r=$(q "MAINTENANCE $d boot-fsck-check" 120)
    case "$r" in
        *shares*|*"already running"*) ok "maintenance is refused while ${d}2 has the shared disk: $(echo "$r" | tail -1 | cut -c1-80)" ;;
        *) title=$(echo "$r" | sed -n 's/.*title=\([^ ]*\).*/\1/p' | base64 -d 2>/dev/null)
           detail=$(echo "$r" | sed -n 's/.*detail=\([^ ]*\).*/\1/p' | base64 -d 2>/dev/null)
           case "$title $detail" in
               *shares*|*"already running"*|*"stop "*) ok "maintenance is refused while ${d}2 has the shared disk: $title - $(echo "$detail" | cut -c1-70)" ;;
               *) bad "maintenance is refused while ${d}2 has the shared disk" "$(echo "$r" | cut -c1-120) / $title $detail" ;;
           esac ;;
    esac
    "$M" --shutdown "${d}2" >/dev/null 2>&1; wait_state "${d}2" stopped

    # 2. A maintenance boot holds the disk: another instance is refused.
    q "MAINTENANCE $d boot-fsck-check" 900 > /tmp/msl-backlog-check.out &
    checker=$!
    for _ in $(seq 1 100); do
        [ "$(pgrep -f com.apple.Virtualization.VirtualMachine | wc -l | tr -d ' ')" -ge 1 ] && break
        sleep 0.1
    done
    out=$(g "${d}2" 'echo SECOND-INSTANCE-STARTED')
    if echo "$out" | grep -q "SECOND-INSTANCE-STARTED"; then
        if grep -q "^OK" /tmp/msl-backlog-check.out 2>/dev/null; then
            note "${d}2 started, but only after the check had already finished - inconclusive"
        else
            bad "a second $d instance is refused while a maintenance boot holds the disk" "it started mid-check"
        fi
    else
        ok "a second $d instance is refused while a maintenance boot holds the disk: $(echo "$out" | tail -1 | cut -c1-90)"
    fi
    wait $checker
    grep -q "^OK" /tmp/msl-backlog-check.out && ok "the check itself still finished" || bad "the check itself still finished" "$(cat /tmp/msl-backlog-check.out)"
    "$M" --shutdown "${d}2" >/dev/null 2>&1
    "$M" remove "${d}2" >/dev/null 2>&1
}

# ---------------------------------------------------------------- fix packages, every distro
section_fixpackages() {
    echo "fixpackages"
    for d in $(. "$HERE/distros.sh"; echo $MSL_DISTROS); do
        fresh $d || continue
        g $d 'echo up' >/dev/null
        r=$(q "MAINTENANCE $d util-fix-packages" 600)
        title=$(echo "$r" | sed -n 's/.*title=\([^ ]*\).*/\1/p' | base64 -d 2>/dev/null)
        tone=$(echo "$r" | sed -n 's/.*tone=\([a-z]*\).*/\1/p')
        case "$tone" in good|info) ok "$d: repair package manager - $title ($tone)" ;; *) bad "$d: repair package manager" "$(echo "$r" | cut -c1-160)" ;; esac
        "$M" --shutdown $d >/dev/null 2>&1; "$M" remove $d >/dev/null 2>&1
    done
}

# ---------------------------------------------------------------- accounts
section_accounts() {
    echo "accounts"
    local d=debian
    fresh $d || return
    out=$(g $d 'useradd -m -s /bin/bash -G sudo resetme && echo "resetme:Old-Pass-1" | chpasswd \
        && echo "resetme:New-Pass-2" | chpasswd \
        && su - resetme -c "echo New-Pass-2 | sudo -S -p \"\" true" && echo OK-NEW-PASSWORD-WORKS; \
        su - resetme -c "sudo -k; echo Old-Pass-1 | sudo -S -p \"\" true 2>/dev/null" && echo BAD-OLD-PASSWORD-STILL-WORKS || echo OK-OLD-PASSWORD-REJECTED')
    echo "$out" | grep -q "^OK-NEW-PASSWORD-WORKS" && ok "root resetting a user's password: the new one works" || bad "root resetting a user's password: the new one works" "$out"
    echo "$out" | grep -q "^OK-OLD-PASSWORD-REJECTED" && ok "the old password stops working" || bad "the old password stops working" "$out"
    "$M" --shutdown $d >/dev/null 2>&1; "$M" remove $d >/dev/null 2>&1
}

# ---------------------------------------------------------------- accounts through the real prompt
forget_default_user() {  # forget_default_user DISTRO
    local registry="$A/default-users.json"
    [ -f "$registry" ] || return 0
    /usr/bin/python3 - "$registry" "$1" <<'PY'
import json, sys
path, distro = sys.argv[1], sys.argv[2]
with open(path) as f:
    data = json.load(f)
data.pop(distro, None)
with open(path, "w") as f:
    json.dump(data, f)
PY
}

section_accounts_extra() {
    echo "accounts-extra"
    local d=debian pw='Correct-Horse-9 $pace' printed

    # A name that already exists in the guest is refused, and another is taken.
    fresh $d || return
    g $d 'useradd -m -s /bin/bash abi && echo ABI-EXISTS' >/dev/null
    "$M" --shutdown $d >/dev/null 2>&1; wait_state $d stopped
    forget_default_user $d
    printed=$(/usr/bin/expect -f "$HERE/account-name-taken.exp" "$M" $d abi abinew "$pw" 2>&1 | tr -d '\r' \
        | perl -pe 's/\e\][^\a\e]*(?:\a|\e\\)//g; s/\e\[[0-9;?]*[A-Za-z]//g')
    echo "$printed" | grep -q '^OK-TAKEN-NAME-REFUSED$' && ok "a username that already exists is refused" \
        || bad "a username that already exists is refused" "$(echo "$printed" | grep -E '^(BAD|OK)-' | tr '\n' ' ')"
    echo "$printed" | grep -q '^OK-ASKED-AGAIN$' && ok "the prompt asks again after refusing" || bad "the prompt asks again after refusing"
    echo "$printed" | grep -q '^LOGIN=abinew$' && ok "the second name is created and logs in" \
        || bad "the second name is created and logs in" "$(echo "$printed" | grep -E '^LOGIN=|^BAD-' | tr '\n' ' ')"
    "$M" --shutdown $d >/dev/null 2>&1; "$M" remove $d >/dev/null 2>&1
    forget_default_user $d

    # First start with the Network gate closed still gets a working sudo.
    fresh $d || return
    forget_default_user $d
    q "SANDBOX SET $d 1000" >/dev/null
    printed=$(/usr/bin/expect -f "$HERE/smoke-account.exp" "$M" $d msltest "$pw" 2>&1 | tr -d '\r' \
        | perl -pe 's/\e\][^\a\e]*(?:\a|\e\\)//g; s/\e\[[0-9;?]*[A-Za-z]//g')
    offline=$(g $d 'ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1 && echo NET-UP || echo NET-DOWN' | tail -1)
    [ "$offline" = NET-DOWN ] && ok "the guest really was offline during first start" || bad "the guest really was offline during first start" "$offline"
    if echo "$printed" | grep -q '^OK-SUDO-WITH-PASSWORD$' && echo "$printed" | grep -q '^OK-SUDO-NEEDS-PASSWORD$' \
        && ! echo "$printed" | grep -q '^BAD-'; then
        ok "an account created offline gets a working sudo"
    else
        bad "an account created offline gets a working sudo" "$(echo "$printed" | grep -E '^(OK|BAD|ACCOUNT)-' | tr '\n' ' ')"
    fi

    # SSH, set up after the account exists, lands as that account.
    q "SANDBOX SET $d 0000" >/dev/null
    "$M" ssh $d --print >/dev/null 2>&1
    who=$(ssh -o BatchMode=yes -o ConnectTimeout=15 "msl-$d" 'whoami' 2>&1 < /dev/null | tail -1)
    [ "$who" = msltest ] && ok "ssh msl-$d lands as the account created at first start" || bad "ssh msl-$d lands as the created account" "$who"
    keys=$(g $d 'grep -c "" /home/msltest/.ssh/authorized_keys 2>/dev/null || echo 0' | tail -1)
    [ "${keys:-0}" -ge 1 ] && ok "MSL's key is in msltest's authorized_keys" || bad "MSL's key is in msltest's authorized_keys" "$keys"

    "$M" --shutdown $d >/dev/null 2>&1; "$M" remove $d >/dev/null 2>&1
    forget_default_user $d
}

# ---------------------------------------------------------------- SSH after a reboot
section_ssh_reboot() {
    echo "ssh-reboot"
    local d=debian
    fresh $d || return
    g $d 'echo up' >/dev/null
    "$M" ssh $d --print >/dev/null 2>&1
    before=$(ssh -o BatchMode=yes -o ConnectTimeout=15 "msl-$d" 'echo SSH-OK' 2>&1 < /dev/null | tail -1)
    [ "$before" = SSH-OK ] && ok "ssh msl-$d before the reboot" || bad "ssh msl-$d before the reboot" "$before"
    host1=$(sed -n "/# >>> MSL $d >>>/,/# <<< MSL $d <<</s/^ *HostName //p" ~/.ssh/config)
    "$M" --shutdown $d >/dev/null 2>&1; wait_state $d stopped
    g $d 'echo up' >/dev/null
    sleep 5
    after=$(ssh -o BatchMode=yes -o ConnectTimeout=15 "msl-$d" 'echo SSH-OK' 2>&1 < /dev/null | tail -1)
    host2=$(g $d "ip -4 -o addr show scope global | awk '{print \$4}' | cut -d/ -f1 | head -1" | tail -1)
    if [ "$after" = SSH-OK ]; then
        ok "ssh msl-$d still works after a reboot, with no setup (address $host1 -> $host2)"
    else
        note "ssh msl-$d without re-setup after a reboot: $after (address $host1 -> $host2)"
        "$M" ssh $d --print >/dev/null 2>&1
        again=$(ssh -o BatchMode=yes -o ConnectTimeout=15 "msl-$d" 'echo SSH-OK' 2>&1 < /dev/null | tail -1)
        [ "$again" = SSH-OK ] && ok "setting SSH up again after a reboot rewrites the entry and works" || bad "setting SSH up again after a reboot works" "$again"
    fi
    [ "$(grep -c "^Host msl-$d\$" ~/.ssh/config)" = 1 ] && ok "one ssh entry for $d, not a pile of stale ones" || bad "one ssh entry for $d" "$(grep -c "^Host msl-$d\$" ~/.ssh/config)"
    "$M" --shutdown $d >/dev/null 2>&1; "$M" remove $d >/dev/null 2>&1
}

# ---------------------------------------------------------------- Sandbox gate across hibernate
section_sandbox_hibernate() {
    echo "sandbox-hibernate"
    local d=debian
    fresh $d || return
    g $d 'echo up' >/dev/null
    q "SANDBOX SET $d 1000" >/dev/null
    "$M" hibernate $d >/dev/null 2>&1
    sleep 3
    out=$(g $d 'ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1 && echo NET-UP || echo NET-DOWN')
    token=$(q "SANDBOX GET $d" | awk '{print $2}')
    echo "$out" | grep -q NET-DOWN && ok "a cut network stays cut across hibernate and resume" || bad "a cut network stays cut across hibernate and resume" "$out"
    case "$token" in 1*) ok "the gate still reads closed after resuming ($token)" ;; *) bad "the gate still reads closed after resuming" "$token" ;; esac
    q "SANDBOX SET $d 0000" >/dev/null
    "$M" --shutdown $d >/dev/null 2>&1; "$M" remove $d >/dev/null 2>&1
}

# ---------------------------------------------------------------- a large upload cut off mid-copy
section_put_kill() {
    echo "put-kill"
    local d=debian port big
    fresh $d || return
    g $d 'echo up' >/dev/null
    port=$(webdav_port $d)
    [ -n "$port" ] || { bad "the WebDAV bridge answers" "no bridge for $d"; return; }
    big=$(mktemp); head -c 67108864 /dev/urandom > "$big"
    curl -s -o /dev/null -m 120 -T "$big" "http://127.0.0.1:$port/root/msl-cut-off.bin" &
    uploader=$!
    sleep 2
    q "SHUTDOWN $d" 120 >/dev/null      # a hard stop, no guest poweroff
    wait $uploader 2>/dev/null
    rm -f "$big"
    out=$(g $d 'ls -la /root/msl-cut-off.bin 2>&1; ls -A /root | grep "^\.msl-put-" || true')
    if echo "$out" | grep -q "No such file"; then
        ok "a 64 MiB upload cut off by a hard stop leaves no file under its final name"
    else
        bad "a cut-off upload leaves no file under its final name" "$(echo "$out" | head -2 | tr '\n' ' ')"
    fi
    temps=$(echo "$out" | grep -c "^\.msl-put-")
    note "upload temps left behind: $temps (swept by fileopsd once they are an hour old)"
    "$M" --shutdown $d >/dev/null 2>&1; "$M" remove $d >/dev/null 2>&1
}

# ---------------------------------------------------------------- very deep paths
section_deep_path() {
    echo "deep-path"
    local d=debian port
    fresh $d || return
    g $d 'echo up' >/dev/null
    port=$(webdav_port $d)
    [ -n "$port" ] || { bad "the WebDAV bridge answers" "no bridge for $d"; return; }
    # 200-character names nest past PATH_MAX quickly; cd step by step so no
    # single syscall sees the whole path.
    depth=$(g $d 'n=$(printf "%0200d" 0); cd /root && mkdir -p deep && cd deep && i=0; while [ $i -lt 22 ]; do mkdir "$n" && cd "$n" || break; i=$((i+1)); done; touch leaf; pwd | wc -c' | tail -1)
    note "created a directory path $depth bytes long"
    code=$(curl -s -o /dev/null -w '%{http_code}' -m 60 -X PROPFIND -H 'Depth: 1' "http://127.0.0.1:$port/root/deep/")
    [ "$code" = 207 ] && ok "listing the top of a path deeper than PATH_MAX still works (HTTP $code)" || bad "listing the top of a very deep path" "HTTP $code"
    pgrep -f 'bin/mslhd' >/dev/null && ok "mslhd is still up" || bad "mslhd is still up"
    g $d 'rm -rf /root/deep' >/dev/null
    "$M" --shutdown $d >/dev/null 2>&1; "$M" remove $d >/dev/null 2>&1
}

# ---------------------------------------------------------------- dynamic memory
section_memory() {
    echo "memory"
    local d=debian policy="$A/resources/debian.json" ceiling=4096 floor=1024
    fresh $d || return
    mkdir -p "$A/resources"
    printf '{"memory":{"dynamic":{"floorMegabytes":%d,"ceilingMegabytes":%d}}}' $floor $ceiling > "$policy"
    g $d 'echo up' >/dev/null
    total=$(g $d "awk '/MemTotal/ {print int(\$2/1024)}' /proc/meminfo" | tail -1)
    note "guest sees ${total} MiB at boot (ceiling $ceiling)"
    first=$(q "MEMORY $d")
    note "memd/balloon at start: $first"
    footprint_before=$(ps -o rss= -p "$(pgrep -f com.apple.Virtualization.VirtualMachine | head -1)" | awk '{print int($1/1024)}')
    # Idle for a while so the governor has something to take back - with one
    # session held open the whole time. Short separate sessions let the idle
    # suspend pause the guest between them, and a paused guest has no
    # governor running, which is all the first version of this test measured.
    g $d 'sleep 170' >/dev/null &
    holder_session=$!
    sleep 5
    samples=""
    for _ in 1 2 3 4 5 6 7 8; do
        s=$(q "MEMORY $d")
        note "  $s"
        samples="$samples$s
"
        sleep 20
    done
    later=$(q "MEMORY $d")

    # The flap this caught before 2026-09-14: the balloon's own pages read as
    # the guest's demand, so an idle guest went reclaim, raise, reclaim. After
    # the first reclaim nothing may be raised, and "in use" must stay the
    # guest's real use, not the balloon's size.
    after_first_reclaim=$(echo "$samples" | sed -n '/reclaimed/,$p')
    raises=$(echo "$after_first_reclaim" | grep -c "reason=raised")
    [ "$raises" = 0 ] && ok "an idle dynamic guest is not raised again after a reclaim (no flapping)" \
        || bad "an idle dynamic guest is not raised again after a reclaim" "$raises raise(s) after reclaiming"
    max_inuse_mb=$(echo "$samples" | sed -n 's/.*inuse=\([0-9]*\).*/\1/p' | sort -n | tail -1)
    max_inuse_mb=$(( ${max_inuse_mb:-0} / 1048576 ))
    [ "$max_inuse_mb" -lt 600 ] && ok "reported in-use memory is the guest's real use (peak ${max_inuse_mb} MiB), not the balloon" \
        || bad "reported in-use memory is the guest's real use" "peaked at ${max_inuse_mb} MiB on an idle guest"
    footprint_after=$(ps -o rss= -p "$(pgrep -f com.apple.Virtualization.VirtualMachine | head -1)" | awk '{print int($1/1024)}')
    note "memd/balloon after 2 idle minutes: $later"
    note "Virtualization process resident memory: ${footprint_before} MiB -> ${footprint_after} MiB"
    case "$later" in OK*) ok "the daemon reports dynamic memory for a dynamic instance" ;; *) bad "the daemon reports dynamic memory for a dynamic instance" "$later" ;; esac
    if [ -n "$footprint_after" ] && [ -n "$footprint_before" ] && [ "$footprint_after" -lt "$footprint_before" ]; then
        ok "the Mac got memory back while the guest idled (${footprint_before} -> ${footprint_after} MiB)"
    else
        note "no drop in the Virtualization process's resident memory while idle (${footprint_before} -> ${footprint_after} MiB)"
    fi
    wait $holder_session 2>/dev/null

    # Hibernate: does the saved state hold the ceiling or what's in use?
    g $d 'echo DYNAMIC-MEMORY-MARK > /dev/shm/msl-dyn' >/dev/null
    "$M" hibernate $d >/dev/null 2>&1
    sleep 2
    size=$(stat -f %z "$A/vm-$d.state" 2>/dev/null)
    note "saved state in dynamic mode: $(( ${size:-0} / 1048576 )) MiB (ceiling $ceiling MiB)"
    out=$(g $d 'cat /dev/shm/msl-dyn 2>&1')
    echo "$out" | grep -q DYNAMIC-MEMORY-MARK && ok "a dynamic-mode instance restores from hibernate with its memory" || bad "a dynamic-mode instance restores from hibernate" "$out"

    # Named snapshot in dynamic mode.
    g $d 'echo DYNAMIC-SNAPSHOT > /dev/shm/msl-dyn-snap' >/dev/null
    "$M" snapshot save $d dyn >/dev/null 2>&1
    g $d 'rm -f /dev/shm/msl-dyn-snap' >/dev/null
    "$M" snapshot restore $d dyn >/dev/null 2>&1
    out=$(g $d 'cat /dev/shm/msl-dyn-snap 2>&1')
    echo "$out" | grep -q DYNAMIC-SNAPSHOT && ok "a snapshot taken in dynamic mode restores" || bad "a snapshot taken in dynamic mode restores" "$out"
    rm -f "$A/vm-$d-dyn.state"

    "$M" --shutdown $d >/dev/null 2>&1; "$M" remove $d >/dev/null 2>&1
    rm -f "$policy"
}

for s in "$@"; do
    fn="section_${s//-/_}"
    declare -f "$fn" >/dev/null || { echo "unknown section: $s" >&2; continue; }
    "$fn"
    echo "    [after $s] mounts=$(mount | grep -c webdav) vz=$(pgrep -f com.apple.Virtualization.VirtualMachine | wc -l | tr -d ' ') registered=[$("$M" list | sed 's/^OK //')]"
done
echo "backlog-test: $pass passed, $fail failed"
[ "$fail" = 0 ]
