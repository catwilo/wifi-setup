#!/usr/bin/env bats
# cleanup.bats -- networks_cleanup no debe borrar filas validas.
# Cubre el bug de IFS colapsando tabs: con psk vacio el parser viejo
# corria _i a autoconnect ("yes"/"no"), la busqueda de perfil NM fallaba
# y la fila se borraba como huerfana (perdida de datos).

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

    systemctl() { return 0; }  # NM activo
    export -f systemctl 2>/dev/null || true

    # shellcheck source=/dev/null
    source "$REPO/lib/networks_store.sh"
    # shellcheck source=/dev/null
    source "$REPO/lib/networks_show.sh"
}

@test "networks_cleanup: fila con psk vacio + perfil NM existe se conserva" {
    # Solo perfil NM, sin .psk en iwd (red abierta tipica).
    nm_con_exists() {
        [[ "$1" == "wifi-wlan0-RedAbierta" ]] && return 0
        return 1
    }
    export -f nm_con_exists 2>/dev/null || true

    _networks_store_init
    {
        printf '# header\n'
        printf 'RedAbierta\t\twlan0\tyes\t0\t0\n'
    } > "${NETWORKS_STORE}"

    run networks_cleanup
    [ "$status" -eq 0 ]

    run grep -c '^RedAbierta' "${NETWORKS_STORE}"
    [ "$output" = "1" ]
}

@test "networks_cleanup: fila con psk no vacio + perfil NM existe se conserva" {
    nm_con_exists() {
        [[ "$1" == "wifi-wlan0-RedConPsk" ]] && return 0
        return 1
    }
    export -f nm_con_exists 2>/dev/null || true

    _networks_store_init
    {
        printf '# header\n'
        printf 'RedConPsk\tsupersecreto\twlan0\tyes\t0\t0\n'
    } > "${NETWORKS_STORE}"

    run networks_cleanup
    [ "$status" -eq 0 ]

    run grep -c '^RedConPsk' "${NETWORKS_STORE}"
    [ "$output" = "1" ]
}
