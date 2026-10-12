#!/bin/sh
# Real apps, not probes. A wedged app is still a running app, so each check
# confirms the process lives AND the server still answers.
check() {
  NAME="$1"; shift
  pkill -f "$NAME" 2>/dev/null; sleep 2
  setsid "$@" </dev/null >/tmp/$NAME.out 2>&1 &
  sleep 20
  A=$(pgrep -fc "$NAME")
  timeout 12 xdpyinfo -display :1 >/dev/null 2>&1 && S=yes || S=NO
  E=$(grep -icE 'BadLength|BadMatch|BadValue|BadDrawable|BadPixmap|BadPicture|X Error' /tmp/$NAME.out 2>/dev/null)
  echo "$NAME: alive=$A served=$S x_errors=$E"
  pkill -f "$NAME" 2>/dev/null; sleep 1
}
check xterm xterm
check xclock xclock
check gimp gimp /tmp/Error.png
