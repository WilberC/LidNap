#!/bin/bash
# Tests for failsafe.sh. Uses a fake pmset and a temporary state directory,
# so it never touches the real power settings.
set -u
cd "$(dirname "$0")/.."

PASSED=0
FAILED=0
TMP=$(mktemp -d)
FAKE_PID=""
cleanup() {
    if [ -n "$FAKE_PID" ]; then
        kill "$FAKE_PID" 2>/dev/null
        wait "$FAKE_PID" 2>/dev/null
    fi
    rm -rf "$TMP"
}
trap cleanup EXIT

check() {
    if eval "$1"; then
        PASSED=$((PASSED + 1))
    else
        FAILED=$((FAILED + 1))
        echo "FAIL $2"
    fi
}

# Fake pmset: records its arguments; exits with $FAKE_PMSET_STATUS.
cat > "$TMP/pmset" <<'EOF'
#!/bin/bash
echo "$*" >> "$FAKE_PMSET_CALLS"
exit "${FAKE_PMSET_STATUS:-0}"
EOF
chmod +x "$TMP/pmset"

# A live process whose executable is named LidAwake. Copying /bin/sleep would
# break its code signature, so build a tiny binary instead.
printf '#include <unistd.h>\nint main(void) { sleep(600); return 0; }\n' > "$TMP/sleeper.c"
cc -o "$TMP/LidAwake" "$TMP/sleeper.c"
"$TMP/LidAwake" &
FAKE_PID=$!

# A pid that is certainly not running.
/usr/bin/true &
DEAD_PID=$!
wait "$DEAD_PID"

reset_state() {
    rm -rf "$TMP/state" "$TMP/calls" "$TMP/log"
    mkdir -p "$TMP/state"
}

run_failsafe() {
    LIDAWAKE_STATE_DIR="$TMP/state" \
    LIDAWAKE_LOG="$TMP/log" \
    LIDAWAKE_PMSET="$TMP/pmset" \
    LIDAWAKE_STALE_SECONDS=60 \
    FAKE_PMSET_CALLS="$TMP/calls" \
    FAKE_PMSET_STATUS="${1:-0}" \
    bash failsafe.sh
    STATUS=$?
}

restored() { [ "$(cat "$TMP/calls" 2>/dev/null)" = "-a disablesleep 0" ]; }
untouched() { [ ! -e "$TMP/calls" ]; }

# 1. No marker: the app never enabled lid-awake (or the user set it manually).
reset_state
run_failsafe
check 'untouched && [ $STATUS -eq 0 ]' "no marker leaves pmset untouched"

# 2. App alive with a fresh heartbeat: nothing to do.
reset_state
echo "$FAKE_PID" > "$TMP/state/active"
touch "$TMP/state/heartbeat"
run_failsafe
check 'untouched && [ -f "$TMP/state/active" ] && [ $STATUS -eq 0 ]' "live app with fresh heartbeat is left alone"

# 3. App died: restore sleep, clear the marker, log the reason.
reset_state
echo "$DEAD_PID" > "$TMP/state/active"
touch "$TMP/state/heartbeat"
run_failsafe
check 'restored && [ ! -e "$TMP/state/active" ] && [ ! -e "$TMP/state/heartbeat" ] && [ $STATUS -eq 0 ]' "dead app restores sleep and clears state"
check 'grep -q "fail-safe: app not running, restored sleep" "$TMP/log"' "dead app is logged"

# 4. Pid reused by another program: treated as not running.
reset_state
echo "$$" > "$TMP/state/active"
touch "$TMP/state/heartbeat"
run_failsafe
check 'restored && [ ! -e "$TMP/state/active" ]' "pid reused by another process restores sleep"

# 5. App hung: heartbeat older than the limit.
reset_state
echo "$FAKE_PID" > "$TMP/state/active"
touch -t "$(date -v-5M +%Y%m%d%H%M.%S)" "$TMP/state/heartbeat"
run_failsafe
check 'restored && [ ! -e "$TMP/state/active" ]' "stale heartbeat restores sleep"
check 'grep -q "fail-safe: app unresponsive, restored sleep" "$TMP/log"' "stale heartbeat is logged"

# 6. Missing heartbeat counts as unresponsive.
reset_state
echo "$FAKE_PID" > "$TMP/state/active"
run_failsafe
check 'restored' "missing heartbeat restores sleep"

# 7. Corrupt marker: restore to be safe.
reset_state
echo "not-a-pid" > "$TMP/state/active"
run_failsafe
check 'restored && [ ! -e "$TMP/state/active" ]' "invalid marker restores sleep"

# 8. pmset fails: keep the marker so the next run retries, and report failure.
reset_state
echo "$DEAD_PID" > "$TMP/state/active"
run_failsafe 1
check '[ -f "$TMP/state/active" ] && [ $STATUS -ne 0 ]' "failed restore keeps marker and exits non-zero"
check 'grep -q "fail-safe: could not restore sleep" "$TMP/log"' "failed restore is logged"

echo "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
