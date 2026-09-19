#!/usr/bin/env bats

load helper

setup() {
    export JOIN_RE='LogNet: Join succeeded:'
}

@test "increments on a join line" {
    ep 'apply_log_line "[2026.01.01-00.00.00] LogNet: Join succeeded: Player1" 0'
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
}

@test "decrements on a leave line" {
    ep 'apply_log_line "[2026.01.01-00.00.00] LogNet: UNetConnection::Close: ..." 3'
    [ "$status" -eq 0 ]
    [ "$output" = "2" ]
}

@test "clamps at zero" {
    ep 'apply_log_line "[2026.01.01-00.00.00] LogNet: UNetConnection::Close: ..." 0'
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

@test "honours a custom join regex" {
    export JOIN_RE='PlayerJoined'
    ep 'apply_log_line "xx PlayerJoined yy" 5'
    [ "$output" = "6" ]
}
