#!/bin/bash
# gtkscroll.sh MODE [native] - MODE core|xi2
here=$(dirname "$0")
[ "$1" = core ] && export GDK_CORE_DEVICE_EVENTS=1
shift
exec python3 "$here/gtkscroll.py" "$@" >/tmp/gtkscroll.log 2>&1
