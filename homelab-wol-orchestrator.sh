#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/etc/homelab-nodes.json"
ROUTER_GATEWAY="192.168.x.x"

logger -t wol-orchestrator "Mains power restored. Starting auto-recovery cycle."

# 1. Wait for local network switch / router to be reachable
MAX_RETRIES=30
COUNTER=0
until ping -c 1 -W 2 "$ROUTER_GATEWAY" > /dev/null 2>&1; do
    sleep 2
    COUNTER=$((COUNTER + 1))
    if [ "$COUNTER" -ge "$MAX_RETRIES" ]; then
        logger -t wol-orchestrator "Gateway unreachable after 60s. Aborting WoL sequence."
        exit 1
    fi
done

# 2. Allow extra 10 seconds for ARP tables and switch fabrics to settle
sleep 10

BROADCAST=$(jq -r '.broadcast_ip' "$CONFIG_FILE")

# 3. Iterate through configured servers
jq -c '.nodes[]' "$CONFIG_FILE" | while read -r item; do
    NAME=$(echo "$item" | jq -r '.name')
    IP=$(echo "$item" | jq -r '.ip')
    MAC=$(echo "$item" | jq -r '.mac')
    PORT=$(echo "$item" | jq -r '.port')
    DELAY=$(echo "$item" | jq -r '.boot_delay')

    # Check if the node is already running
    if ping -c 1 -W 2 "$IP" > /dev/null 2>&1; then
        logger -t wol-orchestrator "Host $NAME ($IP) is already online. Skipping."
    else
        if [ "$DELAY" -gt 0 ]; then
            logger -t wol-orchestrator "Waiting ${DELAY}s before waking $NAME..."
            sleep "$DELAY"
        fi
        logger -t wol-orchestrator "Dispatching WoL Magic Packet to $NAME ($MAC) via $BROADCAST:$PORT"
        # Send packet 3 times to prevent dropped UDP packet issues
        for i in {1..3}; do
            wakeonlan -i "$BROADCAST" -p "$PORT" "$MAC" > /dev/null 2>&1
            sleep 1
        done
    fi
done

logger -t wol-orchestrator "Recovery sequence completed successfully."
