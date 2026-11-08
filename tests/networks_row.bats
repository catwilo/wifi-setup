#!/usr/bin/env bats
# networks_row.bats -- _networks_row y _networks_psk_for_ssid.
# Cubre el bug de IFS=$'\t' read colapsando tabs consecutivos: un psk
# vacio en el TSV corria los campos siguientes (psk recibia la iface).

load helpers

setup() {
    setup_env
    die()  { printf '[ERR] %s\n' "$*" >&2; exit 1; }
    info() { :; }
    ok()   { :; }
    warn() { :; }
    export -f die info ok warn 2>/dev/null || true

    export STATE_DIR="$BATS_TEST_TMPDIR/state"
    mkdir -p "$STATE_DIR"

    # shellcheck source=/dev/null
    source "$REPO/lib/networks_store.sh"
}

@test "_networks_row: 6 campos con psk vacio no corre el resto" {
    _networks_row "$(printf 'RedB\t\twlan0\tyes\t0\t123')"
    [ "$_N_SSID"  = "RedB" ]
    [ -z "$_N_PSK" ]
    [ "$_N_IFACE" = "wlan0" ]
    [ "$_N_AUTO"  = "yes" ]
    [ "$_N_PRIO"  = "0" ]
    [ "$_N_TS"    = "123" ]
}

@test "_networks_row: 6 campos con psk no vacio" {
    _networks_row "$(printf 'RedA\tsecreto\twlan0\tyes\t10\t999')"
    [ "$_N_SSID"  = "RedA" ]
    [ "$_N_PSK"   = "secreto" ]
    [ "$_N_IFACE" = "wlan0" ]
    [ "$_N_AUTO"  = "yes" ]
    [ "$_N_PRIO"  = "10" ]
    [ "$_N_TS"    = "999" ]
}

@test "_networks_row: psk con tab embebido en SSID (caso defensivo)" {
    # Un SSID puede tener caracteres raros pero nunca tab; el TSV es
    # el limite. Solo verifica que un psk real con caracteres normales
    # no se rompe.
    _networks_row "$(printf 'RedCon Spaces\taabbcc\twlan0\tno\t5\t0')"
    [ "$_N_SSID"  = "RedCon Spaces" ]
    [ "$_N_PSK"   = "aabbcc" ]
    [ "$_N_IFACE" = "wlan0" ]
}

@test "_networks_psk_for_ssid: ignora filas con psk vacio (no devuelve iface)" {
    _networks_store_init
    {
        printf '# header\n'
        printf 'RedAbierta\t\twlan0\tyes\t0\t0\n'
        printf 'RedConPsk\tsupersecreto\twlan0\tyes\t0\t0\n'
    } > "${NETWORKS_STORE}"

    run _networks_psk_for_ssid "RedAbierta"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "_networks_psk_for_ssid: devuelve el psk del SSID correcto" {
    _networks_store_init
    {
        printf '# header\n'
        printf 'RedAbierta\t\twlan0\tyes\t0\t0\n'
        printf 'RedConPsk\tsupersecreto\twlan0\tyes\t0\t0\n'
    } > "${NETWORKS_STORE}"

    run _networks_psk_for_ssid "RedConPsk"
    [ "$status" -eq 0 ]
    [ "$output" = "supersecreto" ]
}
