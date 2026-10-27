#!/usr/bin/env bats
# cli.bats -- contrato observable minimo del CLI.

load helpers

setup() { setup_env; }

@test "bin/wifi comando desconocido: exit != 0 con hint" {
    run bash "$WIFI" bogus-cmd
    [ "$status" -ne 0 ]
    [[ "$output" == *"comando desconocido"* ]]
    [[ "$output" == *"wifi help"* ]]
}
