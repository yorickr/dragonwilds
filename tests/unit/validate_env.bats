#!/usr/bin/env bats

load helper

setup() {
    export INSTALL_DIR="$BATS_TEST_TMPDIR/install"
    export OWNER_ID=1234567890
}

@test "fails when OWNER_ID is unset" {
    unset OWNER_ID
    ep validate_env
    [ "$status" -eq 1 ]
    [[ "$output" == *"OWNER_ID is not set"* ]]
}

@test "fails when OWNER_ID is empty" {
    export OWNER_ID=""
    ep validate_env
    [ "$status" -eq 1 ]
    [[ "$output" == *"OWNER_ID is not set"* ]]
}

@test "accepts the defaults" {
    ep validate_env
    [ "$status" -eq 0 ]
}

@test "fails on a non-numeric SERVER_PORT" {
    export SERVER_PORT=abc
    ep validate_env
    [ "$status" -eq 1 ]
    [[ "$output" == *"SERVER_PORT must be a number"* ]]
}

@test "fails on an out-of-range SERVER_PORT" {
    export SERVER_PORT=70000
    ep validate_env
    [ "$status" -eq 1 ]
    [[ "$output" == *"SERVER_PORT must be between 1 and 65535"* ]]
}

@test "fails on a non-numeric AUTO_PAUSE_TIMEOUT" {
    export AUTO_PAUSE_TIMEOUT=soon
    ep validate_env
    [ "$status" -eq 1 ]
    [[ "$output" == *"AUTO_PAUSE_TIMEOUT must be a number"* ]]
}
