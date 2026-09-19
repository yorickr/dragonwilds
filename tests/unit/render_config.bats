#!/usr/bin/env bats

load helper

setup() {
    export INSTALL_DIR="$BATS_TEST_TMPDIR/install"
    CONFIG="$INSTALL_DIR/RSDragonwilds/Saved/Config/LinuxServer/DedicatedServer.ini"
    export OWNER_ID=1234567890
}

@test "writes the expected INI for defaults" {
    ep render_config
    [ "$status" -eq 0 ]
    cat > "$BATS_TEST_TMPDIR/expected" <<'EOF'
;METADATA=(Diff=true, UseCommands=true)
[/Script/Dominion.DedicatedServerSettings]
OwnerId=1234567890
ServerName=Dragonwilds
DefaultWorldName=World
WorldPassword=
AdminPassword=
PlatformPolicy=Crossplay
bAllowSendingCrashDumps=False
EOF
    diff -u "$BATS_TEST_TMPDIR/expected" "$CONFIG"
}

@test "omits ServerGuid on first run" {
    ep render_config
    run grep -c '^ServerGuid=' "$CONFIG"
    [ "$status" -ne 0 ]
}

@test "carries ServerGuid and every KnownPlayerList line over" {
    mkdir -p "$(dirname "$CONFIG")"
    cat > "$CONFIG" <<'EOF'
;METADATA=(Diff=true, UseCommands=true)
[/Script/Dominion.DedicatedServerSettings]
KnownPlayerList=(PlayerId="aaa",Privilege=Admin)
KnownPlayerList=(PlayerId="bbb",Privilege=Banned)
OwnerId=1234567890
ServerGuid=DEADBEEFDEADBEEFDEADBEEFDEADBEEF
ServerName=Old
EOF
    ep render_config
    [ "$status" -eq 0 ]
    cat > "$BATS_TEST_TMPDIR/expected" <<'EOF'
;METADATA=(Diff=true, UseCommands=true)
[/Script/Dominion.DedicatedServerSettings]
KnownPlayerList=(PlayerId="aaa",Privilege=Admin)
KnownPlayerList=(PlayerId="bbb",Privilege=Banned)
OwnerId=1234567890
ServerGuid=DEADBEEFDEADBEEFDEADBEEFDEADBEEF
ServerName=Dragonwilds
DefaultWorldName=World
WorldPassword=
AdminPassword=
PlatformPolicy=Crossplay
bAllowSendingCrashDumps=False
EOF
    diff -u "$BATS_TEST_TMPDIR/expected" "$CONFIG"
}

@test "passes through the settings env vars" {
    export SERVER_NAME="My Server" DEFAULT_WORLD_NAME=Gielinor \
        WORLD_PASSWORD=hunter2 ADMIN_PASSWORD=swordfish PLATFORM_POLICY=PCOnly
    ep render_config
    [ "$status" -eq 0 ]
    grep -qx 'ServerName=My Server' "$CONFIG"
    grep -qx 'DefaultWorldName=Gielinor' "$CONFIG"
    grep -qx 'WorldPassword=hunter2' "$CONFIG"
    grep -qx 'AdminPassword=swordfish' "$CONFIG"
    grep -qx 'PlatformPolicy=PCOnly' "$CONFIG"
}
