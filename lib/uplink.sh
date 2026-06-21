#!/usr/bin/env bash
# lib/uplink.sh -- selector PRIMARY/FALLBACK de uplink (wifi vs lan-a-router).
# Failover no-preemptivo basado en eventos dhcpcd (CARRIER/NOCARRIER), sin polling.
# Persistencia: STATE_DIR/uplink-role.conf

UPLINK_CONF="${STATE_DIR}/uplink-role.conf"

# ---------------------------------------------------------------------------
# Leer config actual. Exporta UPLINK_PRIMARY, UPLINK_FALLBACK, UPLINK_ACTIVE.
# ---------------------------------------------------------------------------
uplink_load() {
    UPLINK_PRIMARY=""; UPLINK_FALLBACK=""; UPLINK_ACTIVE=""
    [[ -f "${UPLINK_CONF}" ]] || return 1
    # shellcheck source=/dev/null
    source "${UPLINK_CONF}"
}

# ---------------------------------------------------------------------------
# uplink_set_roles <primary_iface> <fallback_iface>
# Define los roles. NO activa nada todavia -- eso lo hace uplink_activate.
# ---------------------------------------------------------------------------
uplink_set_roles() {
    local primary="$1" fallback="$2"
    [[ "${primary}" == "${fallback}" ]] && die "PRIMARY y FALLBACK no pueden ser la misma interfaz (${primary}) -- define ambas distintas"
    validate_interface "${primary}"
    validate_interface "${fallback}"
    mkdir -p "${STATE_DIR}"
    cat > "${UPLINK_CONF}" <<EOF
UPLINK_PRIMARY="${primary}"
UPLINK_FALLBACK="${fallback}"
UPLINK_ACTIVE="${primary}"
EOF
    chmod 600 "${UPLINK_CONF}"
    log "INFO" "uplink roles definidos: PRIMARY=${primary} FALLBACK=${fallback}"
}

# ---------------------------------------------------------------------------
# uplink_activate <iface>
# Activa <iface> (dhcpcd -n) y apaga la otra interfaz del par (down, sin dhcpcd).
# No toca la interfaz que lleva la sesion SSH (R3.3 -- seguridad de acceso).
# ---------------------------------------------------------------------------
uplink_activate() {
    local target="$1"
    uplink_load || die "no hay roles uplink definidos -- usa: wifi uplink primary <iface> fallback <iface>"

    local other=""
    [[ "${target}" == "${UPLINK_PRIMARY}" ]] && other="${UPLINK_FALLBACK}"
    [[ "${target}" == "${UPLINK_FALLBACK}" ]] && other="${UPLINK_PRIMARY}"
    [[ -n "${other}" ]] || die "iface '${target}' no es PRIMARY ni FALLBACK conocido"

    local ssh_if
    ssh_if="$(detect_ssh_iface 2>/dev/null || true)"

    log "INFO" "uplink: activando ${target}, apagando ${other}"
    dhcpcd -n "${target}" 2>/dev/null || log "WARN" "dhcpcd fallo en ${target}"

    if [[ -n "${ssh_if}" && "${other}" == "${ssh_if}" ]]; then
        log "WARN" "uplink: NO apago ${other} (lleva la sesion SSH activa)"
    else
        dhcpcd -k "${other}" 2>/dev/null || true
        ip link set "${other}" down 2>/dev/null || true
    fi

    sed -i "s/^UPLINK_ACTIVE=.*/UPLINK_ACTIVE=\"${target}\"/" "${UPLINK_CONF}"
    log "INFO" "uplink: activo ahora = ${target}"
}

# ---------------------------------------------------------------------------
# _uplink_has_internet <iface>
# Confirmacion puntual de internet real (no carrier fisico) POR ESA IFACE
# especifica (ping -I), 3 intentos espaciados. Anclar a la iface evita un
# falso positivo si otra interfaz (p.ej. el fallback) tambien tuviera ruta
# default -- sin esto, el ping podria salir por otro lado y dar OK aunque
# la iface evaluada no tenga internet real. Se llama SOLO dentro de un
# evento ya disparado por el kernel (NOCARRIER) -- no es un poller/timer
# en reposo, cero consumo cuando no esta pasando nada.
# ---------------------------------------------------------------------------
_uplink_has_internet() {
    local iface="$1" i
    for i in 1 2 3; do
        ping -c1 -W2 -I "${iface}" 1.1.1.1 >/dev/null 2>&1 && return 0
        [[ "${i}" -lt 3 ]] && sleep 3
    done
    return 1
}

# ---------------------------------------------------------------------------
# uplink_on_carrier_event <iface> <reason>
# Llamado desde el dhcpcd hook. reason: CARRIER | NOCARRIER
# No-preemptivo: si el activo actual pierde carrier, pasa al otro.
# Si el activo actual SIGUE con carrier, no hace nada (nunca preemptar).
# ---------------------------------------------------------------------------
uplink_on_carrier_event() {
    local iface="$1" reason="$2"
    uplink_load || return 0

    [[ "${iface}" == "${UPLINK_ACTIVE}" ]] || return 0

    if [[ "${reason}" == "NOCARRIER" ]]; then
        if _uplink_has_internet "${iface}"; then
            log "INFO" "uplink: ${UPLINK_ACTIVE} sin carrier momentaneo pero internet OK tras confirmar -- sin accion"
            return 0
        fi
        local other=""
        [[ "${UPLINK_ACTIVE}" == "${UPLINK_PRIMARY}" ]] && other="${UPLINK_FALLBACK}"
        [[ "${UPLINK_ACTIVE}" == "${UPLINK_FALLBACK}" ]] && other="${UPLINK_PRIMARY}"
        log "WARN" "uplink: ${UPLINK_ACTIVE} sin carrier e internet no confirmado -- activando ${other}"
        uplink_activate "${other}"
    fi
    # CARRIER (recuperacion) en la interfaz activa: no-op, ya esta activa.
    # CARRIER en la interfaz inactiva: no-op intencional (no-preemptivo, R8 confirmado).
}

# ---------------------------------------------------------------------------
# uplink_status: imprime estado actual legible.
# ---------------------------------------------------------------------------
uplink_status() {
    if ! uplink_load; then
        echo "uplink: no configurado. Usa: wifi uplink primary <iface> fallback <iface>"
        return 0
    fi
    echo "PRIMARY  : ${UPLINK_PRIMARY}"
    echo "FALLBACK : ${UPLINK_FALLBACK}"
    echo "ACTIVO   : ${UPLINK_ACTIVE}"
}
