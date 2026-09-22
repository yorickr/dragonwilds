#!/usr/bin/env bash
# End-to-end tests against a real container running a stub server: config
# rendering, idle pause, UDP wake, shutdown signal order, the OWNER_ID guard and
# opt-in interval backups (snapshot contents, change detection, retention).
# No game download -- the stub stands in for RSDragonwildsServer.sh.
#
# Helpers below are called indirectly (traps, wait_for "$@").
# shellcheck disable=SC2329
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGE="${IMAGE:-dragonwilds:test}"
TEST_IMAGE="${TEST_IMAGE:-dragonwilds:test-harness}"
OWNER_ID_VALUE=1234567890
HOST_PORT="${HOST_PORT:-$(( 30000 + RANDOM % 20000 ))}"

CONTAINER=""
WORKDIR=""
FAILURES=0

cleanup() {
    if [ -n "$CONTAINER" ]; then
        docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    fi
    if [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ]; then
        remove_workdir "$WORKDIR"
    fi
}
trap cleanup EXIT

say()  { echo "[test] $*"; }
pass() { echo "[test] PASS: $*"; }
fail() { echo "[test] FAIL: $*" >&2; FAILURES=$(( FAILURES + 1 )); }

# wait_for <timeout_s> <description> <command...>
wait_for() {
    local timeout="$1" desc="$2"
    shift 2
    local deadline=$(( $(date +%s) + timeout ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if "$@"; then
            return 0
        fi
        sleep 0.25
    done
    fail "timed out after ${timeout}s waiting for $desc"
    return 1
}

proc_state() {
    local pid="$1"
    docker exec "$CONTAINER" awk '{ sub(/.*\) /, ""); print $1 }' "/proc/$pid/stat" 2>/dev/null || true
}

state_is() {
    local pid="$1" want="$2" got
    got="$(proc_state "$pid")"
    [[ "$got" == "$want" ]]
}

state_in() {
    local pid="$1" want="$2" got
    got="$(proc_state "$pid")"
    [[ -n "$got" && "$want" == *"$got"* ]]
}

file_exists() {
    [ -f "$1" ]
}

contains() { grep -q "$2" "$1"; }

snapshot_dirs() {
    find "$WORKDIR/data/backup" -maxdepth 1 -mindepth 1 -type d -name '20*' 2>/dev/null || true
}
snapshot_count() { snapshot_dirs | wc -l; }
snapshot_count_is() { [ "$(snapshot_count)" = "$1" ]; }
newest_snapshot() { snapshot_dirs | sort | tail -n1; }

log_has() {
    docker logs "$CONTAINER" 2>&1 | grep -q "$1"
}

# The container writes into the volume as uid 1000; if the tests run as another
# uid, only a container can clean those files up again.
remove_workdir() {
    rm -rf "$1" 2>/dev/null && return 0
    docker run --rm -v "$1:/w" --entrypoint /bin/sh "$TEST_IMAGE" -c 'rm -rf /w/..?* /w/.[!.]* /w/*' >/dev/null 2>&1 || true
    rm -rf "$1" 2>/dev/null || true
}

new_workdir() {
    WORKDIR="$(mktemp -d)"
    mkdir -p "$WORKDIR/data"
    cp "$REPO_ROOT/tests/integration/stub/RSDragonwildsServer.sh" "$WORKDIR/data/"
    chmod +x "$WORKDIR/data/RSDragonwildsServer.sh"
    # The container runs as uid 1000; make the volume writable regardless of the
    # uid running these tests (CI runners are not always 1000).
    chmod -R 0777 "$WORKDIR"
}

say "building $IMAGE"
docker build -q -t "$IMAGE" "$REPO_ROOT" >/dev/null
say "building $TEST_IMAGE (adds python3 for the stub)"
docker build -q -t "$TEST_IMAGE" \
    --build-arg "BASE_IMAGE=$IMAGE" \
    -f "$REPO_ROOT/tests/integration/Dockerfile.test" "$REPO_ROOT/tests/integration" >/dev/null

###############################################################################
say "1-5: config rendering, idle pause, UDP wake, shutdown, backups stay off by default"
###############################################################################
new_workdir
CONTAINER="dragonwilds-test-$$"
docker run -d --name "$CONTAINER" \
    -p "$HOST_PORT:7777/udp" \
    -v "$WORKDIR/data:/home/steam/rs_server" \
    -e OWNER_ID="$OWNER_ID_VALUE" \
    -e UPDATE_ON_BOOT=false \
    -e AUTO_PAUSE_TIMEOUT=2 \
    -e AUTO_PAUSE_POLL=1 \
    "$TEST_IMAGE" >/dev/null

CONFIG="$WORKDIR/data/RSDragonwilds/Saved/Config/LinuxServer/DedicatedServer.ini"
if wait_for 30 "DedicatedServer.ini to be written" file_exists "$CONFIG"; then
    cat > "$WORKDIR/expected.ini" <<EOF
;METADATA=(Diff=true, UseCommands=true)
[/Script/Dominion.DedicatedServerSettings]
OwnerId=$OWNER_ID_VALUE
ServerName=Dragonwilds
DefaultWorldName=World
WorldPassword=
AdminPassword=
PlatformPolicy=Crossplay
bAllowSendingCrashDumps=False
EOF
    if diff -u "$WORKDIR/expected.ini" "$CONFIG"; then
        pass "1: DedicatedServer.ini matches the expected content"
    else
        fail "1: DedicatedServer.ini does not match the expected content"
    fi
fi

if wait_for 30 "the stub to record its pid" file_exists "$WORKDIR/data/stub.pid"; then
    STUB_PID="$(cat "$WORKDIR/data/stub.pid")"
    say "stub pid inside the container: $STUB_PID"

    if wait_for 30 "the watcher to pause the stub" state_is "$STUB_PID" T; then
        pass "2: the watcher SIGSTOPped the server after the idle timeout"
    fi

    if log_has '\[autopause\] pausing'; then
        pass "2b: the watcher logged the pause"
    else
        fail "2b: no [autopause] pausing line in the container logs"
    fi

    say "sending a UDP datagram to 127.0.0.1:$HOST_PORT"
    for _ in 1 2 3; do
        exec 3<>"/dev/udp/127.0.0.1/$HOST_PORT" && printf 'wake' >&3 && exec 3>&-
        sleep 0.2
    done

    if wait_for 30 "the watcher to resume the stub" state_in "$STUB_PID" "SR"; then
        pass "3: an inbound datagram resumed the server"
    fi

    # Shutdown matters most from the PAUSED state: a STOPped process can only
    # handle TERM if CONT was delivered first.
    if wait_for 30 "the watcher to pause the stub again" state_is "$STUB_PID" T; then
        say "stub is paused; stopping the container"
    fi

    START="$(date +%s)"
    docker stop -t 30 "$CONTAINER" >/dev/null
    ELAPSED=$(( $(date +%s) - START ))
    EXIT_CODE="$(docker inspect -f '{{.State.ExitCode}}' "$CONTAINER")"
    SIGNALS="$(tr '\n' ' ' < "$WORKDIR/data/signals.log" 2>/dev/null || true)"

    # A paused process that ran its TERM handler and exited cleanly proves the
    # entrypoint sent CONT before TERM; had it sent TERM alone, the stub would
    # still be STOPped and Docker would have SIGKILLed it at the grace period.
    if [[ "$SIGNALS" == *"TERM EXITED"* ]]; then
        pass "4: the paused stub handled TERM and exited cleanly (CONT preceded it)"
    else
        fail "4: expected the stub to handle TERM and exit, signal log was: '$SIGNALS'"
    fi
    if log_has 'stopping: CONT then TERM to pgid'; then
        pass "4b: the entrypoint logged CONT-then-TERM"
    else
        fail "4b: no CONT-then-TERM line in the container logs"
    fi
    if [ "$EXIT_CODE" = "0" ]; then
        pass "4c: the container exited 0"
    else
        fail "4c: the container exited $EXIT_CODE, expected 0"
    fi
    # The on_term poll is bounded at 28s; a clean stop is near-instant, so a slow
    # shutdown here means TERM was never handled.
    if [ "$ELAPSED" -lt 15 ]; then
        pass "4d: shutdown took ${ELAPSED}s, well inside the 30s grace period"
    else
        fail "4d: shutdown took ${ELAPSED}s -- the stub did not handle TERM promptly"
    fi
fi

if [ ! -d "$WORKDIR/data/backup" ]; then
    pass "5: no backup directory without BACKUP_ENABLED"
else
    fail "5: data/backup was created without BACKUP_ENABLED"
fi

docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
CONTAINER=""
remove_workdir "$WORKDIR"
WORKDIR=""

###############################################################################
say "6: missing OWNER_ID"
###############################################################################
new_workdir
CONTAINER="dragonwilds-test-owner-$$"
OWNER_OUT=""
OWNER_STATUS=0
OWNER_OUT="$(docker run --name "$CONTAINER" \
    -v "$WORKDIR/data:/home/steam/rs_server" \
    -e UPDATE_ON_BOOT=false \
    "$TEST_IMAGE" 2>&1)" || OWNER_STATUS=$?

if [ "$OWNER_STATUS" = "1" ]; then
    pass "6: the container exited 1 without OWNER_ID"
else
    fail "6: the container exited $OWNER_STATUS without OWNER_ID, expected 1"
fi
if [[ "$OWNER_OUT" == *"OWNER_ID is not set"* ]]; then
    pass "6b: it printed the OWNER_ID error"
else
    fail "6b: expected an OWNER_ID error, got: $OWNER_OUT"
fi

docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
CONTAINER=""

###############################################################################
say "7-9: opt-in interval backups, change detection"
###############################################################################
new_workdir
CONTAINER="dragonwilds-test-backup-$$"
docker run -d --name "$CONTAINER" \
    -v "$WORKDIR/data:/home/steam/rs_server" \
    -e OWNER_ID="$OWNER_ID_VALUE" \
    -e UPDATE_ON_BOOT=false \
    -e AUTO_PAUSE_TIMEOUT=2 \
    -e AUTO_PAUSE_POLL=1 \
    -e BACKUP_ENABLED=true \
    -e BACKUP_INTERVAL=1 \
    -e BACKUP_QUIET=0 \
    "$TEST_IMAGE" >/dev/null

FIRST_SNAPSHOT=""
if wait_for 60 "a snapshot to appear" snapshot_count_is 1; then
    pass "7: BACKUP_ENABLED=true wrote a snapshot"
    FIRST_SNAPSHOT="$(newest_snapshot)"
    if [ -f "$FIRST_SNAPSHOT/SaveGames/World-1.sav" ] \
        && contains "$FIRST_SNAPSHOT/SaveGames/World-1.sav" world-v1; then
        pass "7b: the snapshot holds the world save"
    else
        fail "7b: no World-1.sav containing world-v1 under $FIRST_SNAPSHOT"
    fi
    if [ -f "$FIRST_SNAPSHOT/Config/LinuxServer/DedicatedServer.ini" ]; then
        pass "7c: the snapshot holds the rendered config"
    else
        fail "7c: no Config/LinuxServer/DedicatedServer.ini under $FIRST_SNAPSHOT"
    fi
    if log_has '\[backup\] snapshot'; then
        pass "7d: the loop logged the snapshot"
    else
        fail "7d: no [backup] snapshot line in the container logs"
    fi
fi

# Several 1s ticks with nothing writing to the world: the signature is
# unchanged, so no second snapshot may appear.
sleep 4
if snapshot_count_is 1; then
    pass "8: an unchanged world is not snapshotted again"
else
    fail "8: $(snapshot_count) snapshots after 4 idle ticks, expected 1"
fi

docker exec "$CONTAINER" sh -c \
    'printf "world-v2\n" >> /home/steam/rs_server/RSDragonwilds/Saved/SaveGames/World-1.sav'
if wait_for 60 "a changed world to be snapshotted" snapshot_count_is 2; then
    NEW_SNAPSHOT="$(newest_snapshot)"
    if [ "$NEW_SNAPSHOT" != "$FIRST_SNAPSHOT" ] \
        && contains "$NEW_SNAPSHOT/SaveGames/World-1.sav" world-v2; then
        pass "9: a changed world is snapshotted into a new directory"
    else
        fail "9: newest snapshot $NEW_SNAPSHOT is not a new copy of world-v2"
    fi
fi

docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
CONTAINER=""
remove_workdir "$WORKDIR"
WORKDIR=""

###############################################################################
say "10-11: retention"
###############################################################################
new_workdir
for stamp in 2026-01-01_000000 2026-01-02_000000 2026-01-03_000000 \
             2026-01-04_000000 2026-01-05_000000; do
    mkdir -p "$WORKDIR/data/backup/$stamp/SaveGames"
    printf 'world\n' > "$WORKDIR/data/backup/$stamp/SaveGames/World-1.sav"
done
# Not our layout: a snapshot from the old image, which retention must not touch.
mkdir -p "$WORKDIR/data/backup/SaveGames_2026-01-06_000000"
chmod -R 0777 "$WORKDIR"

CONTAINER="dragonwilds-test-retention-$$"
docker run -d --name "$CONTAINER" \
    -v "$WORKDIR/data:/home/steam/rs_server" \
    -e OWNER_ID="$OWNER_ID_VALUE" \
    -e UPDATE_ON_BOOT=false \
    -e BACKUP_ENABLED=true \
    -e BACKUP_INTERVAL=1 \
    -e BACKUP_QUIET=0 \
    -e BACKUP_KEEP=3 \
    "$TEST_IMAGE" >/dev/null

if wait_for 60 "retention to prune the five seeded snapshots down to three" snapshot_count_is 3; then
    pass "10: BACKUP_KEEP=3 kept three of six snapshots"
fi
if [ -d "$WORKDIR/data/backup/2026-01-04_000000" ] \
    && [ -d "$WORKDIR/data/backup/2026-01-05_000000" ]; then
    pass "10b: the two oldest survivors are kept"
else
    fail "10b: 2026-01-04/2026-01-05 were pruned"
fi
if [ ! -d "$WORKDIR/data/backup/2026-01-01_000000" ] \
    && [ ! -d "$WORKDIR/data/backup/2026-01-02_000000" ] \
    && [ ! -d "$WORKDIR/data/backup/2026-01-03_000000" ]; then
    pass "10c: the three oldest snapshots were pruned"
else
    fail "10c: 2026-01-01/02/03 survived pruning"
fi
if [ -d "$WORKDIR/data/backup/SaveGames_2026-01-06_000000" ]; then
    pass "11: a foreign directory is left alone"
else
    fail "11: the SaveGames_2026-01-06_000000 directory was deleted"
fi

docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
CONTAINER=""
remove_workdir "$WORKDIR"
WORKDIR=""

###############################################################################
if [ "$FAILURES" -eq 0 ]; then
    say "all integration tests passed"
else
    say "$FAILURES integration assertion(s) failed"
fi
exit "$FAILURES"
