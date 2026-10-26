#!/usr/bin/env bats
# networks_db.bats -- operaciones de la DB (export/import/prune).
# Foco en integridad de datos: export no pierde, import no duplica,
# prune no borra lo que existe.

load helpers

setup() {
    setup_env
    ok()      { printf '  [OK] %s\n'   "$*" >&2; }
    warn()    { printf '  [WARN] %s\n' "$*" >&2; }
    err()     { printf '  [ERR] %s\n'  "$*" >&2; }
    info()    { printf '  [i] %s\n'    "$*" >&2; }
    die()     { printf '  [ERR] %s\n'  "$*" >&2; return 1; }
    section() { :; }
    export -f ok warn err info die section 2>/dev/null || true

    nm_con_exists() { return 1; }
    nm_con_get()    { printf ''; }
    export -f nm_con_exists nm_con_get 2>/dev/null || true

    export IWD_DIR="$BATS_TEST_TMPDIR/iwd"
    export STATE_DIR="$BATS_TEST_TMPDIR/state"
    mkdir -p "$IWD_DIR" "$STATE_DIR"

    # shellcheck source=/dev/null
    source "$REPO/lib/networks.sh"

    # DB minima
    printf '# ssid\tpsk\tiface\tautoconnect\tpriority\tupdated\n' > "${NETWORKS_STORE}"
    printf 'RedA\tpskA\twlan0\tyes\t0\t1000\n' >> "${NETWORKS_STORE}"
    printf 'RedB\tpskB\twlan0\tno\t0\t1000\n'  >> "${NETWORKS_STORE}"
}

@test "networks_export: copia la DB integra a <path>" {
    local out="$BATS_TEST_TMPDIR/export.tsv"
    run networks_export "$out"
    [ "$status" -eq 0 ]
    [ -f "$out" ]
    run diff "${NETWORKS_STORE}" "$out"
    [ "$status" -eq 0 ]
}

@test "networks_export: falla sin path" {
    run networks_export ""
    [ "$status" -ne 0 ]
}

@test "networks_import: agrega filas nuevas sin duplicar existentes" {
    local inc="$BATS_TEST_TMPDIR/import.tsv"
    {
        printf '# header\n'
        printf 'RedA\tpskA\twlan0\tyes\t0\t1000\n'   # ya existe -> skip
        printf 'RedC\tpskC\twlan0\tyes\t0\t2000\n'   # nueva -> agregar
    } > "$inc"

    run networks_import "$inc"
    [ "$status" -eq 0 ]

    # RedA sigue una sola vez
    local count_a; count_a="$(grep -c '^RedA' "${NETWORKS_STORE}")"
    [ "$count_a" -eq 1 ]

    # RedC fue agregada
    run grep '^RedC' "${NETWORKS_STORE}"
    [ "$status" -eq 0 ]
}

@test "networks_import: no duplica si el archivo se importa dos veces" {
    local inc="$BATS_TEST_TMPDIR/import.tsv"
    printf 'RedC\tpskC\twlan0\tyes\t0\t2000\n' > "$inc"

    networks_import "$inc" >/dev/null 2>&1
    networks_import "$inc" >/dev/null 2>&1

    local count_c; count_c="$(grep -c '^RedC' "${NETWORKS_STORE}")"
    [ "$count_c" -eq 1 ]
}

@test "networks_import: falla si el archivo no existe" {
    run networks_import "$BATS_TEST_TMPDIR/no-existe.tsv"
    [ "$status" -ne 0 ]
}

@test "networks_cleanup: rechaza correr sin NM activo" {
    # systemctl is-active NM siempre falla en test -> debe abortar.
    run networks_cleanup
    [ "$status" -ne 0 ]
    [[ "$output" == *"requiere NM activo"* ]]

    # DB intacta
    run grep -c '^Red' "${NETWORKS_STORE}"
    [ "$output" -eq 2 ]
}

@test "networks_show: imprime SSID, PSK, filas por antena" {
    # nm_con_exists ya devuelve 1 (no existe en NM) -- show lo reporta.
    run networks_show "RedA"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SSID: RedA"* ]]
    [[ "$output" == *"PSK : pskA"* ]]
    [[ "$output" == *"wlan0"* ]]
}

@test "networks_show: falla si el SSID no esta en la DB" {
    run networks_show "NoExiste"
    [ "$status" -ne 0 ]
}
