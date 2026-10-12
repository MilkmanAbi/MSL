#!/bin/bash
# replay_as.sh NAME CAPTURE... -- runs xreplay under its own process name,
# so the router gives it a fresh app host (named xreplay-NAME).
name=$1; shift
here=$(dirname "$0")
exec -a "xreplay-$name" python3 "$here/xreplay.py" "$@"
