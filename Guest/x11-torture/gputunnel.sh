#!/bin/bash
# Starts the guest end of the GPU bridge: /tmp/.virgl_test -> vsock 5011.
# (x11tunnel's relay carries any stream; see its --socket-path option.)
pkill -f "socket-path /tmp/.virgl_test" 2>/dev/null
rm -f /tmp/.virgl_test
setsid "${TUNNEL:-/tmp/x11tunnel-new}" 0 5011 --socket-path /tmp/.virgl_test </dev/null >/dev/null 2>&1 &
sleep 1
ls -la /tmp/.virgl_test
