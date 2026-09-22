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
lives on the volume, so back that up. The image can also snapshot the world and
its config itself on an interval — see [Backups](#backups).

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
4. **Back up.** With `BACKUP_ENABLED=true`, a loop snapshots the world and the
   config on an interval and prunes the oldest snapshots. Off by default.
5. **Launch.** `AUTO_PAUSE=false` → plain `exec` (or, with backups enabled,
   `setsid` + `wait`, so the snapshot loop outlives the server). Otherwise the
   server starts under `setsid` and the auto-pause watcher runs in the
   foreground.

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

## Backups

With `BACKUP_ENABLED=true` the entrypoint snapshots the world and its config on
an interval, prunes the oldest snapshots, and leaves the game running whatever
happens to the backup loop.

A snapshot is a plain directory `$BACKUP_DIR/<UTC timestamp>/` holding two
subtrees:

- `SaveGames/` — everything in `RSDragonwilds/Saved/SaveGames/`: one `.sav` per
  world plus the engine's own `<name>.sav.backup` (the previous 5-minute
  autosave). The whole directory is copied, never a filename parsed out of
  `DEFAULT_WORLD_NAME`, so older worlds' files survive too.
- `Config/LinuxServer/` — `DedicatedServer.ini` (which carries `ServerGuid` and
  the `KnownPlayerList=` privilege/ban lines), `Engine.ini` and
  `GameUserSettings.ini`.

Everything else under `/home/steam/rs_server` is excluded, because it is either
regenerated or re-downloaded:

| Excluded | Why |
|---|---|
| `Saved/SpudCache/` | Streamed-level cell cache, rewritten continuously during play. |
| `Saved/Logs/` | The engine rotates its own. |
| `Saved/PersistentDownloadDir/EOSCache` | EOS platform cache. |
| `Engine/`, `RSDragonwilds/{Binaries,Content,Plugins}`, `steamapps/`, `appcache/`, `depotcache/`, `userdata/`, `*.vdf`, `Manifest_*` | SteamCMD install state; `UPDATE_ON_BOOT=true` re-fetches it. |

- **Schedule.** One snapshot at container start (for free, that is the
  "after update" backup) and then every `BACKUP_INTERVAL` seconds. Nothing is
  snapshotted if no backed-up file changed since the last one, so a quiet world
  costs nothing — the signature of the last snapshot lives in
  `$BACKUP_DIR/.last_signature`; `rm` that file to force one.
- **Quiet window.** A snapshot is skipped while the newest file is younger than
  `BACKUP_QUIET` seconds, so a copy can't catch the engine mid-rename of a save.
  The default 30s is far shorter than the 5-minute autosave cadence; `0` disables
  the guard.
- **Retention.** The newest `BACKUP_KEEP` snapshots are kept and older ones
  deleted. Only directories named like our own snapshots are candidates —
  anything else in `BACKUP_DIR` is left alone.
- **Log.** `[backup] snapshot …`, `[backup] pruning …` and errors are logged;
  identical-world skips are silent.

Snapshots are written to `$BACKUP_DIR`, inside the data volume by default, so
they share its fate — point `BACKUP_DIR` at a separate mount for a real second
copy. A snapshot is as fresh as the previous autosave (up to 5 minutes old), and
`DedicatedServer.ini` inside it contains `WorldPassword`/`AdminPassword` in
plaintext, so protect it like the volume itself.

To restore: stop the container, copy `SaveGames/*.sav` back to
`RSDragonwilds/Saved/SaveGames/`, copy `Config/LinuxServer/DedicatedServer.ini`
back to where it came from (or copy just its `ServerGuid=` and
`KnownPlayerList=` lines into the current one to keep the identity and player
list), and start the container.

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
| `BACKUP_ENABLED` | `false` | Snapshot the world and config on an interval. |
| `BACKUP_INTERVAL` | `86400` | Seconds between snapshots. |
| `BACKUP_KEEP` | `7` | Snapshots retained; the oldest are pruned. |
| `BACKUP_DIR` | `$INSTALL_DIR/backup` | Where snapshots are written. Point it at a separate mount to survive the data disk. |
| `BACKUP_QUIET` | `30` | Skip while the newest file is younger than this (seconds). `0` disables the guard. |

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
shutdown signal order, the `OWNER_ID` guard, and opt-in interval backups
(snapshot contents, change detection, retention). See
[CONTRIBUTING.md](CONTRIBUTING.md).

## Versioning

Pushing a `vX.Y.Z` git tag runs the full CI suite and, if it passes, builds and
pushes `ghcr.io/yorickr/dragonwilds` with semver and `latest` tags.

## License

[MIT](LICENSE).
