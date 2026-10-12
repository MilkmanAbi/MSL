#!/bin/sh
pkill -x gimp 2>/dev/null; pkill gdb 2>/dev/null; pkill -f gimp 2>/dev/null
sleep 3
rm -f /tmp/xspy.log
export LD_PRELOAD=/tmp/xspy.so
export XSPY_LOG=/tmp/xspy.log
export G_MESSAGES_DEBUG=all GDK_SYNCHRONIZE=1
setsid sh -c 'exec gimp /tmp/Error.png' </dev/null >/tmp/gimp-xspy.out 2>&1 &
sleep 3
echo "gimp pid: $(pgrep -x gimp | head -1)"
