#!/usr/bin/env bats
# show_list.bats -- networks_list y networks_show con psk vacio.
# Cubre el bug de IFS colapsando tabs: con psk vacio, la fila
# (ssid, "", iface, auto, prio, ts) se parseaba como
# (ssid, iface, auto, prio, ts, "") y la busqueda del perfil NM
# (wifi-iface-ssid) fallaba -> "NM: NO" incorrecto; y networks_show
# mostraba psk=iface.

load helpers

setup() {
    setup_env
    die()  { printf '[ERR] %s\n' "$*" >&2; exit 1; }
    info() { :; }
    ok()   { :; }
    warn() { :; }
    err()  { :; }
    export -f die info ok warn err 2>/dev/null || true

    export STATE_DIR="$BATS_TEST_TMPDIR/state"
    export IWD_DIR="$BATS_TEST_TMPDIR/iwd"
    mkdir -p "$STATE_DIR" "$IWD_DIR"

    nm_con_exists() {
        [[ "$1" == "wifi-wlan0-RedAbierta" ]] && return 0
        return 1
    }
    export -f nm_con_exists 2>/dev/null || true

    # shellcheck source=/dev/null
    source "$REPO/lib/networks_store.sh"
    # shellcheck source=/dev/null
    source "$REPO/lib/networks_show.sh"
}

@test "networks_list: psk vacio reporta NM correcto (no perdido por parser)" {
    _networks_store_init
    {
        printf '# header\n'
        printf 'RedAbierta\t\twlan0\tyes\t0\t0\n'
    } > "${NETWORKS_STORE}"

    run networks_list
    [ "$status" -eq 0 ]
    # El SSID debe aparecer con NM=si
    echo "$output" | grep -E 'RedAbierta.*si'
}

@test "networks_show: psk vacio no muestra iface como PSK" {
    _networks_store_init
    {
        printf '# header\n'
        printf 'RedAbierta\t\twlan0\tyes\t0\t0\n'
    } > "${NETWORKS_STORE}"

    run networks_show "RedAbierta"
    [ "$status" -eq 0 ]
    # La salida NO debe decir "psk: wlan0"
    ! echo "$output" | grep -qE 'psk[^a-zA-Z]*wlan0'
    # La salida NO debe decir "psk: yes"
    ! echo "$output" | grep -qE 'psk[^a-zA-Z]*yes'
}
