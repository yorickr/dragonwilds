#!/usr/bin/env bats

load helper

setup() {
    export INSTALL_DIR="$BATS_TEST_TMPDIR/install"
    export OWNER_ID=1234567890
    export BACKUP_DIR="$BATS_TEST_TMPDIR/backups"
}

# The world as the server leaves it: one world's save plus the engine's own
# previous-save copy, and the rendered config directory.
seed_world() {
    mkdir -p "$INSTALL_DIR/RSDragonwilds/Saved/SaveGames" \
             "$INSTALL_DIR/RSDragonwilds/Saved/Config/LinuxServer"
    printf 'world-v1\n' > "$INSTALL_DIR/RSDragonwilds/Saved/SaveGames/World-1.sav"
    printf 'previous\n' > "$INSTALL_DIR/RSDragonwilds/Saved/SaveGames/World-1.sav.backup"
    printf 'OwnerId=1\n' > "$INSTALL_DIR/RSDragonwilds/Saved/Config/LinuxServer/DedicatedServer.ini"
}

# Age everything out of the quiet window.
age_fixtures() { find "$INSTALL_DIR/RSDragonwilds/Saved" -exec touch -d '-2 hours' {} +; }

snapshots() { find "$BACKUP_DIR" -maxdepth 1 -mindepth 1 -type d -name '20*' 2>/dev/null; }

@test "backup_once copies the world and the config" {
    seed_world
    export BACKUP_QUIET=0
    ep backup_once
    [ "$status" -eq 0 ]
    [ "$(snapshots | wc -l)" -eq 1 ]

    local snap
    snap="$(snapshots)"
    [ -f "$snap/SaveGames/World-1.sav" ]
    [ -f "$snap/SaveGames/World-1.sav.backup" ]
    [ -f "$snap/Config/LinuxServer/DedicatedServer.ini" ]
    run cat "$snap/SaveGames/World-1.sav"
    [ "$output" = "world-v1" ]
    run cat "$snap/SaveGames/World-1.sav.backup"
    [ "$output" = "previous" ]
}

@test "backup_once waits for the files to settle" {
    seed_world
    export BACKUP_QUIET=3600
    ep backup_once
    [ "$status" -eq 1 ]
    [ ! -d "$BACKUP_DIR" ]

    age_fixtures
    ep backup_once
    [ "$status" -eq 0 ]
    [ "$(snapshots | wc -l)" -eq 1 ]
}

@test "backup_once skips an unchanged world and reruns after a change" {
    seed_world
    age_fixtures
    export BACKUP_QUIET=0

    ep backup_once
    [ "$status" -eq 0 ]

    ep backup_once
    [ "$status" -eq 1 ]
    [ "$(snapshots | wc -l)" -eq 1 ]

    printf 'world-v2\n' >> "$INSTALL_DIR/RSDragonwilds/Saved/SaveGames/World-1.sav"
    ep backup_once
    [ "$status" -eq 0 ]
    [ "$(snapshots | wc -l)" -eq 2 ]
}

@test "backup_once does nothing without anything to back up" {
    export BACKUP_QUIET=0
    ep backup_once
    [ "$status" -eq 1 ]
    [ ! -d "$BACKUP_DIR" ]
}

@test "backup_prune keeps the newest snapshots and leaves foreign files alone" {
    local stamp
    for stamp in 2026-01-01_000000 2026-01-02_000000 2026-01-03_000000 \
                 2026-01-04_000000 2026-01-05_000000; do
        mkdir -p "$BACKUP_DIR/$stamp/SaveGames"
        printf 'world\n' > "$BACKUP_DIR/$stamp/SaveGames/World-1.sav"
    done
    mkdir -p "$BACKUP_DIR/SaveGames_2026-01-06_000000"
    printf 'sig\n' > "$BACKUP_DIR/.last_signature"

    export BACKUP_KEEP=2
    ep backup_prune
    [ "$status" -eq 0 ]

    [ ! -d "$BACKUP_DIR/2026-01-01_000000" ]
    [ ! -d "$BACKUP_DIR/2026-01-02_000000" ]
    [ ! -d "$BACKUP_DIR/2026-01-03_000000" ]
    [ -d "$BACKUP_DIR/2026-01-04_000000" ]
    [ -d "$BACKUP_DIR/2026-01-05_000000" ]
    [ -d "$BACKUP_DIR/SaveGames_2026-01-06_000000" ]
    [ -f "$BACKUP_DIR/.last_signature" ]
}
