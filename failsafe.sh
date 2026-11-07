#!/bin/bash
# LidNap fail-safe. Run every few seconds by a LaunchAgent
# (~/Library/LaunchAgents/com.wilberc.lidnap.failsafe.plist).
#
# While LidNap keeps the Mac awake it writes its pid to "$STATE/active" and
# touches "$STATE/heartbeat" regularly. If the app is no longer running, or the
# heartbeat is stale (the app hung), this script restores normal sleep with
# `pmset -a disablesleep 0` and clears the marker.
#
# Without a marker it does nothing, so a disablesleep value set manually
# outside the app is never touched.
set -u

STATE="${LIDNAP_STATE_DIR:-$HOME/Library/Application Support/LidNap}"
LOG="${LIDNAP_LOG:-$HOME/Library/Logs/LidNap.log}"
STALE_SECONDS="${LIDNAP_STALE_SECONDS:-60}"
MARKER="$STATE/active"
HEARTBEAT="$STATE/heartbeat"

log() {
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$LOG"
}

restore_sleep() {
    if [ -n "${LIDNAP_PMSET:-}" ]; then
        "$LIDNAP_PMSET" -a disablesleep 0
    else
        /usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0
    fi
}

[ -f "$MARKER" ] || exit 0

pid=$(tr -d '[:space:]' < "$MARKER")
reason=""

if ! [[ "$pid" =~ ^[0-9]+$ ]]; then
    reason="invalid marker"
else
    command=$(ps -p "$pid" -o comm= 2>/dev/null)
    if [ "$(basename "${command:-none}")" != "LidNap" ]; then
        reason="app not running"
    elif [ ! -f "$HEARTBEAT" ]; then
        reason="app unresponsive"
    else
        age=$(( $(date +%s) - $(stat -f %m "$HEARTBEAT") ))
        [ "$age" -gt "$STALE_SECONDS" ] && reason="app unresponsive"
    fi
fi

[ -z "$reason" ] && exit 0

if restore_sleep >/dev/null 2>&1; then
    rm -f "$MARKER" "$HEARTBEAT"
    log "fail-safe: $reason, restored sleep"
    exit 0
fi

log "fail-safe: could not restore sleep ($reason); will retry"
exit 1
