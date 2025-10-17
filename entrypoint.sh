#!/usr/bin/env bash
set -e

DAEMON="/opt/expressvpn/bin/expressvpn-daemon"
EV_BIN="/opt/expressvpn/bin/expressvpnctl"

echo "Start ExpressVPN daemon..."
pkill -f "expressvpn-daemon" || true
sleep 2
"$DAEMON" >/dev/null 2>&1 &
DAEMON_PID=$!
echo "Daemon started with PID: $DAEMON_PID"
sleep 5

echo "Wait daemon to be ready..."
for i in {1..30}; do
    if $EV_BIN status >/dev/null 2>&1; then
        echo "✓ Daemon ready"
        break
    fi
    sleep 1
done

echo "login ExpressVPN..."
echo "$EXPRESSVPN_ACTIVATION_CODE" > /tmp/activation
$EV_BIN login /tmp/activation
rm /tmp/activation

echo "set Network Lock..."
$EV_BIN background enable
$EV_BIN set networklock true

echo "connect to: ${EXPRESSVPN_CONNECT:-smart}"
$EV_BIN connect "${EXPRESSVPN_CONNECT:-smart}"


for i in {1..30}; do
    if out=$("$EV_BIN" status 2>/dev/null); then
        if echo "$out" | grep -q "Connected"; then
            echo "✓ ExpressVPN connected"
            break
        fi
    fi
    sleep 5
done

$EV_BIN status

echo "Container started..."
tail -f /dev/null
