#!/usr/bin/env bats
# networks_store_update_field.bats -- _networks_store_update_field
# Actualiza UN campo (psk/autoconnect/priority) en las filas que matchean.
# Es la primitiva que reemplazo las 3 copias inline de cirugia TSV que
# vivian en bin/wifi (password set, priority set, autoconnect set) antes
# del refactor.

load helpers

setup() {
    setup_env
    die()  { printf '[ERR] %s\n' "$*" >&2; return 1; }
    info() { :; }
    ok()   { :; }
    warn() { :; }
    export -f die info ok warn 2>/dev/null || true

    export STATE_DIR="$BATS_TEST_TMPDIR/state"
    mkdir -p "$STATE_DIR"

    # shellcheck source=/dev/null
    source "$REPO/lib/networks_store.sh"
}

@test "update_field: psk actualiza todas las filas del SSID (iface='*')" {
    _networks_store_upsert "RedA" "psk-old" "wlan0" "yes" "0"
    _networks_store_upsert "RedA" "psk-old" "wlx1" "no" "10"

    run _networks_store_update_field "RedA" "*" psk "psk-new"
    [ "$status" -eq 0 ]

    run grep -c '^RedA.*psk-new' "${NETWORKS_STORE}"
    [ "$output" = "2" ]
}

@test "update_field: autoconnect solo toca la iface indicada" {
    _networks_store_upsert "RedA" "psk" "wlan0" "yes" "0"
    _networks_store_upsert "RedA" "psk" "wlx1" "yes" "0"

    run _networks_store_update_field "RedA" "wlan0" autoconnect "no"
    [ "$status" -eq 0 ]

    run grep '^RedA.*wlan0.*no' "${NETWORKS_STORE}"
    [ "$status" -eq 0 ]

    run grep '^RedA.*wlx1.*yes' "${NETWORKS_STORE}"
    [ "$status" -eq 0 ]
}

@test "update_field: priority actualiza todas las filas del SSID" {
    _networks_store_upsert "RedA" "psk" "wlan0" "yes" "0"
    _networks_store_upsert "RedA" "psk" "wlx1" "no" "0"

    run _networks_store_update_field "RedA" "*" priority "42"
    [ "$status" -eq 0 ]

    run grep -c $'\t42\t' "${NETWORKS_STORE}"
    [ "$output" = "2" ]
}

@test "update_field: rc=1 cuando SSID no existe" {
    _networks_store_init
    run _networks_store_update_field "NoSuch" "*" psk "x"
    [ "$status" -eq 1 ]
}

@test "update_field: rc=1 cuando (ssid,iface) no matchea" {
    _networks_store_upsert "RedA" "psk" "wlan0" "yes" "0"
    run _networks_store_update_field "RedA" "wlx9" autoconnect "no"
    [ "$status" -eq 1 ]
}

@test "update_field: preserva comentarios de cabecera" {
    _networks_store_upsert "RedA" "psk" "wlan0" "yes" "0"
    local before after
    before="$(grep -c '^#' "${NETWORKS_STORE}")"

    _networks_store_update_field "RedA" "*" psk "psk-new"

    after="$(grep -c '^#' "${NETWORKS_STORE}")"
    [ "$before" = "$after" ]
}
