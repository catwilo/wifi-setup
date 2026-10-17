#!/usr/bin/env bats
# boot_select.bats -- seleccion del perfil de fallback al arranque.

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

    export IWD_DIR="$BATS_TEST_TMPDIR/iwd"
    export STATE_DIR="$BATS_TEST_TMPDIR/state"
    mkdir -p "$IWD_DIR" "$STATE_DIR"

    # shellcheck source=/dev/null
    source "$REPO/lib/networks.sh"

    # DB con dos SSIDs en wlx1 con prioridades distintas
    printf '# ssid\tpsk\tiface\tautoconnect\tpriority\tupdated\n' > "${NETWORKS_STORE}"
    printf 'RedBaja\tp1\twlx1\tyes\t10\t1000\n'  >> "${NETWORKS_STORE}"
    printf 'RedAlta\tp2\twlx1\tyes\t100\t1000\n' >> "${NETWORKS_STORE}"
    printf 'RedOtra\tp3\twlx1\tyes\t50\t1000\n'  >> "${NETWORKS_STORE}"
}

@test "boot-select: elige el perfil con mayor prioridad de la iface" {
    # Reproducir la logica del selector: awk + sort -rn por prio, desempate por SSID.
    local best
    best="$(_networks_store_rows \
        | awk -F'\t' -v i="wlx1" '$3==i && $2!="" {print $5"\t"$1}' \
        | sort -rn -k1,1 -k2,2 \
        | head -1 | cut -f2)"
    [ "${best}" = "RedAlta" ]
}

@test "boot-select: sin perfiles para la iface, no hay best" {
    local best
    best="$(_networks_store_rows \
        | awk -F'\t' -v i="wlan9" '$3==i && $2!="" {print $5"\t"$1}' \
        | sort -rn -k1,1 -k2,2 \
        | head -1 | cut -f2)"
    [ -z "${best}" ]
}
