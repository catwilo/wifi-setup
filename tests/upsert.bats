#!/usr/bin/env bats
# upsert.bats -- _networks_store_upsert y _networks_store_delete.
# Funciones que escriben cada 'wifi add' y 'wifi passwd'. Sin estas
# garantias, la DB puede corromperse silenciosamente.

load helpers

setup() {
    setup_env
    info() { :; }
    warn() { :; }
    ok()   { :; }
    err()  { :; }
    export -f info warn ok err 2>/dev/null || true

    export IWD_DIR="$BATS_TEST_TMPDIR/iwd"
    export STATE_DIR="$BATS_TEST_TMPDIR/state"
    mkdir -p "$IWD_DIR" "$STATE_DIR"

    # shellcheck source=/dev/null
    source "$REPO/lib/networks.sh"
}

@test "upsert: inserta fila nueva cuando no existe" {
    _networks_store_upsert "RedA" "pskA" "wlan0" "yes" "0"

    run grep '^RedA' "${NETWORKS_STORE}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"pskA"* ]]
    [[ "$output" == *"wlan0"* ]]
}

@test "upsert: actualiza fila existente sin duplicar" {
    _networks_store_upsert "RedA" "psk-vieja" "wlan0" "yes" "0"
    _networks_store_upsert "RedA" "psk-nueva" "wlan0" "yes" "0"

    local count
    count="$(grep -c '^RedA.*wlan0' "${NETWORKS_STORE}")"
    [ "${count}" -eq 1 ]

    run grep '^RedA.*psk-nueva' "${NETWORKS_STORE}"
    [ "$status" -eq 0 ]
    run grep '^RedA.*psk-vieja' "${NETWORKS_STORE}"
    [ "$status" -ne 0 ]
}

@test "upsert: preserva otras ifaces del mismo SSID" {
    _networks_store_upsert "RedA" "psk" "wlan0" "yes" "0"
    _networks_store_upsert "RedA" "psk" "wlx1" "no" "0"

    local count
    count="$(grep -c '^RedA' "${NETWORKS_STORE}")"
    [ "${count}" -eq 2 ]

    run grep '^RedA.*wlan0' "${NETWORKS_STORE}"
    [ "$status" -eq 0 ]
    run grep '^RedA.*wlx1' "${NETWORKS_STORE}"
    [ "$status" -eq 0 ]
}

@test "upsert: idempotente (mismos args no duplican)" {
    _networks_store_upsert "RedA" "psk" "wlan0" "yes" "100"
    _networks_store_upsert "RedA" "psk" "wlan0" "yes" "100"

    local count
    count="$(grep -c '^RedA.*wlan0' "${NETWORKS_STORE}")"
    [ "${count}" -eq 1 ]
}

@test "upsert: preserva comentarios de cabecera" {
    _networks_store_init
    local before
    before="$(grep -c '^#' "${NETWORKS_STORE}")"

    _networks_store_upsert "RedA" "psk" "wlan0" "yes" "0"

    local after
    after="$(grep -c '^#' "${NETWORKS_STORE}")"
    [ "${before}" -eq "${after}" ]
}

@test "delete: elimina todas las filas del SSID" {
    _networks_store_upsert "RedA" "psk" "wlan0" "yes" "0"
    _networks_store_upsert "RedA" "psk" "wlx1" "no" "0"
    _networks_store_upsert "RedB" "pskB" "wlan0" "yes" "0"

    _networks_store_delete "RedA"

    run grep '^RedA' "${NETWORKS_STORE}"
    [ "$status" -ne 0 ]
    run grep '^RedB' "${NETWORKS_STORE}"
    [ "$status" -eq 0 ]
}

@test "delete: SSID inexistente es no-op" {
    _networks_store_upsert "RedA" "psk" "wlan0" "yes" "0"

    _networks_store_delete "NoExiste"

    run grep '^RedA' "${NETWORKS_STORE}"
    [ "$status" -eq 0 ]
}
