#!/usr/bin/env bats

load helper

setup() {
    export PROC_NET_UDP="$FIXTURES/proc_net_udp"
    export PROC_NET_UDP6="$FIXTURES/proc_net_udp6"
    # 7777
    export PORT_HEX=1E61
}

@test "sums the matching rows across udp and udp6" {
    ep udp_rx_queue
    [ "$status" -eq 0 ]
    # 0x140 (320) from udp + 0x80 (128) from udp6
    [ "$output" = "448" ]
}

@test "matches only the requested port" {
    export PORT_HEX=0035
    ep udp_rx_queue
    # only the 0x0035 row (0x200 = 512); the 1E61 rows are not counted
    [ "$output" = "512" ]
}

@test "reads a single matching row on udp6 only" {
    export PROC_NET_UDP=/dev/null
    ep udp_rx_queue
    [ "$output" = "128" ]
}

@test "is zero when nothing is queued" {
    export PORT_HEX=FFFF
    ep udp_rx_queue
    [ "$output" = "0" ]
}
