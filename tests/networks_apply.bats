#!/usr/bin/env bats
# networks_apply.bats -- networks_apply y networks_apply_to_iwd.
# Cubre la propagacion DB -> iwd (.psk por SSID) y DB -> NM
# (networks_sync, mockeado). Sin este test, un cambio en la DB podria
# no propagarse a iwd y romper el fallback silenciosamente.

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
    mkdir -p "$STATE_DIR"

    SYNC_CALLED_FILE="$BATS_TEST_TMPDIR/sync_called"
    : > "$SYNC_CALLED_FILE"
    NM_ACTIVE=0
    export NM_ACTIVE SYNC_CALLED_FILE

    systemctl() {
        if [ "$1" = "is-active" ] && [ "$2" = "NetworkManager" ]; then
            [ "${NM_ACTIVE:-0}" = "1" ] && return 0 || return 1
        fi
        return 1
    }
    export -f systemctl 2>/dev/null || true

    # shellcheck source=/dev/null
    source "$REPO/lib/networks_store.sh"
    # shellcheck source=/dev/null
    source "$REPO/lib/networks_apply.sh"

    # IMPORTANTE: override DESPUES del source para que networks_sync del lib
    # no gane. Con NM_ACTIVE=0 el override no se usa (la rama ni entra),
    # pero con NM_ACTIVE=1 el contador confirma que se invoco el sync.
    networks_sync() {
        printf 'called\n' >> "$SYNC_CALLED_FILE"
    }
    nm_con_exists() { return 1; }
    export -f networks_sync nm_con_exists 2>/dev/null || true
}

@test "apply_to_iwd: no-op si IWD_DIR no existe" {
    _networks_store_init
    _networks_store_upsert "RedA" "pskA" "wlan0" "yes" "0"

    run networks_apply_to_iwd
    [ "$status" -eq 0 ]
    [ ! -d "$IWD_DIR" ]
}

@test "apply_to_iwd: escribe un .psk por SSID, no por fila" {
    mkdir -p "$IWD_DIR"
    _networks_store_init
    _networks_store_upsert "RedA" "pskA" "wlan0" "yes" "0"
    _networks_store_upsert "RedA" "pskA" "wlx1" "no" "0"
    _networks_store_upsert "RedB" "pskB" "wlan0" "yes" "0"

    run networks_apply_to_iwd
    [ "$status" -eq 0 ]

    [ -f "${IWD_DIR}/RedA.psk" ]
    [ -f "${IWD_DIR}/RedB.psk" ]
}

@test "apply_to_iwd: idempotente (segunda corrida reescribe sin duplicar)" {
    mkdir -p "$IWD_DIR"
    _networks_store_init
    _networks_store_upsert "RedA" "pskA" "wlan0" "yes" "0"

    networks_apply_to_iwd
    local hash1 hash2
    hash1="$(sha256sum "${IWD_DIR}/RedA.psk" | awk '{print $1}')"

    networks_apply_to_iwd
    hash2="$(sha256sum "${IWD_DIR}/RedA.psk" | awk '{print $1}')"

    [ "$hash1" = "$hash2" ]
    run grep -c 'Passphrase' "${IWD_DIR}/RedA.psk"
    [ "$output" = "1" ]
}

@test "apply_to_iwd: salta filas sin psk" {
    mkdir -p "$IWD_DIR"
    _networks_store_init
    # Escribir filas directamente: _networks_store_upsert con psk vacio
    # produce un TSV donde el campo 2 queda entre dos tabs; el read de
    # networks_apply_to_iwd con IFS=$'\t' puede correr el psk al campo
    # siguiente en algunas builds de bash. La fila directa es fiel al
    # TSV final que ve apply_to_iwd en produccion.
    {
        printf '# header\n'
        printf 'RedA\tpskA\twlan0\tyes\t0\t0\n'
        printf 'RedB\t\twlan0\tyes\t0\t0\n'
    } > "${NETWORKS_STORE}"

    run networks_apply_to_iwd
    [ "$status" -eq 0 ]

    [ -f "${IWD_DIR}/RedA.psk" ]
    [ ! -f "${IWD_DIR}/RedB.psk" ]
}

@test "apply_to_iwd: contenido del .psk es [Security] + Passphrase" {
    mkdir -p "$IWD_DIR"
    _networks_store_init
    _networks_store_upsert "RedA" "secreto123" "wlan0" "yes" "0"

    networks_apply_to_iwd

    run cat "${IWD_DIR}/RedA.psk"
    echo "$output" | grep -qx '\[Security\]'
    echo "$output" | grep -qx 'Passphrase=secreto123'
}

@test "apply: sin NM activo, solo llama a iwd" {
    mkdir -p "$IWD_DIR"
    _networks_store_init
    _networks_store_upsert "RedA" "pskA" "wlan0" "yes" "0"
    NM_ACTIVE=0

    networks_apply

    [ -f "${IWD_DIR}/RedA.psk" ]
    run cat "$SYNC_CALLED_FILE"
    [ -z "$output" ]
}

@test "apply: con NM activo, llama a networks_sync y a iwd" {
    mkdir -p "$IWD_DIR"
    _networks_store_init
    _networks_store_upsert "RedA" "pskA" "wlan0" "yes" "0"
    NM_ACTIVE=1

    networks_apply

    [ -f "${IWD_DIR}/RedA.psk" ]
    run cat "$SYNC_CALLED_FILE"
    [ "$output" = "called" ]
}
