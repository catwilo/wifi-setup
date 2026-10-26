#!/usr/bin/env bats
# import_iwd.bats -- importacion de redes desde el store de iwd a la DB.
# Solo lectura sobre iwd; escribe en el store TSV.

load helpers

setup() {
    setup_env
    # Stubs de las funciones de common.sh + radio que el modulo necesita.
    ok()      { printf '  [OK] %s\n'   "$*" >&2; }
    warn()    { printf '  [WARN] %s\n' "$*" >&2; }
    info()    { printf '  [i] %s\n'    "$*" >&2; }
    die()     { printf '  [ERR] %s\n'  "$*" >&2; return 1; }
    section() { :; }
    export -f ok warn info die section 2>/dev/null || true

    # Sin NM: solo probamos la parte de import (TSV + iwd store).
    nm_con_exists() { return 1; }
    nm_con_get()    { printf ''; }
    nm_con_set_autoconnect() { :; }
    nm_con_set_priority()    { :; }
    radio_ifaces()  { printf 'wlan0\n'; }
    radio_is_iface() { [[ "$1" == "wlan0" ]]; }
    export -f nm_con_exists nm_con_get nm_con_set_autoconnect nm_con_set_priority radio_ifaces radio_is_iface 2>/dev/null || true

    export IWD_DIR="$BATS_TEST_TMPDIR/iwd"
    export IWD_IFACES_CMD="printf 'wlan0\\n'"
    mkdir -p "$IWD_DIR"

    # STATE_DIR del modulo apunta a BASE_DIR (usar env override o tmp).
    export STATE_DIR="$BATS_TEST_TMPDIR/state"
    mkdir -p "$STATE_DIR"

    # shellcheck source=/dev/null
    source "$REPO/lib/networks.sh"
}

@test "networks_pull_iwd: iwd vacio no agrega filas" {
    run networks_pull_iwd
    [ "$status" -eq 0 ]
    [[ "$output" == *"no tiene redes nuevas"* ]]
}

@test "networks_pull_iwd: agrega fila con la PSK del .psk" {
    printf '[Security]\nPassphrase=super-secreta-123\n' > "$IWD_DIR/MiRed.psk"

    run networks_pull_iwd
    [ "$status" -eq 0 ]
    [[ "$output" == *"1 fila"* ]]

    run grep -P '^MiRed\tsuper-secreta-123\twlan0\tyes\t0\t' "$NETWORKS_STORE"
    [ "$status" -eq 0 ]
}

@test "networks_pull_iwd: idempotente (segunda corrida no duplica)" {
    printf '[Security]\nPassphrase=psk-xyz\n' > "$IWD_DIR/Otra.psk"
    networks_pull_iwd >/dev/null 2>&1

    local n1; n1="$(grep -c '^Otra' "$NETWORKS_STORE")"
    [ "$n1" -eq 1 ]

    networks_pull_iwd >/dev/null 2>&1
    local n2; n2="$(grep -c '^Otra' "$NETWORKS_STORE")"
    [ "$n2" -eq 1 ]
}

@test "networks_pull_iwd: no pisa SSID ya presente en la DB" {
    printf '# ssid\tpsk\tiface\tautoconnect\tpriority\tupdated\n' > "$NETWORKS_STORE"
    printf 'MiRed\tpsk-vieja\twlan0\tyes\t0\t1700000000\n' >> "$NETWORKS_STORE"
    printf '[Security]\nPassphrase=psk-nueva\n' > "$IWD_DIR/MiRed.psk"

    networks_pull_iwd >/dev/null 2>&1
    run grep -P '^MiRed\tpsk-vieja\t' "$NETWORKS_STORE"
    [ "$status" -eq 0 ]
    run grep -P '^MiRed\tpsk-nueva\t' "$NETWORKS_STORE"
    [ "$status" -ne 0 ]
}

@test "networks_pull_iwd: multiplos SSID se importan todos" {
    printf '[Security]\nPassphrase=psk-a\n' > "$IWD_DIR/RedA.psk"
    printf '[Security]\nPassphrase=psk-b\n' > "$IWD_DIR/RedB.psk"

    networks_pull_iwd >/dev/null 2>&1
    run grep -c '^Red[AB]' "$NETWORKS_STORE"
    [ "$status" -eq 0 ]
    [ "$output" -eq 2 ]
}
