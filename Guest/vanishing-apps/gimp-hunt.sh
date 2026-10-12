#!/bin/bash
# An hour of GIMP, on repeat, until it vanishes - then again.
#
# Everything here is built around one fact: when this bug fires the app
# calls _exit(1) from GDK's X11 I/O error handler, so there is no crash
# report and nothing in GIMP's own log. The evidence lives in three places
# that must be captured AT THE MOMENT of death: gdb's stop (which breakpoint,
# the xcb verdict, the stack), mslgd's ring dump in msl.log (the last
# requests in and packets out), and what was being done to the window.
export PATH="/opt/homebrew/bin:$HOME/Library/Application Support/MSL/bin:$PATH"
PROJ=/Users/abinaash/Desktop/MSL-Project
D=$HOME/msl-debug
OUT=$D/runs/$(date +%Y%m%d-%H%M%S)
mkdir -p "$OUT"
DEADLINE=$(( $(date +%s) + 3600 ))
MODEL=${MODEL:-qwen2.5vl:7b}

# Any exit path clears modifiers. A Control left down in the WINDOW SERVER
# outlives this script and makes the Mac feel broken afterwards.
cleanup() { /Library/Frameworks/Python.framework/Versions/3.14/bin/python3 "$PROJ/input_sim.py" release >/dev/null 2>&1; }
trap cleanup EXIT INT TERM

say() { echo "$(date +%T) $*" | tee -a "$OUT/hunt.log"; }

launch() {
  msl Ubuntu sh /mnt/mac/msl-debug/run6.sh >/dev/null 2>&1
  for _ in $(seq 1 40); do
    if W=$(/Library/Frameworks/Python.framework/Versions/3.14/bin/python3 "$D/haswin.py" 2>>"$OUT/hunt.log"); then
      say "window: $W"
      return 0
    fi
    sleep 5
  done
  return 1
}

capture() {   # $1 = why
  local n="$OUT/death-$(date +%H%M%S)"
  mkdir -p "$n"
  say "*** DIED ($1) - capturing to $(basename "$n") ***"
  msl Ubuntu sh /mnt/mac/msl-debug/verdict2.sh > "$n/gdb.txt" 2>&1
  # The ring dump is the point: mslgd's last requests and packets out.
  grep 'x11' "$HOME/Library/Logs/MSL/msl.log" 2>/dev/null | tail -40 > "$n/x11.txt"
  tail -120 "$HOME/Library/Logs/MSL/msl.log" 2>/dev/null > "$n/msl.log"
  tail -40 "$OUT/actions.log" 2>/dev/null > "$n/last-actions.txt"
  find ~/Library/Logs/DiagnosticReports -name '*.ips' -newermt '-5 minutes' \
       -exec cp {} "$n/" \; 2>/dev/null
  cp "$(ls -t $D/shots/*.png 2>/dev/null | head -3)" "$n/" 2>/dev/null
  echo "$1" > "$n/why.txt"
}

DEATHS=0; CYCLES=0
while [ "$(date +%s)" -lt "$DEADLINE" ] && [ ! -f "$D/STOP" ]; do
  CYCLES=$((CYCLES+1))
  say "--- cycle $CYCLES (deaths so far: $DEATHS) ---"
  if ! launch; then say "no window appeared; retrying"; continue; fi
  say "gimp up"

  # Inner loop: act until it dies or the cycle times out.
  CYCLE_END=$(( $(date +%s) + 420 ))
  while [ "$(date +%s)" -lt "$CYCLE_END" ]; do
    [ -f "$D/STOP" ] && break
    if msl Ubuntu sh /mnt/mac/msl-debug/poll.sh 2>/dev/null | grep -q DEAD; then
      DEATHS=$((DEATHS+1)); capture "gdb stop"; break
    fi
    # Layer churn reproduces this far faster than random input, so it
    # gets two turns in three.
    if [ $((RANDOM % 3)) -lt 2 ]; then
      /Library/Frameworks/Python.framework/Versions/3.14/bin/python3 "$D/churn.py" >> "$OUT/actions.log" 2>&1
    else
      /Library/Frameworks/Python.framework/Versions/3.14/bin/python3 "$D/act.py" "$MODEL" >> "$OUT/actions.log" 2>&1
    fi
  done
  pkill -f 'gimp' >/dev/null 2>&1
done

say "=== finished: $CYCLES cycles, $DEATHS deaths ==="
ls -d "$OUT"/death-* 2>/dev/null | wc -l | xargs echo "death records:"
