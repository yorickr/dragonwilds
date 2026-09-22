#!/usr/bin/env bash
set -euo pipefail

# Paths are injectable so the unit tests can point them at fixtures.
INSTALL_DIR="${INSTALL_DIR:-/home/steam/rs_server}"
STEAMCMD="${STEAMCMD:-/opt/steamcmd/steamcmd.sh}"
PROC_NET_UDP="${PROC_NET_UDP:-/proc/net/udp}"
PROC_NET_UDP6="${PROC_NET_UDP6:-/proc/net/udp6}"
SYS_CLASS_NET="${SYS_CLASS_NET:-/sys/class/net}"
APP_ID="${APP_ID:-4019830}"

CONFIG_DIR="$INSTALL_DIR/RSDragonwilds/Saved/Config/LinuxServer"
CONFIG_FILE="$CONFIG_DIR/DedicatedServer.ini"
LOG_FILE="${LOG_FILE:-$INSTALL_DIR/RSDragonwilds/Saved/Logs/RSDragonwilds.log}"
OVERRIDE_FILE="$INSTALL_DIR/.autopause"
SAVEGAMES_DIR="$INSTALL_DIR/RSDragonwilds/Saved/SaveGames"
BACKUP_DIR="${BACKUP_DIR:-$INSTALL_DIR/backup}"

die() {
    echo "[entrypoint] ERROR: $1" >&2
    exit 1
}

# A non-numeric or out-of-range value here makes printf '%04X' abort the script
# under set -e with no useful message, so check everything up front.
require_int() {
    local name="$1" value="$2" min="$3" max="$4"
    [[ "$value" =~ ^[0-9]+$ ]] || die "$name must be a number, got '$value'."
    if [ "$value" -lt "$min" ] || [ "$value" -gt "$max" ]; then
        die "$name must be between $min and $max, got '$value'."
    fi
}

validate_env() {
    if [ -z "${OWNER_ID:-}" ]; then
        echo "[entrypoint] ERROR: OWNER_ID is not set. The server will not start without it." >&2
        echo "[entrypoint] Set OWNER_ID in the container environment (in-game: Settings -> My Player Id)." >&2
        exit 1
    fi
    require_int SERVER_PORT "${SERVER_PORT:-7777}" 1 65535
    require_int AUTO_PAUSE_POLL "${AUTO_PAUSE_POLL:-10}" 1 86400
    require_int AUTO_PAUSE_TIMEOUT "${AUTO_PAUSE_TIMEOUT:-900}" 1 604800
    require_int AUTO_PAUSE_IDLE_PPS "${AUTO_PAUSE_IDLE_PPS:-3}" 0 1000000
    require_int AUTO_PAUSE_WAKE_BYTES "${AUTO_PAUSE_WAKE_BYTES:-0}" 0 1000000000
    require_int BACKUP_INTERVAL "${BACKUP_INTERVAL:-86400}" 1 31536000
    require_int BACKUP_KEEP "${BACKUP_KEEP:-7}" 1 1000
    require_int BACKUP_QUIET "${BACKUP_QUIET:-30}" 0 86400
}

install_or_update() {
    if [ "${UPDATE_ON_BOOT:-true}" = "true" ] || [ ! -f "$INSTALL_DIR/RSDragonwildsServer.sh" ]; then
        echo "[entrypoint] Installing/updating app $APP_ID via SteamCMD..."
        # +app_info_update/+app_info_print first: without it +app_update on this app
        # intermittently fails with "Missing configuration" from a stale appinfo cache.
        "$STEAMCMD" +force_install_dir "$INSTALL_DIR" +login anonymous \
            +app_info_update 1 +app_info_print "$APP_ID" \
            +app_update "$APP_ID" validate +quit
        chmod +x "$INSTALL_DIR/RSDragonwildsServer.sh"
    fi
}

render_config() {
    mkdir -p "$CONFIG_DIR"

    # Carry over state the server owns rather than us: the server identity clients
    # already know, and the player privilege/ban list.
    local existing_guid="" existing_players=""
    if [ -f "$CONFIG_FILE" ]; then
        existing_guid="$(sed -n 's/^ServerGuid=//p' "$CONFIG_FILE" | head -n1)"
        existing_players="$(grep '^KnownPlayerList=' "$CONFIG_FILE" || true)"
    fi

    {
        echo ";METADATA=(Diff=true, UseCommands=true)"
        echo "[/Script/Dominion.DedicatedServerSettings]"
        [ -n "$existing_players" ] && echo "$existing_players"
        echo "OwnerId=${OWNER_ID}"
        [ -n "$existing_guid" ] && echo "ServerGuid=${existing_guid}"
        echo "ServerName=${SERVER_NAME:-Dragonwilds}"
        echo "DefaultWorldName=${DEFAULT_WORLD_NAME:-World}"
        echo "WorldPassword=${WORLD_PASSWORD:-}"
        echo "AdminPassword=${ADMIN_PASSWORD:-}"
        echo "PlatformPolicy=${PLATFORM_POLICY:-Crossplay}"
        echo "bAllowSendingCrashDumps=False"
    } > "$CONFIG_FILE"

    echo "[entrypoint] Wrote $CONFIG_FILE"
}

# Epoch seconds of the most recently modified file we back up; 0 if there is
# nothing to back up yet.
backup_source_mtime() {
    local m
    m="$({ find "$SAVEGAMES_DIR" "$CONFIG_DIR" -type f -printf '%T@\n' 2>/dev/null || true; } \
        | sort -rn | head -n1 | cut -d. -f1)"
    echo "${m:-0}"
}

# Fingerprint of a SaveGames/Config pair: names, sizes and mtimes relative to
# each root, so the same fingerprint can be taken from the live tree or from a
# snapshot of it. Changes whenever any file we back up is rewritten, so an
# identical signature means a snapshot would only duplicate the previous one.
tree_signature() {
    local savegames="$1" config="$2"
    {
        find "$savegames" -type f -printf 'SaveGames/%P %s %T@\n' 2>/dev/null || true
        find "$config" -type f -printf 'Config/LinuxServer/%P %s %T@\n' 2>/dev/null || true
    } | sort | md5sum | cut -d' ' -f1
}

# Keep the newest $BACKUP_KEEP snapshots. Only our own <date>_<time> directories
# are candidates: anything else in $BACKUP_DIR (snapshots from the old image
# layout, a user's own files) is left alone.
backup_prune() {
    local keep="${BACKUP_KEEP:-7}" path
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        echo "[backup] pruning $path"
        rm -rf "$path"
    done < <(find "$BACKUP_DIR" -maxdepth 1 -mindepth 1 -type d \
                -name '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9]*' \
             | sort -r | tail -n +$(( keep + 1 )))
}

# One snapshot: copy the world and its config into $BACKUP_DIR/<UTC stamp>/.
# 0 = written, 1 = nothing to do yet (skips are silent, the loop logs once).
backup_once() {
    local quiet="${BACKUP_QUIET:-30}" dir="$BACKUP_DIR" sig newest now
    sig="$(tree_signature "$SAVEGAMES_DIR" "$CONFIG_DIR")"
    if [ -f "$dir/.last_signature" ] && [ "$sig" = "$(<"$dir/.last_signature")" ]; then
        return 1
    fi
    newest="$(backup_source_mtime)"
    [ "$newest" -gt 0 ] || return 1
    now="$(date +%s)"
    # The server renames the previous save aside and writes a fresh .sav; copying
    # while that is in flight can catch a torn file, so wait for the files to
    # settle. The quiet window is far shorter than the 5-minute autosave cadence.
    [ $(( now - newest )) -ge "$quiet" ] || return 1

    local stamp tmp final n=1
    stamp="$(date -u +%Y-%m-%d_%H%M%S)"
    tmp="$dir/.tmp-$stamp"
    final="$dir/$stamp"
    while [ -e "$final" ]; do final="$dir/${stamp}_$n"; n=$(( n + 1 )); done

    # Copy aside, then rename into place: a half-written snapshot must never look
    # like a restorable one.
    rm -rf "$tmp"
    mkdir -p "$tmp/SaveGames" "$tmp/Config/LinuxServer" || {
        echo "[backup] ERROR: cannot create $tmp" >&2
        return 1
    }
    if ! cp -a "$SAVEGAMES_DIR/." "$tmp/SaveGames/" \
        || ! cp -a "$CONFIG_DIR/." "$tmp/Config/LinuxServer/"; then
        echo "[backup] ERROR: copy into $tmp failed" >&2
        rm -rf "$tmp"
        return 1
    fi
    # Fingerprint the copy, never the source: a save written between the checks
    # above and this copy would otherwise leave a signature behind that no
    # snapshot matches, and the loop would write a duplicate on its next tick.
    local copy_sig
    copy_sig="$(tree_signature "$tmp/SaveGames" "$tmp/Config/LinuxServer")"
    mv "$tmp" "$final" || {
        echo "[backup] ERROR: cannot finalise $final" >&2
        rm -rf "$tmp"
        return 1
    }
    printf '%s\n' "$copy_sig" > "$dir/.last_signature"
    echo "[backup] snapshot $final"
    backup_prune
    return 0
}

# Snapshot once at start, then every $BACKUP_INTERVAL seconds. A broken backup
# must never take the game down with it, so failures log and retry.
backup_loop() {
    local interval="${BACKUP_INTERVAL:-86400}" tick last=0 warned=0 now
    tick="$interval"
    [ "$tick" -gt 60 ] && tick=60
    if ! mkdir -p "$BACKUP_DIR"; then
        echo "[backup] ERROR: cannot create $BACKUP_DIR; backups disabled" >&2
        return 0
    fi
    echo "[backup] every ${interval}s: $SAVEGAMES_DIR + $CONFIG_DIR -> $BACKUP_DIR (keep ${BACKUP_KEEP:-7}, quiet ${BACKUP_QUIET:-30}s)"
    while :; do
        now="$(date +%s)"
        if [ "$last" -eq 0 ] || [ $(( now - last )) -ge "$interval" ]; then
            if backup_once; then
                last="$now"
                warned=0
            elif [ "$warned" -eq 0 ]; then
                echo "[backup] nothing to snapshot yet (world unchanged, or a save is in flight)"
                warned=1
            fi
        fi
        nap "$tick"
    done
}

pick_iface() {
    local iface="" path base
    for path in "$SYS_CLASS_NET"/*; do
        base="$(basename "$path")"
        if [ "$base" != lo ] && [ "$base" != '*' ]; then
            iface="$base"
            break
        fi
    done
    if [ -z "$iface" ]; then
        # network_mode: none, or a lo-only netns. rx_packets on lo never moves for
        # inbound game traffic, so traffic-only idle detection is useless here.
        echo "[autopause] WARNING: no non-loopback interface under $SYS_CLASS_NET; falling back to lo." >&2
        echo "[autopause] WARNING: traffic-only idle detection (empty AUTO_PAUSE_JOIN_RE) will always read idle." >&2
        iface=lo
    fi
    echo "$iface"
}

rx_packets() {
    cat "$SYS_CLASS_NET/$IFACE/statistics/rx_packets" 2>/dev/null || echo 0
}

# Bytes queued on the game port's UDP socket(s). A STOPped server drains
# nothing, so this is what an inbound join attempt looks like while paused.
udp_rx_queue() {
    local total=0 hex
    while read -r hex; do
        [ -n "$hex" ] || continue
        total=$(( total + 16#$hex ))
    done < <(awk -v ph="$PORT_HEX" 'FNR>1 { split($2,a,":"); if (a[2]==ph) { split($5,q,":"); print q[2] } }' \
            "$PROC_NET_UDP" "$PROC_NET_UDP6" 2>/dev/null)
    echo "$total"
}

rest_players() {
    command -v curl >/dev/null 2>&1 || return 1
    curl -sf --max-time 3 "$PLAYERS_URL" 2>/dev/null | grep -o '[0-9]\+' | head -n1
}

# Pure: given a matched log line and the current count, echo the new count.
apply_log_line() {
    local line="$1" players="$2"
    if printf '%s' "$line" | grep -qE "$JOIN_RE"; then
        players=$(( players + 1 ))
    else
        players=$(( players - 1 ))
        if [ "$players" -lt 0 ]; then players=0; fi
    fi
    echo "$players"
}

nap() {
    sleep "$1" &
    wait $! 2>/dev/null || true
}

# A STOPped process never handles SIGTERM, so CONT has to come first or the
# world is never flushed inside stop_grace_period.
on_term() {
    trap - TERM INT
    echo "[autopause] stopping: CONT then TERM to pgid $PGID"
    kill -CONT -"$PGID" 2>/dev/null || true
    kill -TERM -"$PGID" 2>/dev/null || true
    # `wait` in a trap returns immediately here, which would let the container
    # die mid-save; poll /proc instead, bounded well inside stop_grace_period.
    local state_ch
    for _ in $(seq 1 112); do
        state_ch="$(awk '{ sub(/.*\) /, ""); print $1 }' "/proc/$SERVER_PID/stat" 2>/dev/null || true)"
        case "$state_ch" in ""|Z) break ;; esac
        sleep 0.25
    done
    echo "[autopause] server stopped"
    exit 0
}

start_server() {
    setsid "$INSTALL_DIR/RSDragonwildsServer.sh" -log -Port="$SERVER_PORT" &
    SERVER_PID=$!
    sleep 1
    PGID="$(awk '{ sub(/.*\) /, ""); print $3 }' "/proc/$SERVER_PID/stat" 2>/dev/null || true)"
    [ -n "$PGID" ] || PGID="$SERVER_PID"
    trap on_term TERM INT
}

watch_loop() {
    if [ -n "$JOIN_RE" ]; then
        mkdir -p "$(dirname "$LOG_FILE")"
        exec 3< <(tail -F -n0 "$LOG_FILE" 2>/dev/null | grep --line-buffered -E "$JOIN_RE|$LEAVE_RE")
    fi

    local players=0 state=running idle_since=0 last_rx last_t
    local now rx dt pps override idle wake queue status line
    last_rx="$(rx_packets)"
    last_t="$(date +%s)"

    echo "[autopause] watching pid=$SERVER_PID pgid=$PGID iface=$IFACE port=$SERVER_PORT ($PORT_HEX) timeout=${TIMEOUT}s poll=${POLL}s"

    while :; do
        nap "$POLL"

        if ! kill -0 "$SERVER_PID" 2>/dev/null; then
            status=0
            wait "$SERVER_PID" || status=$?
            echo "[autopause] server exited with status $status"
            exit "$status"
        fi

        if [ -n "$JOIN_RE" ]; then
            while IFS= read -r -t 0.05 -u 3 line; do
                players="$(apply_log_line "$line" "$players")"
            done
        fi

        if [ -n "$PLAYERS_URL" ]; then
            local rest
            rest="$(rest_players || true)"
            if [ -n "$rest" ]; then players="$rest"; fi
        fi

        now="$(date +%s)"
        rx="$(rx_packets)"
        dt=$(( now - last_t ))
        if [ "$dt" -lt 1 ]; then dt=1; fi
        pps=$(( (rx - last_rx) / dt ))
        last_rx="$rx"
        last_t="$now"

        override=""
        if [ -f "$OVERRIDE_FILE" ]; then
            override="$(tr -d '[:space:]' < "$OVERRIDE_FILE" 2>/dev/null || true)"
        fi

        if [ "$state" = running ]; then
            if [ "$override" = pause ]; then
                idle=yes
                idle_since=$(( now - TIMEOUT ))
            elif [ "$override" = resume ]; then
                idle=no
            elif [ -n "$JOIN_RE" ] || [ -n "$PLAYERS_URL" ]; then
                if [ "$players" -eq 0 ]; then idle=yes; else idle=no; fi
            elif [ "$pps" -lt "$IDLE_PPS" ]; then
                idle=yes
            else
                idle=no
            fi

            if [ "$idle" = no ]; then
                idle_since=0
            else
                if [ "$idle_since" -eq 0 ]; then idle_since="$now"; fi
                if [ $(( now - idle_since )) -ge "$TIMEOUT" ]; then
                    echo "[autopause] pausing (players=$players pps=$pps)"
                    kill -STOP -"$PGID" 2>/dev/null || true
                    state=paused
                    idle_since=0
                fi
            fi
        else
            wake=no
            queue=override
            if [ "$override" = resume ]; then
                wake=yes
            elif [ "$override" != pause ]; then
                queue="$(udp_rx_queue)"
                if [ "$queue" -gt "$WAKE_BYTES" ]; then wake=yes; fi
            fi

            if [ "$wake" = yes ]; then
                echo "[autopause] resuming (rx_queue=${queue:-override})"
                kill -CONT -"$PGID" 2>/dev/null || true
                state=running
                idle_since=0
                last_rx="$(rx_packets)"
                last_t="$(date +%s)"
            fi
        fi
    done
}

main() {
    validate_env
    install_or_update
    render_config
    cd "$INSTALL_DIR"

    SERVER_PORT="${SERVER_PORT:-7777}"

    local backups=no
    if [ "${BACKUP_ENABLED:-false}" = "true" ]; then
        backup_loop &
        backups=yes
    fi

    if [ "${AUTO_PAUSE:-true}" != "true" ]; then
        if [ "$backups" = no ]; then
            exec "$INSTALL_DIR/RSDragonwildsServer.sh" -log -Port="$SERVER_PORT"
        fi
        # The snapshot loop outlives the server, so with backups on this path
        # supervises the server instead of exec'ing it (PID 1 stays this shell,
        # which already forwards CONT-then-TERM via on_term).
        start_server
        local status=0
        wait "$SERVER_PID" || status=$?
        exit "$status"
    fi

    POLL="${AUTO_PAUSE_POLL:-10}"
    TIMEOUT="${AUTO_PAUSE_TIMEOUT:-900}"
    IDLE_PPS="${AUTO_PAUSE_IDLE_PPS:-3}"
    WAKE_BYTES="${AUTO_PAUSE_WAKE_BYTES:-0}"
    JOIN_RE="${AUTO_PAUSE_JOIN_RE-LogNet: Join succeeded:}"
    LEAVE_RE="${AUTO_PAUSE_LEAVE_RE-LogNet: UNetConnection::Close:}"
    PLAYERS_URL="${AUTO_PAUSE_PLAYERS_URL:-}"
    PORT_HEX="$(printf '%04X' "$SERVER_PORT")"
    IFACE="$(pick_iface)"

    start_server
    watch_loop
}

# Sourcing this file (the bats unit tests do) defines the functions without
# running the server.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
