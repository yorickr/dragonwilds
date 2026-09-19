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

    if [ "${AUTO_PAUSE:-true}" != "true" ]; then
        exec "$INSTALL_DIR/RSDragonwildsServer.sh" -log -Port="$SERVER_PORT"
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
