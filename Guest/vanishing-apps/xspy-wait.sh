#!/bin/sh
# Drive it the way that reproduces fastest, then report.
i=0
while [ $i -lt 40 ]; do
  if ! pgrep -x gimp >/dev/null; then echo "GIMP GONE after ${i} checks"; break; fi
  grep -q DEATH /tmp/xspy.log 2>/dev/null && { echo "DEATH CAPTURED"; break; }
  sleep 5
  i=$((i+1))
done
echo "--- the moment ---"
grep -nE 'DEATH|XREAD|XRECV|XWRITE' /tmp/xspy.log 2>/dev/null | head -4
echo "--- full death block ---"
awk '/DEATH/{f=1} f' /tmp/xspy.log 2>/dev/null | head -26
