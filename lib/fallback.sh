#!/usr/bin/env bash
# lib/fallback.sh -- alterna entre NetworkManager (backbone) e iwd (fallback).
#
# RESPONSABILIDAD UNICA: apagar limpiamente NetworkManager y dejar iwd al
# mando con DHCP integrado, o revertir exactamente ese cambio.
#
# MODELO:
#   - fallback on:     para + enmascara NM, activa DHCP integrado de iwd
#                      (EnableNetworkConfiguration=true en /etc/iwd/main.conf),
#                      arranca + habilita iwd.
#   - fallback off:    para iwd, desenmascara + arranca NM.
#   - fallback status: reporta quien esta al mando ahora.
#
# Persistencia: STATE_DIR/fallback.state guarda el estado previo al "on"
# para que "off" restaure el estado original sin asumir nada.
#
# DHCP: iwd hace DHCP por si mismo cuando EnableNetworkConfiguration=true;
# no se necesita dhcpcd ni NM corriendo. Al volver a NM, NM toma su DHCP.
#
# Los perfiles NM NO se tocan: cuando NM vuelve, reconecta solo con ellos.
# iwd no ve esos perfiles; al arrancar por primera vez pide credenciales
# (iwctl) o espera configuracion. No se pierden credenciales.
#
# Requiere: common.sh + log.sh cargados antes.

FALLBACK_STATE="${STATE_DIR}/fallback.state"

# _fallback_svc_snapshot <svc> -- "active=X enabled=Y" compacto.
_fallback_svc_snapshot() {
    local svc="$1" active enabled
    active="$(systemctl is-active  "${svc}" 2>/dev/null || true)"
    enabled="$(systemctl is-enabled "${svc}" 2>/dev/null || true)"
    printf 'active=%s enabled=%s\n' "${active:-unknown}" "${enabled:-unknown}"
}

# _fallback_ensure_iwd_netconf -- garantiza que iwd haga DHCP por si mismo
# (sin dhcpcd ni NM corriendo). Escribe /etc/iwd/main.conf con la directiva
# EnableNetworkConfiguration=true. Idempotente: solo toca el archivo si
# falta la directiva. Preserva el resto de la config del usuario.
_fallback_ensure_iwd_netconf() {
    local conf="/etc/iwd/main.conf"
    mkdir -p /etc/iwd
    if [[ -s "${conf}" ]] && grep -qE '^[[:space:]]*EnableNetworkConfiguration[[:space:]]*=' "${conf}"; then
        info "iwd: DHCP integrado ya declarado en ${conf}"
        return 0
    fi
    if [[ -s "${conf}" ]]; then
        printf '\n[General]\nEnableNetworkConfiguration=true\n' >> "${conf}"
    else
        printf '[General]\nEnableNetworkConfiguration=true\n' > "${conf}"
    fi
    ok "iwd: DHCP integrado habilitado en ${conf}"
}

# _fallback_wait_ip <timeout-s> -- espera a que alguna antena WiFi tenga IP.
# Best-effort: no aborta si vence el timeout (iwd puede necesitar
# 'iwctl station <iface> connect <ssid>' si no conoce la red).
_fallback_wait_ip() {
    local timeout="${1:-30}" waited=0 ip w
    info "esperando IP en alguna antena WiFi (max ${timeout}s)..."
    while [[ "${waited}" -lt "${timeout}" ]]; do
        for w in /sys/class/net/*/wireless; do
            [[ -d "${w}" ]] || continue
            w="${w%/wireless}"; w="${w##*/}"
            ip="$(ip -4 -o addr show "${w}" 2>/dev/null | awk '{print $4}' | head -1)"
            if [[ -n "${ip}" ]]; then
                ok "IP asignada: ${w} ${ip}"
                return 0
            fi
        done
        sleep 2
        waited=$((waited + 2))
    done
    warn "ninguna antena obtuvo IP en ${timeout}s"
    warn "si iwd no conoce la red: iwctl station <iface> connect <ssid>"
    return 1
}

# fallback_status -- quien esta al mando.
fallback_status() {
    section "Fallback (iwd vs NetworkManager)"
    printf '  NetworkManager : %s\n' "$(_fallback_svc_snapshot NetworkManager)"
    printf '  iwd            : %s\n' "$(_fallback_svc_snapshot iwd)"

    local mode="?"
    if systemctl is-active iwd >/dev/null 2>&1; then
        mode="iwd (fallback)"
    elif systemctl is-active NetworkManager >/dev/null 2>&1; then
        mode="NetworkManager (backbone)"
    else
        mode="ninguno (sin gestor WiFi activo)"
    fi
    ok "gestor activo: ${mode}"

    if [[ -f "${FALLBACK_STATE}" ]]; then
        info "state previo guardado en ${FALLBACK_STATE}:"
        while IFS= read -r _line; do
            printf '    %s\n' "${_line}"
        done < "${FALLBACK_STATE}"
    fi
}

# fallback_on -- apagar NM, dejar iwd al mando con DHCP integrado.
fallback_on() {
    if systemctl is-active iwd >/dev/null 2>&1 \
       && ! systemctl is-active NetworkManager >/dev/null 2>&1; then
        ok "ya estas en fallback (iwd activo, NM parado)"
        return 0
    fi

    mkdir -p "${STATE_DIR}"
    {
        printf 'NM_ACTIVE_BEFORE=%s\n'  "$(systemctl is-active  NetworkManager 2>/dev/null || true)"
        printf 'NM_ENABLED_BEFORE=%s\n' "$(systemctl is-enabled NetworkManager 2>/dev/null || true)"
        printf 'IWD_ACTIVE_BEFORE=%s\n' "$(systemctl is-active iwd 2>/dev/null || true)"
        printf 'IWD_ENABLED_BEFORE=%s\n' "$(systemctl is-enabled iwd 2>/dev/null || true)"
    } > "${FALLBACK_STATE}"
    chmod 600 "${FALLBACK_STATE}"

    section "Cambiando a iwd (fallback)"
    _fallback_ensure_iwd_netconf

    info "parando NetworkManager..."
    systemctl stop NetworkManager 2>/dev/null || true
    info "enmascarando NetworkManager (evita autostart en boot)..."
    systemctl mask NetworkManager 2>/dev/null || true

    info "habilitando iwd..."
    systemctl unmask iwd 2>/dev/null || true
    systemctl enable iwd 2>/dev/null || true
    info "arrancando iwd..."
    systemctl restart iwd 2>/dev/null || true

    if ! systemctl is-active iwd >/dev/null 2>&1; then
        err "iwd no arranco -- revisa: journalctl -u iwd -n 40"
        warn "para volver atras: wifi fallback off"
        return 1
    fi
    ok "iwd activo -- es el gestor WiFi ahora"

    _fallback_wait_ip 30 || true

    info "conecta con: iwctl station <iface> connect <ssid>"
    info "scan con:    iwctl station <iface> scan"
}

# fallback_off -- volver a NetworkManager (backbone).
fallback_off() {
    if systemctl is-active NetworkManager >/dev/null 2>&1 \
       && ! systemctl is-active iwd >/dev/null 2>&1; then
        ok "ya estas en NetworkManager (iwd parado)"
        return 0
    fi

    section "Volviendo a NetworkManager (backbone)"
    info "parando iwd..."
    systemctl stop iwd 2>/dev/null || true
    info "deshabilitando iwd..."
    systemctl disable iwd 2>/dev/null || true

    info "desenmascarando NetworkManager..."
    systemctl unmask NetworkManager 2>/dev/null || true
    info "habilitando NetworkManager..."
    systemctl enable NetworkManager 2>/dev/null || true
    info "arrancando NetworkManager..."
    systemctl restart NetworkManager 2>/dev/null || true

    if ! systemctl is-active NetworkManager >/dev/null 2>&1; then
        err "NetworkManager no arranco -- revisa: journalctl -u NetworkManager -n 40"
        return 1
    fi
    ok "NetworkManager activo -- backbone restaurado"

    _fallback_wait_ip 30 || true

    rm -f "${FALLBACK_STATE}"
}
