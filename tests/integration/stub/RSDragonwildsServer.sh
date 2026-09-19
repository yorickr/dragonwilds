#!/usr/bin/env bash
# Stand-in for the real dedicated server: binds the game's UDP port, records the
# signals it receives, and writes log lines in the shape the watcher greps for.
set -uo pipefail

DIR="${INSTALL_DIR:-/home/steam/rs_server}"
SIGLOG="$DIR/signals.log"
LOG="$DIR/RSDragonwilds/Saved/Logs/RSDragonwilds.log"

PORT=7777
for arg in "$@"; do
    case "$arg" in -Port=*) PORT="${arg#-Port=}" ;; esac
done

mkdir -p "$(dirname "$LOG")"
touch "$LOG" "$SIGLOG"
echo "$$" > "$DIR/stub.pid"
echo "LogInit: stub server starting on port $PORT" >> "$LOG"

# Drains the socket while running so rx_queue only grows once the process group
# is STOPped -- which is exactly the signal the watcher wakes on.
python3 -u -c '
import socket, sys
s = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
s.bind(("::", int(sys.argv[1])))
while True:
    s.recvfrom(4096)
' "$PORT" &
SOCK_PID=$!

RUNNING=1
# shellcheck disable=SC2064  # SIGLOG is fixed at trap time on purpose
trap "echo CONT >> '$SIGLOG'" CONT
trap 'echo TERM >> "$SIGLOG"; kill "$SOCK_PID" 2>/dev/null; RUNNING=0' TERM

echo "LogInit: stub server ready" >> "$LOG"
while [ "$RUNNING" = 1 ]; do
    sleep 0.2 &
    wait $! 2>/dev/null
done

echo "LogExit: stub server exiting" >> "$LOG"
exit 0
