#!/usr/bin/env bash
set -eu
shopt -s nocasematch

# Paths to ExpressVPN binaries
DAEMON="/opt/expressvpn/bin/expressvpn-daemon"
EV_BIN="/opt/expressvpn/bin/expressvpnctl"
DAEMON_PID=""
MONITOR_INTERVAL=${MONITOR_INTERVAL:-30}
DEBUG="${DEBUG:-false}"  # default to false when DEBUG is not defined
# How long to try reconnecting before failing the container (seconds)
RECONNECT_TIMEOUT=${RECONNECT_TIMEOUT:-240}

# Function: check daemon status
check_daemon_status() {
    if timeout 5s "$EV_BIN" status >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Function: check whether VPN reports connected
is_vpn_connected() {
    local out
    if out=$("$EV_BIN" status 2>/dev/null); then
        if echo "$out" | grep -q "Connected"; then
            return 0
        fi
    fi
    return 1
}

# Attempt to reconnect the VPN without restarting the daemon.
# Returns 0 on success, 1 on timeout, 2 if daemon became unresponsive.
attempt_reconnect() {
    local elapsed=0
    local interval=${MONITOR_INTERVAL:-30}
    local target="${EXPRESSVPN_CONNECT:-smart}"

    while [ "$elapsed" -lt "$RECONNECT_TIMEOUT" ]; do
        # If daemon stops responding while trying, signal caller to restart daemon
        if ! check_daemon_status; then
            echo "Daemon unresponsive during reconnect attempts"
            return 2
        fi

        if is_vpn_connected; then
            return 0
        fi

        echo "Attempting VPN connect to '$target' (elapsed ${elapsed}s)..."
        if "$EV_BIN" connect "$target" >/dev/null 2>&1; then
            # give status a moment to update
            sleep 2
            if is_vpn_connected; then
                echo "VPN connected after explicit connect"
                return 0
            fi
        fi

        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    return 1
}

# Function: wait for daemon to become ready
wait_for_daemon() {
    local timeout=30
    local counter=0

    echo "Waiting for ExpressVPN daemon to be ready..."

    while [ $counter -lt $timeout ]; do
        if check_daemon_status; then
            echo "✓ Daemon is ready after ${counter}s"
            return 0
        fi
        sleep 1
        ((counter++))
    done

    echo "✗ Timeout waiting for daemon to be ready"
    return 1
}

# Function: start the daemon
start_daemon() {
    echo "Starting ExpressVPN daemon..."
    # Ensure no leftover process is running
    pkill -f "expressvpn-daemon" || true
    sleep 2

    # Start the daemon
    if [[ "$DEBUG" == "true" ]]; then
        "$DAEMON" &
        DAEMON_PID=$!
    else
        "$DAEMON" >/dev/null 2>&1 &
        DAEMON_PID=$!
    fi
    echo "Daemon started with PID: $DAEMON_PID"

    if ! wait_for_daemon; then
        echo "Failed to start daemon properly"
        return 1
    fi
    return 0
}

# Function: check and restart the daemon if needed
restart_daemon_if_needed() {
    # Check if the process is still alive
    if [ -n "$DAEMON_PID" ] && ! kill -0 "$DAEMON_PID" 2>/dev/null; then
        echo "Daemon process died, restarting..."
        start_daemon
        return $?
    fi

    # Check if the daemon is responsive
    if ! check_daemon_status; then
        echo "Daemon not responding, restarting..."
        [ -n "$DAEMON_PID" ] && kill -9 "$DAEMON_PID" 2>/dev/null || true
        start_daemon
        return $?
    fi

    # If daemon is responsive but VPN is disconnected, try a direct connect first
    if ! is_vpn_connected; then
        echo "VPN is not connected. Attempting direct connect..."
        if "$EV_BIN" connect "${EXPRESSVPN_CONNECT:-smart}" >/dev/null 2>&1; then
            echo "Direct connect successful"
            return 0
        else
            echo "Direct connect failed, restarting daemon..."
            [ -n "$DAEMON_PID" ] && kill -9 "$DAEMON_PID" 2>/dev/null || true
            start_daemon
            return $?
        fi
    fi

    return 0
}

# Function: perform a vpn operation with retries
vpn_operation() {
    local operation="$1"
    shift  # remove the operation name, remaining are arguments
    local retries=3

    for i in $(seq 1 $retries); do
        if restart_daemon_if_needed; then
            # If there are args pass them all, otherwise just the operation
            if [ $# -gt 0 ]; then
                if "$EV_BIN" "$operation" "$@" >/dev/null 2>&1; then
                    echo "✓ $operation $*"
                    return 0
                fi
            else
                if "$EV_BIN" "$operation" >/dev/null 2>&1; then
                    echo "✓ $operation"
                    return 0
                fi
            fi
        fi

        if [ $i -lt $retries ]; then
            echo "Retrying $operation... ($i/$retries)"
            sleep 5
        fi
    done

    echo "⚠️ Failed: $operation $*"
    return 1
}

# Function: show status
show_status() {
    if check_daemon_status; then
        echo "=== ExpressVPN Status ==="
        "$EV_BIN" status 2>/dev/null || echo "Status command failed"
        echo "========================="
    else
        echo "Daemon not available for status check"
    fi
}

# 主函数
main() {
    # 1️⃣ Start the daemon
    echo "Initializing ExpressVPN..."
    if ! start_daemon; then
        echo "Error: Failed to start ExpressVPN daemon"
        exit 1
    fi
    # 2️⃣ Activate (activation code is required)
    if [ -z "${EXPRESSVPN_ACTIVATION_CODE:-}" ]; then
        echo "Error: EXPRESSVPN_ACTIVATION_CODE is required but not provided. Exiting."
        exit 1
    fi

    echo "Activating ExpressVPN with activation code file..."
    # create activation code file
    echo "$EXPRESSVPN_ACTIVATION_CODE" > /tmp/activationCodeFile
    # login using the file; fail if login fails
    if ! "$EV_BIN" login /tmp/activationCodeFile >/dev/null 2>&1; then
        echo "Error: ExpressVPN activation/login failed" >&2
        exit 1
    fi

    # 3️⃣ Basic configuration
    echo "Configuring ExpressVPN settings..."
    vpn_operation "background" "enable"
    vpn_operation "set" "networklock" "true"

    # 4️⃣ Connect VPN
    CONNECT_LOCATION="${EXPRESSVPN_CONNECT:-smart}"
    echo "Connecting to: $CONNECT_LOCATION"
    vpn_operation "connect" "$CONNECT_LOCATION"

    # 5️⃣ Show initial status
    show_status

    # 6️⃣ Start background monitor
    echo "Starting daemon monitor (checks every ${MONITOR_INTERVAL}s)..."
    (
        local disconnected_since=0
        local restart_failures=0
        local restart_failure_threshold=3
        while true; do
            # First, ensure daemon is alive and responsive. If not, restart it.
            if ! restart_daemon_if_needed; then
                restart_failures=$((restart_failures+1))
                echo "Warning: daemon could not be restarted (attempt ${restart_failures}/${restart_failure_threshold}); will retry after ${MONITOR_INTERVAL}s"
                if [ "$restart_failures" -ge "$restart_failure_threshold" ]; then
                    echo "Error: daemon restart failed ${restart_failures} times; exiting to allow orchestrator to restart the container"
                    pkill -f "expressvpn-daemon" 2>/dev/null || true
                    exit 1
                fi
                sleep $MONITOR_INTERVAL
                continue
            fi
            restart_failures=0

            # Print current status each monitor iteration
            show_status

            # If daemon is responsive but VPN reports disconnected, try reconnecting (without restarting daemon)
            if ! is_vpn_connected; then
                echo "VPN reports Disconnected — attempting reconnect sequence"
                # print status again before reconnect attempts
                show_status
                case $(attempt_reconnect; echo $?) in
                    0)
                        echo "Reconnect successful"
                        disconnected_since=0
                        ;;
                    2)
                        echo "Daemon became unresponsive during reconnect attempts; restarting daemon"
                        restart_daemon_if_needed
                        disconnected_since=0
                        ;;
                    *)
                        echo "Failed to reconnect within ${RECONNECT_TIMEOUT}s — restarting daemon to attempt recovery"
                        restart_daemon_if_needed
                        disconnected_since=0
                        ;;
                esac
            fi

            sleep $MONITOR_INTERVAL
        done
    ) &
    MONITOR_PID=$!

    # 7️⃣ Keep the container running
    echo "ExpressVPN is running. Container will stay active."
    echo "Press Ctrl+C to stop the container."

    # Setup signal handling for graceful shutdown
    trap "echo 'Shutting down...'; kill $MONITOR_PID 2>/dev/null; pkill -f 'expressvpn-daemon' 2>/dev/null; exit 0" SIGTERM SIGINT

    # Wait for the monitor process (this will run indefinitely)
    wait $MONITOR_PID
}

# Run the main function with all script arguments
main "$@"