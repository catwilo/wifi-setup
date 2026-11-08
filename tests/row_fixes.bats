#!/usr/bin/env bats
# row_fixes.bats -- sitios afectados por el bug de IFS colapsando tabs.
# _networks_pull_nm (old_auto/old_prio y ssid_iface_*) y
# _radio_db_set_autoconnect indexan/escriben por iface. Con psk vacio el
# parser viejo corria los campos y esas claves quedaban mal.

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
    mkdir -p "$STATE_DIR"

    radio_ifaces() { printf 'wlan0\n'; }
    export -f radio_ifaces 2>/dev/null || true

    # shellcheck source=/dev/null
    source "$REPO/lib/networks_store.sh"
    # shellcheck source=/dev/null
    source "$REPO/lib/radio_roles.sh"
}

@test "_radio_db_set_autoconnect: psk vacio no corrompe la fila" {
    _networks_store_init
    {
        printf '# header\n'
        printf 'RedAbierta\t\twlan0\tyes\t0\t0\n'
    } > "${NETWORKS_STORE}"

    _radio_db_set_autoconnect "RedAbierta" "wlan0" "no"

    run grep '^RedAbierta' "${NETWORKS_STORE}"
    [ "$status" -eq 0 ]
    # psk debe seguir vacio (tab-tab), iface=wlan0, auto=no
    [ "$output" = "$(printf 'RedAbierta\t\twlan0\tno\t0\t')$(echo "$output" | awk -F'\t' '{print $6}')" ]
}

@test "_radio_db_set_autoconnect: psk no vacio preserva el resto" {
    _networks_store_init
    {
        printf '# header\n'
        printf 'RedConPsk\tsupersecreto\twlan0\tyes\t5\t0\n'
    } > "${NETWORKS_STORE}"

    _radio_db_set_autoconnect "RedConPsk" "wlan0" "no"

    run grep '^RedConPsk' "${NETWORKS_STORE}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"supersecreto"* ]]
    [[ "$output" == *$'\tno\t'* ]]
    [[ "$output" == *$'\t5\t'* ]]
}

@test "_radio_db_set_autoconnect: no-op si (ssid,iface) no matchea" {
    _networks_store_init
    {
        printf '# header\n'
        printf 'RedA\tpsk\twlan0\tyes\t0\t0\n'
    } > "${NETWORKS_STORE}"
    cp "${NETWORKS_STORE}" "${NETWORKS_STORE}.orig"

    _radio_db_set_autoconnect "RedA" "wlx1" "no"

    run diff -q "${NETWORKS_STORE}" "${NETWORKS_STORE}.orig"
    [ "$status" -eq 0 ]
}
