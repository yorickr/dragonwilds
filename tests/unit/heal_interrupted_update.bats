#!/usr/bin/env bats

load helper

setup() {
    export INSTALL_DIR="$BATS_TEST_TMPDIR/install"
    export APP_ID=4019830
    STEAMAPPS="$INSTALL_DIR/steamapps"
    MANIFEST="$STEAMAPPS/appmanifest_$APP_ID.acf"
    mkdir -p "$STEAMAPPS/downloading/$APP_ID" "$STEAMAPPS/temp/$APP_ID" "$INSTALL_DIR/appcache"
}

write_manifest() {
    printf '"AppState"\n{\n\t"appid"\t\t"%s"\n\t"StateFlags"\t\t"%s"\n}\n' "$APP_ID" "$1" > "$MANIFEST"
}

@test "does nothing when there is no manifest" {
    ep heal_interrupted_update
    [ "$status" -eq 0 ]
    [ -d "$INSTALL_DIR/appcache" ]
}

@test "keeps a fully installed manifest" {
    write_manifest 4
    ep heal_interrupted_update
    [ "$status" -eq 0 ]
    [ -f "$MANIFEST" ]
    [ -d "$INSTALL_DIR/appcache" ]
}

@test "clears SteamCMD state after an interrupted update" {
    write_manifest 6
    ep heal_interrupted_update
    [ "$status" -eq 0 ]
    [[ "$output" == *"StateFlags=6"* ]]
    [ ! -e "$MANIFEST" ]
    [ ! -e "$STEAMAPPS/downloading/$APP_ID" ]
    [ ! -e "$STEAMAPPS/temp/$APP_ID" ]
    [ ! -e "$INSTALL_DIR/appcache" ]
}

@test "leaves saves and game files alone when healing" {
    write_manifest 6
    mkdir -p "$INSTALL_DIR/RSDragonwilds/Saved/SaveGames"
    touch "$INSTALL_DIR/RSDragonwilds/Saved/SaveGames/World.sav"
    ep heal_interrupted_update
    [ -f "$INSTALL_DIR/RSDragonwilds/Saved/SaveGames/World.sav" ]
}
