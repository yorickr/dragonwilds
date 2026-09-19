#!/usr/bin/env bats

load helper

setup() {
    export PLAYERS_URL="http://example.invalid/players"
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

stub_curl() {
    cat > "$BATS_TEST_TMPDIR/bin/curl" <<EOF
#!/usr/bin/env bash
printf '%s' '$1'
EOF
    chmod +x "$BATS_TEST_TMPDIR/bin/curl"
}

@test "parses a bare integer" {
    stub_curl '4'
    ep rest_players
    [ "$status" -eq 0 ]
    [ "$output" = "4" ]
}

@test "parses the first integer out of JSON" {
    stub_curl '{"players":7,"max":20}'
    ep rest_players
    [ "$output" = "7" ]
}

@test "returns nothing when the body has no integer" {
    stub_curl 'unavailable'
    ep rest_players
    [ "$output" = "" ]
}

@test "fails when curl is not installed" {
    ep 'PATH=/nonexistent; rest_players'
    [ "$status" -ne 0 ]
}
