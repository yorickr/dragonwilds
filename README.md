# Dragonwilds

[![CI](../../actions/workflows/ci.yml/badge.svg)](../../actions/workflows/ci.yml)

Docker image for a dedicated *RuneScape: Dragonwilds* server. The image is just
Debian + SteamCMD; the game (Steam app **4019830**, free, anonymous login) is
installed at runtime into `/home/steam/rs_server`, not baked in. Runs as user
`steam`, UID 1000.

Unofficial and not affiliated with or endorsed by Jagex.

## Running it

```sh
docker run -d --name dragonwilds \
    -p 7777:7777/udp \
    -v ./data:/home/steam/rs_server \
    -e OWNER_ID=your-player-id \
    --stop-timeout 30 \
    ghcr.io/yorickr/dragonwilds:latest
```

Or with compose — see [`compose.example.yaml`](compose.example.yaml):

```yaml
services:
  dragonwilds:
    image: ghcr.io/yorickr/dragonwilds:latest
    restart: unless-stopped
    ports:
      - "7777:7777/udp"
    volumes:
      - ./data:/home/steam/rs_server
    environment:
      OWNER_ID: "your-player-id"
    stop_grace_period: 30s
```

`OWNER_ID` is mandatory — in-game, Settings → "My Player Id". Everything under
`/home/steam/rs_server` (the game install, the world, and the rendered config)
lives on the volume, so back that up.

### Ports

`EXPOSE 7777/udp` in the image is metadata only. The game port is set by
`SERVER_PORT` and what actually matters is the published mapping. If you change
`SERVER_PORT`, publish that port instead: `-e SERVER_PORT=7800 -p 7800:7800/udp`.

### Shutdown

Give the container at least 30 seconds to stop (`--stop-timeout 30` /
`stop_grace_period: 30s`). The entrypoint's shutdown poll is bounded at 28s.

## entrypoint.sh

1. **Validate.** Aborts if `OWNER_ID` is empty (the server silently refuses to
   start without it) or if `SERVER_PORT`/the numeric `AUTO_PAUSE_*` vars are not
   numbers in range.
2. **Install/update** via SteamCMD if `UPDATE_ON_BOOT=true` or the server isn't
   installed. `+app_info_update 1 +app_info_print` runs first — without it
   `+app_update` intermittently fails with "Missing configuration" from a stale
   appinfo cache.
3. **Render** `RSDragonwilds/Saved/Config/LinuxServer/DedicatedServer.ini` from
   the env vars below. `ServerGuid` (the identity clients already know) and
   `KnownPlayerList=` lines (privilege/ban list) are carried over from the
   existing file rather than regenerated.
4. **Launch.** `AUTO_PAUSE=false` → plain `exec`. Otherwise the server starts
   under `setsid` and the auto-pause watcher runs in the foreground.

## Auto-pause

Idle, the server still burns CPU and keeps simulating world time. The watcher
SIGSTOPs the server's process group after an idle timeout and SIGCONTs it when
someone connects. RAM stays allocated, CPU goes to zero, in-game time stops.

- **Idle detection.** No RCON/REST/console exists, so the player count is tailed
  from `Saved/Logs/RSDragonwilds.log` (`AUTO_PAUSE_JOIN_RE` / `_LEAVE_RE`).
  Clearing `AUTO_PAUSE_JOIN_RE` falls back to interface `rx_packets` rate;
  `AUTO_PAUSE_PLAYERS_URL` overrides both. With no non-loopback interface (e.g.
  `network_mode: none`) the watcher warns and falls back to `lo`, where
  traffic-only mode always reads idle.
- **Wake.** A stopped process can't drain its UDP socket, so packets queue in the
  kernel. The watcher reads `/proc/net/udp{,6}` for the game port's row and
  resumes when `rx_queue` exceeds `AUTO_PAUSE_WAKE_BYTES`. Port-scoped.
- **Shutdown.** SIGCONT before SIGTERM — a stopped process never handles TERM —
  then polls `/proc` until the process is gone (`wait` in a bash trap returns
  immediately, which would let the container die mid-save). The game exits
  instantly on TERM without a shutdown save, so a restart loses up to one
  5-minute autosave interval regardless.
- **Manual override.** `.autopause` in the install dir: `resume` = stay awake,
  `pause` = pause now, absent = automatic.

Watcher output is prefixed `[autopause]`. If the server exits on its own the
watcher exits with its status.

## Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `OWNER_ID` | — | **Mandatory.** Player ID of the owner. In-game: Settings → "My Player Id". |
| `SERVER_NAME` | `Dragonwilds` | Name in the server browser. |
| `DEFAULT_WORLD_NAME` | `World` | World to load/create. **Max 16 characters.** Changing it starts a different world. |
| `PLATFORM_POLICY` | `Crossplay` | Which platforms may join. |
| `WORLD_PASSWORD` | unset | Join password. Unset = open. |
| `ADMIN_PASSWORD` | unset | Password for in-game admin commands. |
| `UPDATE_ON_BOOT` | `true` | Re-run SteamCMD every start. `false` pins the current build; still runs if not installed. |
| `SERVER_PORT` | `7777` | Game port inside the container. |
| `AUTO_PAUSE` | `true` | Freeze the server while nobody is connected. |
| `AUTO_PAUSE_TIMEOUT` | `900` | Seconds of idle before pausing. |
| `AUTO_PAUSE_POLL` | `10` | Watcher tick, in seconds. Also worst-case wake latency. |
| `AUTO_PAUSE_IDLE_PPS` | `3` | Traffic-only mode: packets/sec below this is idle. |
| `AUTO_PAUSE_WAKE_BYTES` | `0` | Resume when the port's UDP `rx_queue` exceeds this. |
| `AUTO_PAUSE_JOIN_RE` | `LogNet: Join succeeded:` | Log regex counting a player in. Empty = traffic-only mode. |
| `AUTO_PAUSE_LEAVE_RE` | `LogNet: UNetConnection::Close:` | Log regex counting a player out. |
| `AUTO_PAUSE_PLAYERS_URL` | unset | Optional URL returning a player count; first integer wins. |

`ServerGuid` is deliberately not an env var — the server generates it on first
run and the entrypoint preserves it. Crash dump sending is always disabled.

`WORLD_PASSWORD` and `ADMIN_PASSWORD` are written in plaintext into
`DedicatedServer.ini` on the data volume. Protect that volume accordingly.

## Testing

Tooling is pinned in `mise.toml`.

```sh
mise install
mise run lint              # shellcheck + hadolint
mise run test:unit         # bats, sources entrypoint.sh, no Docker needed
mise run test:integration  # builds the image, runs container tests against a stub server
```

The integration suite never downloads the game: it bind-mounts a stub
`RSDragonwildsServer.sh` and asserts config rendering, idle pause, UDP wake,
shutdown signal order, and the `OWNER_ID` guard. See
[CONTRIBUTING.md](CONTRIBUTING.md).

## Versioning

Pushing a `vX.Y.Z` git tag runs the full CI suite and, if it passes, builds and
pushes `ghcr.io/yorickr/dragonwilds` with semver and `latest` tags.

## License

[MIT](LICENSE).
