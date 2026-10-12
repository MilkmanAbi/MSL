#!/bin/bash
# Two hours of GIMP, stopping dead the instant a death is recorded.
#
# "Alive" is not the bar - a wedged client is still a running process. Each
# check requires the SERVER to answer (xdpyinfo completes) as well as the app
# to exist. On a death everything is captured at once: the client's stack via
# the xspy shim, mslgd's wire rings, the invariants, and the last actions.
export PATH="$HOME/Library/Application Support/MSL/bin:$PATH"
PY=/Library/Frameworks/Python.framework/Versions/3.14/bin/python3
D=$HOME/msl-debug
OUT=$D/hell/$(date +%Y%m%d-%H%M%S)
mkdir -p "$OUT"
DEADLINE=$(( $(date +%s) + 7200 ))
LOG=$HOME/Library/Logs/MSL/msl.log

cleanup() { $PY /Users/abinaash/Desktop/MSL-Project/input_sim.py release >/dev/null 2>&1; }
trap cleanup EXIT INT TERM
say() { echo "$(date +%T) $*" | tee -a "$OUT/hell.log"; }

capture() {
  say "*** DEATH on round $1, cycle $2 - capturing ***"
  msl Ubuntu sh /mnt/mac/msl-debug/death.sh   > "$OUT/client-stack.txt" 2>&1
  msl Ubuntu sh /mnt/mac/msl-debug/alive.sh   > "$OUT/client-counters.txt" 2>&1
  tr -d '\0' < "$LOG" 2>/dev/null | grep 'x11' | tail -60 > "$OUT/server-rings.txt"
  tr -d '\0' < "$LOG" 2>/dev/null | tail -200 > "$OUT/msl.log"
  for k in 'WENT BACKWARDS' UNANSWERED 'LENGTH MISMATCH' 'write failed' 'QUEUE FULL'; do
    echo "$k: $(tr -d '\0' < "$LOG" | grep -c "$k")" >> "$OUT/invariants.txt"
  done
  find ~/Library/Logs/DiagnosticReports -name '*.ips' -newermt '-10 minutes' -exec cp {} "$OUT/" \; 2>/dev/null
  say "captured to $OUT"
}

: > "$LOG"
CYCLE=0; ROUNDS=0
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  CYCLE=$((CYCLE+1))
  msl Ubuntu sh /mnt/mac/msl-debug/build-xspy.sh >/dev/null 2>&1
  msl Ubuntu sh /mnt/mac/msl-debug/stage.sh      >/dev/null 2>&1
  msl Ubuntu sh /mnt/mac/msl-debug/run-xspy.sh   >/dev/null 2>&1
  sleep 25
  S=$(msl Ubuntu sh /mnt/mac/msl-debug/served.sh 2>/dev/null | tail -1)
  case "$S" in gimp:0*) say "cycle $CYCLE: gimp never came up ($S)"; continue;; esac
  say "cycle $CYCLE: up"

  for r in $(seq 1 40); do
    [ "$(date +%s)" -ge "$DEADLINE" ] && break
    $PY "$D/churn.py" >> "$OUT/actions.log" 2>&1
    ROUNDS=$((ROUNDS+1))
    S=$(msl Ubuntu sh /mnt/mac/msl-debug/served.sh 2>/dev/null | tail -1)
    case "$S" in
      gimp:0*|*served:NO*)
        capture "$r" "$CYCLE"
        say "=== STOPPING: $ROUNDS churn rounds survived across $CYCLE cycles ==="
        echo "$S" > "$OUT/VERDICT-DIED"
        exit 1 ;;
    esac
  done
  msl Ubuntu pkill -x gimp >/dev/null 2>&1
done
say "=== SURVIVED two hours: $ROUNDS churn rounds across $CYCLE cycles ==="
echo "$ROUNDS rounds, $CYCLE cycles" > "$OUT/VERDICT-SURVIVED"
exit 0
