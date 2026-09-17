#!/bin/bash
# Exercises the MSL features that only a booted guest can prove, through the
# real daemon: hibernate and restore, named snapshots, SSH, the Sandbox's
# network gate, the Finder (WebDAV) bridge, and the Maintenance card's
# utilities and maintenance boot.
#
#   image-build/feature-test.sh INSTANCE
#
# Meant for a freshly installed image (smoke-test.sh leaves one installed).
# Run it with no other instance running - the WebDAV port is found by asking
# mslhd which ports it listens on. Snapshot restore replays memory over a
# disk that has moved on, so re-install the image afterwards before using
# the instance for anything real (smoke-test.sh does).
set -u

[ $# -eq 1 ] || { echo "usage: $0 INSTANCE" >&2; exit 2; }
I=$1
A="$HOME/Library/Application Support/MSL"
M="$A/bin/msl"
SOCK="$A/mslhd.sock"

fifo=$(mktemp -u "${TMPDIR:-/tmp}/msl-feature.XXXXXX")
mkfifo "$fifo"
sleep 3600 > "$fifo" &
holder=$!
trap 'kill $holder 2>/dev/null; rm -f "$fifo"' EXIT

g() { "$M" "$I" -u root "$1" < "$fifo" 2>&1 | tr -d '\r'; }
q() { printf '%s\n' "$1" | nc -U -w "${2:-60}" "$SOCK"; }
pass=0; fail=0
ok()  { echo "  ok    $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1${2:+ - $2}"; fail=$((fail + 1)); }
wait_state() { for _ in $(seq 1 60); do [ "$("$M" status "$I" 2>&1)" = "OK $1" ] && return 0; sleep 1; done; return 1; }

echo "feature-test[$I]"

# ------------------------------------------------------------ hibernate
before=$(g 'x=MARK$RANDOM$RANDOM; echo $x > /dev/shm/msl-feature; echo $x; cat /proc/sys/kernel/random/boot_id')
"$M" hibernate "$I" >/dev/null 2>&1
# Checked after a pause, not at once: a leftover Finder mount used to wake
# the instance moments later and throw the saved state away (2026-09-14).
sleep 10
status_after=$("$M" status "$I" 2>&1)
if [ -f "$A/vm-$I.state" ] && [ "$status_after" = "OK stopped" ]; then
    ok "hibernate saves its state and it stays saved"
else
    bad "hibernate saves its state and it stays saved" "$status_after, state file $([ -f "$A/vm-$I.state" ] && echo present || echo missing)"
fi
after=$(g 'cat /dev/shm/msl-feature 2>&1; cat /proc/sys/kernel/random/boot_id')
if [ -n "$before" ] && [ "$(echo "$before" | tail -2)" = "$(echo "$after" | tail -2)" ]; then
    ok "restore resumes the same boot with its memory intact"
else
    bad "restore resumes the same boot with its memory intact" "before: $(echo $before) / after: $(echo $after)"
fi
[ -f "$A/vm-$I.state" ] && bad "a used saved state is deleted" || ok "a used saved state is deleted"

# ------------------------------------------------------------ snapshots
g 'echo SNAPSHOT-MEMORY > /dev/shm/msl-snapshot' >/dev/null
"$M" snapshot save "$I" feature >/dev/null 2>&1
[ -f "$A/vm-$I-feature.state" ] && ok "snapshot save writes vm-$I-feature.state" || bad "snapshot save writes its file"
"$M" snapshot list "$I" 2>&1 | grep -q feature && ok "snapshot list shows it" || bad "snapshot list shows it"
g 'rm -f /dev/shm/msl-snapshot' >/dev/null
"$M" snapshot restore "$I" feature >/dev/null 2>&1
restored=$(g 'cat /dev/shm/msl-snapshot 2>&1')
echo "$restored" | grep -q SNAPSHOT-MEMORY && ok "snapshot restore brings back its memory" || bad "snapshot restore brings back its memory" "$restored"
rm -f "$A/vm-$I-feature.state"

# ------------------------------------------------------------ SSH
if "$M" ssh "$I" --print > /tmp/msl-feature-ssh.txt 2>&1; then
    ok "msl ssh --print sets SSH up: $(tail -1 /tmp/msl-feature-ssh.txt)"
    out=$(ssh -o BatchMode=yes -o ConnectTimeout=15 "msl-$I" 'echo SSH-OK; whoami' 2>&1 < /dev/null)
    echo "$out" | grep -q SSH-OK && ok "ssh msl-$I connects ($(echo "$out" | tail -1))" || bad "ssh msl-$I connects" "$(echo "$out" | tail -2 | tr '\n' ' ')"
else
    bad "msl ssh --print sets SSH up" "$(tail -2 /tmp/msl-feature-ssh.txt | tr '\n' ' ')"
fi

# ------------------------------------------------------------ Sandbox network gate
original=$(q "SANDBOX GET $I" | awk '{print $2}')
case "$original" in [01][01][01][01]) ;; *) echo "  (SANDBOX GET answered '$original' - assuming every gate open)"; original=0000 ;; esac
q "SANDBOX SET $I 1${original:1:3}" >/dev/null
cut=$(g 'ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1 && echo NET-UP || echo NET-DOWN; echo VSOCK-STILL-WORKS')
echo "$cut" | grep -q NET-DOWN && ok "closing the Network gate cuts the guest off" || bad "closing the Network gate cuts the guest off" "$cut"
echo "$cut" | grep -q VSOCK-STILL-WORKS && ok "msl still reaches the guest with the Network gate closed" || bad "msl works with the Network gate closed"
q "SANDBOX SET $I 0${original:1:3}" >/dev/null
sleep 3
back=$(g 'ping -c 1 -W 5 1.1.1.1 >/dev/null 2>&1 && echo NET-UP || echo NET-DOWN')
echo "$back" | grep -q NET-UP && ok "reopening the Network gate restores the network" || bad "reopening the Network gate restores the network" "$back"

# A closed gate is re-applied on every start. Doing that off the VM's queue
# crashed mslhd on any cold boot with a gate closed (fixed 2026-09-14).
daemon_before=$(pgrep -f 'bin/mslhd')
q "SANDBOX SET $I 0010" >/dev/null
"$M" --shutdown "$I" >/dev/null 2>&1; wait_state stopped
booted=$(g 'echo BOOTED-WITH-A-GATE-CLOSED')
daemon_after=$(pgrep -f 'bin/mslhd')
if echo "$booted" | grep -q BOOTED-WITH-A-GATE-CLOSED && [ "$daemon_before" = "$daemon_after" ]; then
    ok "a cold boot with a Sandbox gate closed works, and mslhd survives it"
else
    bad "a cold boot with a Sandbox gate closed works, and mslhd survives it" "daemon $daemon_before -> $daemon_after; $booted"
fi
q "SANDBOX SET $I 0000" >/dev/null

# ------------------------------------------------------------ WebDAV (the Finder bridge)
# The bridge whose guest has this instance's hostname - not merely the first
# that answers. Another running instance's bridge answers too, and uploads
# then land in the wrong guest while the download still matches (it did,
# 2026-09-14, when an Alpine instance was left running).
port=""
want_host=$(g 'cat /etc/hostname' | tail -1)
for p in $(lsof -nP -iTCP -sTCP:LISTEN -a -p "$(pgrep -f 'bin/mslhd')" 2>/dev/null | awk 'NR>1 {sub(/.*:/, "", $9); print $9}'); do
    [ "$(curl -s -m 20 "http://127.0.0.1:$p/etc/hostname" | head -1)" = "$want_host" ] && { port=$p; break; }
done
if [ -z "$port" ]; then
    bad "the WebDAV bridge answers" "no mslhd listener serves a guest named '$want_host'"
else
    ok "the WebDAV bridge answers on 127.0.0.1:$port"
    big=$(mktemp); head -c 6291456 /dev/urandom > "$big"
    want=$(shasum -a 256 "$big" | cut -d' ' -f1)
    code=$(curl -s -o /dev/null -w '%{http_code}' -m 120 -T "$big" "http://127.0.0.1:$port/root/msl-feature-6mib.bin")
    got=$(g 'sha256sum /root/msl-feature-6mib.bin' | tail -1 | cut -d' ' -f1)
    [ "$want" = "$got" ] && ok "a 6 MiB upload lands intact (HTTP $code)" || bad "a 6 MiB upload lands intact" "HTTP $code, $want vs $got"
    back_sha=$(curl -s -m 120 "http://127.0.0.1:$port/root/msl-feature-6mib.bin" | shasum -a 256 | cut -d' ' -f1)
    [ "$want" = "$back_sha" ] && ok "downloading it returns the same bytes" || bad "downloading it returns the same bytes"
    g 'printf "#!/bin/sh\necho hi\n" > /root/msl-feature.sh; chmod 755 /root/msl-feature.sh' >/dev/null
    printf '#!/bin/sh\necho edited\n' > "$big.small"
    curl -s -o /dev/null -m 60 -T "$big.small" "http://127.0.0.1:$port/root/msl-feature.sh"
    mode=$(g 'stat -c %a /root/msl-feature.sh' | tail -1)
    [ "$mode" = 755 ] && ok "saving over a script keeps its +x (small file)" || bad "saving over a script keeps its +x (small file)" "mode $mode"
    curl -s -o /dev/null -m 120 -T "$big" "http://127.0.0.1:$port/root/msl-feature.sh"
    mode=$(g 'stat -c %a /root/msl-feature.sh' | tail -1)
    [ "$mode" = 755 ] && ok "saving over a script keeps its +x (over 4 MiB)" || bad "saving over a script keeps its +x (over 4 MiB)" "mode $mode"
    leftovers=$(g 'ls -A /root | grep -c "^\.msl-put-" || true' | tail -1)
    [ "$leftovers" = 0 ] && ok "no upload temps left behind" || bad "no upload temps left behind" "$leftovers"
    g 'rm -f /root/msl-feature-6mib.bin /root/msl-feature.sh' >/dev/null
    rm -f "$big" "$big.small"
fi

# ------------------------------------------------------------ Maintenance
for u in util-clock util-free-space util-disk-errors; do
    r=$(q "MAINTENANCE $I $u" 300)
    case "$r" in OK*) ok "maintenance $u: $(echo "$r" | head -1 | cut -c1-90)" ;; *) bad "maintenance $u" "$(echo "$r" | head -2 | tr '\n' ' ')" ;; esac
done
"$M" --shutdown "$I" >/dev/null 2>&1
wait_state stopped || bad "instance stops for the maintenance boot"
r=$(q "MAINTENANCE $I boot-fsck-check" 900)
case "$r" in OK*) ok "maintenance boot filesystem check: $(echo "$r" | head -1 | cut -c1-90)" ;; *) bad "maintenance boot filesystem check" "$(echo "$r" | head -3 | tr '\n' ' ')" ;; esac

"$M" --shutdown "$I" >/dev/null 2>&1
echo "feature-test[$I]: $pass passed, $fail failed"
[ "$fail" = 0 ]
