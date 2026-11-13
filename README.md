# Automated Homelab Grid Sentinel & Remote Recovery (WoL)

An automated, bidirectional power-management system for home and lab infrastructure using battery-backed servers and an unbacked wall-powered sentinel anchor (single-board computer or low-power appliance).

The system initiates an automatic graceful shutdown of battery-backed servers during grid power outages and automatically dispatches Wake-on-LAN (WoL) packets to bring them back up once mains power returns.

---

## Architecture Overview

```
 [ Mains Power (Unprotected Wall Circuit) ]
                    │
           ┌────────┴────────┐
           │ Sentinel Anchor │ (Mains Sensor / WoL Dispatcher / Mesh Node)
           └────────┬────────┘
                    │
         Local LAN (e.g., 192.168.0.0/24)
                    │
┌───────────────────┴───────────────────┐
│ Network Gateway / Switch (UPS-Backed) │ (Always-on switch & local gateway)
└───────────────────┬───────────────────┘
                    │
         Local LAN (e.g., 192.168.0.0/24)
                    │
         ┌──────────┴──────────┐
         │    Managed Host     │ (Sentinel Client on UPS/Inverter Power)
         └─────────────────────┘
```

### Roles & Terminology

* **Sentinel Anchor:** An energy-efficient device (e.g., single-board computer, embedded Linux thin client) connected to an unprotected wall outlet. It serves as the physical indicator of mains presence.
* **Managed Host:** Any server, workstation, or hypervisor connected to battery backup (UPS or inverter).
* **Network Gateway / Switch:** The local network infrastructure, also backed by uninterruptible power, ensuring local switching remains available even during grid loss.

### Event Lifecycle

1. **Grid Power Outage:**
   * The Sentinel Anchor loses power immediately and goes offline.
   * The Managed Host and Network Switch remain powered by battery backup.
   * The Managed Host's sentinel monitor detects consecutive ping failures to the Sentinel Anchor.
   * After a **3-minute sustained failure window** (allowing tolerance for router/switch reboots and firmware updates), the Managed Host initiates a graceful local shutdown.

2. **Grid Power Restoration:**
   * Mains power returns; the Sentinel Anchor boots automatically.
   * The recovery orchestrator on the Sentinel Anchor waits for the local network switch to initialize.
   * The Sentinel Anchor reads a declarative node inventory (`/etc/homelab-nodes.json`) and pings targets to determine state.
   * For servers that remain down, it broadcasts Wake-on-LAN magic packets across the local broadcast address with optional staggered spin-up delays to avoid inrush current surges on power circuits.
   * The Managed Hosts power on and resume normal operation.

---

## Network Prerequisites

* **Subnet:** Ensure static IP assignments or static DHCP reservations for all infrastructure nodes:
  * Network Gateway: `192.168.0.1` (example)
  * Sentinel Anchor: `192.168.0.20` (example)
  * Managed Host: `192.168.0.50` (example)
  * Local Subnet Broadcast: `192.168.0.255` (example)

---

## Step 1: Managed Host BIOS & OS Configuration

### 1.1 BIOS Setup
1. Enter your system BIOS/UEFI setup utility during boot.
2. Under **Power Management** (or equivalent):
   * Set **Wake on LAN (WoL)** to `Enabled` / `LAN Only`.
   * Set **Deep Sleep Control** / **ErP Ready** to `Disabled` (ensures the network interface card keeps auxiliary standby power in S5 shutdown state).
   * Set **AC Recovery / After Power Loss** to `Power Off` or `Stay Off` (power restoration will be handled deterministically via WoL).
3. Save changes and reboot.

### 1.2 Enable Persistent Wake-on-LAN (Linux)
Install network diagnostic and management utilities:

```bash
sudo apt update && sudo apt install -y ethtool network-manager
```

Identify the wired Ethernet interface name and MAC address:

```bash
ip link
```

Verify that the network adapter supports Magic Packet wakeup:

```bash
sudo ethtool <INTERFACE_NAME> | grep -i wake-on
```
*Expected: `Supports Wake-on: pumbg` (where `g` denotes Magic Packet support).*

Configure NetworkManager to keep Wake-on-LAN active across shutdowns:

```bash
# List connection profiles
nmcli connection show

# Enable Magic Packet WoL on your active wired profile
nmcli connection modify "<CONNECTION_NAME>" 802-3-ethernet.wake-on-lan magic
```

---

## Step 2: Managed Host Sentinel Service Setup

Configure the Managed Host to poll the Sentinel Anchor.

### 2.1 Create the Sentinel Script
Create `/usr/local/bin/grid-sentinel.sh`:

```bash
sudo nano /usr/local/bin/grid-sentinel.sh
```

Add the following script:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Static IP of the unbacked wall-powered Sentinel Anchor
SENTINEL_IP="192.168.0.20"

# 36 attempts * 5s interval = 180s (3 minutes) before shutdown
# Accommodates gateway reboots and temporary network interruptions
MAX_FAILURES=36
POLL_INTERVAL=5
FAIL_COUNT=0

while true; do
    if ping -c 1 -W 2 "$SENTINEL_IP" > /dev/null 2>&1; then
        if [ "$FAIL_COUNT" -gt 0 ]; then
            logger -t grid-sentinel "Sentinel anchor reachable. Resetting failure counter."
            FAIL_COUNT=0
        fi
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        logger -t grid-sentinel "Ping to sentinel anchor ($SENTINEL_IP) failed [$FAIL_COUNT/$MAX_FAILURES]"

        if [ "$FAIL_COUNT" -ge "$MAX_FAILURES" ]; then
            logger -t grid-sentinel "Grid power loss confirmed. Executing emergency shutdown."
            /sbin/shutdown -h now "Grid failure detected: sentinel anchor offline for ${MAX_FAILURES} cycles."
            exit 0
        fi
    fi
    sleep "$POLL_INTERVAL"
done
```

Set execution permissions:

```bash
sudo chmod 750 /usr/local/bin/grid-sentinel.sh
```

### 2.2 Create the Systemd Unit
Create `/etc/systemd/system/grid-sentinel.service`:

```ini
[Unit]
Description=Grid Power Sentinel Monitor
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/grid-sentinel.sh
Restart=always
RestartSec=15
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

Reload and enable the service:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now grid-sentinel.service
```

---

## Step 3: Sentinel Anchor Configuration

The Sentinel Anchor detects grid return and coordinates wake-up sequences.

### 3.1 Install Prerequisites
```bash
sudo apt update && sudo apt install -y wakeonlan jq fping curl
```

### 3.2 Optional Secure Remote Access (VPN Mesh)
To wake servers remotely over the internet without WAN port forwarding, configure a VPN overlay (such as Tailscale or WireGuard) on the Sentinel Anchor:

```bash
# Example using Tailscale
curl -fsSL https://tailscale.com/install.sh | sh

# Enable kernel packet forwarding
echo 'net.ipv4.ip_forward = 1' | sudo tee -a /etc/sysctl.d/99-network-forward.conf
echo 'net.ipv6.conf.all.forwarding = 1' | sudo tee -a /etc/sysctl.d/99-network-forward.conf
sudo sysctl -p /etc/sysctl.d/99-network-forward.conf

# Advertise your home subnet
sudo tailscale up --advertise-routes=192.168.0.0/24
```

### 3.3 Declarative Server Inventory
Define target hosts in `/etc/homelab-nodes.json` on the Sentinel Anchor:

```json
{
  "broadcast_ip": "192.168.0.255",
  "nodes": [
    {
      "name": "primary-server",
      "ip": "192.168.0.50",
      "mac": "aa:bb:cc:dd:ee:ff",
      "port": 9,
      "boot_delay": 0
    },
    {
      "name": "storage-nas",
      "ip": "192.168.0.51",
      "mac": "11:22:33:44:55:66",
      "port": 9,
      "boot_delay": 15
    }
  ]
}
```

Set secure file permissions:

```bash
sudo chmod 640 /etc/homelab-nodes.json
```

### 3.4 Recovery Orchestrator Script
Create `/usr/local/bin/homelab-wol-orchestrator.sh`:

```bash
sudo nano /usr/local/bin/homelab-wol-orchestrator.sh
```

Add the following orchestration logic:

```bash
#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/etc/homelab-nodes.json"
ROUTER_GATEWAY="192.168.0.1"

logger -t wol-orchestrator "Mains power restored. Starting auto-recovery cycle."

# 1. Wait for local network switch / gateway to become reachable
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

# 2. Settle window for switch port negotiation and ARP tables
sleep 10

BROADCAST=$(jq -r '.broadcast_ip' "$CONFIG_FILE")

# 3. Process inventory nodes
jq -c '.nodes[]' "$CONFIG_FILE" | while read -r item; do
    NAME=$(echo "$item" | jq -r '.name')
    IP=$(echo "$item" | jq -r '.ip')
    MAC=$(echo "$item" | jq -r '.mac')
    PORT=$(echo "$item" | jq -r '.port')
    DELAY=$(echo "$item" | jq -r '.boot_delay')

    if ping -c 1 -W 2 "$IP" > /dev/null 2>&1; then
        logger -t wol-orchestrator "Host $NAME ($IP) is already online. Skipping."
    else
        if [ "$DELAY" -gt 0 ]; then
            logger -t wol-orchestrator "Waiting ${DELAY}s before waking $NAME..."
            sleep "$DELAY"
        fi
        logger -t wol-orchestrator "Dispatching WoL Magic Packet to $NAME ($MAC) via $BROADCAST:$PORT"
        for i in {1..3}; do
            wakeonlan -i "$BROADCAST" -p "$PORT" "$MAC" > /dev/null 2>&1
            sleep 1
        done
    fi
done

logger -t wol-orchestrator "Recovery sequence completed successfully."
```

Set execution permissions:

```bash
sudo chmod 750 /usr/local/bin/homelab-wol-orchestrator.sh
```

### 3.5 Create the Oneshot Systemd Service
Create `/etc/systemd/system/homelab-recovery.service`:

```ini
[Unit]
Description=Homelab Grid Recovery WoL Dispatcher
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/homelab-wol-orchestrator.sh
RemainAfterExit=true
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

Enable the service:

```bash
sudo systemctl daemon-reload
sudo systemctl enable homelab-recovery.service
```

---

## Step 4: Router / Gateway Hardening

1. **Eliminate WAN Port Forwarding:**
   * Do not forward UDP port `7` or `9` from the public WAN to internal IPs.
   * *Security rationale:* Wake-on-LAN packets are broadcast locally from the Sentinel Anchor, and remote invocation is securely tunneled over encrypted VPN overlays. Publicly exposed ports invite unwanted scanning and packet amplification abuse.
2. **Configure Static DHCP & ARP Bindings:**
   * Reserve static private IP addresses for the Sentinel Anchor and all managed hosts.
   * Configure static IP-MAC bindings where supported to ensure switches route traffic reliably even after hosts have been offline for extended periods.

---

## Step 5: Testing & Verification

### Test 1: Simulated Sentinel Failure
On the Sentinel Anchor, take its primary network interface down temporarily:
```bash
sudo sh -c "ip link set <INTERFACE> down && sleep 200 && ip link set <INTERFACE> up"
```
On the Managed Host, follow the logs:
```bash
sudo journalctl -u grid-sentinel.service -f
```
Verify the failure counter advances from `1/36` to `36/36` and initiates a system shutdown.

### Test 2: Recovery Orchestration Test
With the Managed Host powered off, execute the recovery script manually from the Sentinel Anchor:
```bash
sudo /usr/local/bin/homelab-wol-orchestrator.sh
```
Check log output:
```bash
sudo journalctl -t wol-orchestrator -n 20
```
Verify the target host receives the Magic Packet and powers on.

### Test 3: Full Physical Cycle
1. Disconnect the Sentinel Anchor from wall power.
2. Verify the Managed Host gracefully powers down after 3 minutes.
3. Reconnect the Sentinel Anchor to wall power.
4. Verify the Sentinel Anchor boots, completes its network check, and automatically wakes the Managed Host.

---

## Maintenance & Best Practices

* **Staggered Spin-Up:** When managing multiple servers, configure progressive `boot_delay` values (e.g., `0`, `15`, `30` seconds) in `/etc/homelab-nodes.json` to prevent inrush current surges on your power circuit or backup inverter.
* **Storage Resilience on Sentinel:** Single-board computers and appliances subjected to sudden power cuts should utilize a read-only root filesystem (such as an overlay filesystem) or high-endurance media to prevent filesystem corruption during outages.