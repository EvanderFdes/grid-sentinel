#!/usr/bin/env bash
set -euo pipefail

# Static IP of the unbacked wall-powered Pi
PI_IP="192.168.x.x"

# 24 failed attempts * 5s interval = 120s sustained grid outage required
MAX_FAILURES=24
POLL_INTERVAL=5
FAIL_COUNT=0

while true; do
    if ping -c 1 -W 2 "$PI_IP" > /dev/null 2>&1; then
        if [ "$FAIL_COUNT" -gt 0 ]; then
            logger -t grid-sentinel "Pi returned online. Resetting failure counter."
            FAIL_COUNT=0
        fi
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        logger -t grid-sentinel "Ping to wall-anchor ($PI_IP) failed [$FAIL_COUNT/$MAX_FAILURES]"

        if [ "$FAIL_COUNT" -ge "$MAX_FAILURES" ]; then
            logger -t grid-sentinel "Grid power loss confirmed. Executing emergency shutdown."
            /sbin/shutdown -h now "Grid failure detected: wall anchor offline for ${MAX_FAILURES} cycles."
            exit 0
        fi
    fi
    sleep "$POLL_INTERVAL"
done
