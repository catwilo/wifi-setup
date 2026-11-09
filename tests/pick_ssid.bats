#!/usr/bin/env bats
# pick_ssid.bats -- el picker devuelve el SSID sin las comillas que usa
# last-scan.txt. Regresion: scan.sh escribe '"Familia_Mora"' (comillas
# para visibilidad de espacios); el refactor perdio el strip al elegir
# y se creo un perfil NM con el SSID literal '"Familia_Mora"'.

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
    source "$REPO/lib/profiles.sh"
}

@test "_profile_strip_ssid_quotes: SSID entre comillas -> sin comillas" {
    run _profile_strip_ssid_quotes '"Familia_Mora"'
    [ "$status" -eq 0 ]
    [ "$output" = "Familia_Mora" ]
}

@test "_profile_strip_ssid_quotes: SSID sin comillas queda igual" {
    run _profile_strip_ssid_quotes 'Familia_Mora'
    [ "$status" -eq 0 ]
    [ "$output" = "Familia_Mora" ]
}

@test "_profile_strip_ssid_quotes: SSID con espacios internos preserva espacios" {
    run _profile_strip_ssid_quotes '"Familia Mora Cafe"'
    [ "$status" -eq 0 ]
    [ "$output" = "Familia Mora Cafe" ]
}

@test "_profile_strip_ssid_quotes: comillas internas no se tocan" {
    run _profile_strip_ssid_quotes '"My"Net"'
    [ "$status" -eq 0 ]
    [ "$output" = 'My"Net' ]
}

@test "_profile_strip_ssid_quotes: string vacio no rompe" {
    run _profile_strip_ssid_quotes ''
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "_profile_strip_ssid_quotes: una sola comilla no se quita" {
    run _profile_strip_ssid_quotes '"'
    [ "$status" -eq 0 ]
    [ "$output" = '"' ]
}
