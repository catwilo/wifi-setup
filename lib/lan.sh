#!/usr/bin/env bash
# lib/lan.sh -- configuracion del cable LAN (ethernet).
#
# RESPONSABILIDAD UNICA: crear, activar y desactivar el perfil NM del
# cable ethernet para conectar con otro equipo por red directa.
#
# MODELO:
#   - Perfil NM con autoconnect=off: la configuracion existe y sobrevive
#     reboot, pero NO se activa automaticamente. El usuario la activa
#     cuando conecta el cable.
#   - Modos:
#       server   IP estatica (default 1.2.3.2/24) + NAT (shared) si hay
#                upstream, para compartir internet con el otro equipo.
#       client   IP estatica (default 1.2.3.1/24) + gateway 1.2.3.2,
#                para recibir internet del otro equipo.
#       router   DHCP del router conectado al cable, sin NAT.
#       auto     DHCP del router, sin configuracion propia.
#   - IP configurable: wifi lan setup server --ip 10.0.0.1/24
#
# Persistencia: STATE_DIR/lan.state con LAN_IFACE/LAN_MODE/LAN_IP/LAN_GW.
#
# Requiere: common.sh + nm.sh + log.sh cargados antes.

LAN_STATE_FILE="${STATE_DIR}/lan.state"
LAN_PROFILE="wifi-setup-lan"

# ---------------------------------------------------------------------------
# _lan_load_state -- carga LAN_IFACE/LAN_MODE/LAN_IP/LAN_GW.
# ---------------------------------------------------------------------------
_lan_load_state() {
    LAN_IFACE=""
    LAN_MODE=""
    LAN_IP=""
    LAN_GW=""
    [[ -f "${LAN_STATE_FILE}" ]] || return 0
    # shellcheck source=/dev/null
    source "${LAN_STATE_FILE}"
}

# _lan_save_state -- persiste los valores actuales.
_lan_save_state() {
    mkdir -p "${STATE_DIR}"
    cat > "${LAN_STATE_FILE}" <<EOF
LAN_IFACE="${LAN_IFACE}"
LAN_MODE="${LAN_MODE}"
LAN_IP="${LAN_IP}"
LAN_GW="${LAN_GW}"
EOF
    chmod 600 "${LAN_STATE_FILE}"
}

# ---------------------------------------------------------------------------
# _lan_default_ip <mode> -- imprime la IP estatica por defecto del modo.
# ---------------------------------------------------------------------------
_lan_default_ip() {
    case "$1" in
        server) echo "1.2.3.2/24" ;;
        client) echo "1.2.3.1/24" ;;
        *)      echo "" ;;
    esac
}

# ---------------------------------------------------------------------------
# _lan_default_gw <mode> -- imprime el gateway por defecto.
# ---------------------------------------------------------------------------
_lan_default_gw() {
    case "$1" in
        client) echo "1.2.3.2" ;;
        *)      echo "" ;;
    esac
}

# ---------------------------------------------------------------------------
# _lan_autodetect_iface -- primera ethernet no virtual.
# ---------------------------------------------------------------------------
_lan_autodetect_iface() {
    local iface
    while IFS=: read -r iface _type _state _conn; do
        [[ -n "${iface}" ]] || continue
        echo "${iface}"
        return 0
    done < <(nm_dev_ethernet_list)
    return 1
}

# ---------------------------------------------------------------------------
# lan_setup <server|client|router|auto> [--iface X] [--ip CIDR] [--gw IP]
# Crea el perfil NM (idempotente, autoconnect=off). NO lo activa.
# ---------------------------------------------------------------------------
lan_setup() {
    nm_require
    local mode="${1:-}" iface="" ip="" gw=""
    shift || true

    case "${mode}" in
        server|client|router|auto) ;;
        "") die "uso: wifi lan setup <server|client|router|auto> [--iface X] [--ip CIDR] [--gw IP]" ;;
        *)  die "modo invalido: '${mode}' (server|client|router|auto)" ;;
    esac

    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --iface) iface="${2:-}"; shift 2 ;;
            --ip)    ip="${2:-}";    shift 2 ;;
            --gw)    gw="${2:-}";    shift 2 ;;
            *) die "flag desconocido: $1" ;;
        esac
    done

    [[ -n "${iface}" ]] || iface="$(_lan_autodetect_iface || true)"
    [[ -n "${iface}" ]] || die "no se detecto interfaz ethernet -- usa --iface <nombre>"

    case "${mode}" in
        server)
            [[ -n "${ip}" ]] || ip="$(_lan_default_ip server)"
            nm_ethernet_create "${LAN_PROFILE}" "${iface}" shared
            # con method=shared NM asigna la IP de gateway automaticamente;
            # si el usuario forzo --ip, la fijamos manual con la IP + sharing
            if [[ -n "${ip}" && "${ip}" != "$(_lan_default_ip server)" ]]; then
                nm_con_delete "${LAN_PROFILE}"
                nmcli con add type ethernet con-name "${LAN_PROFILE}" \
                    ifname "${iface}" ipv4.method shared \
                    ipv4.addresses "${ip}" >/dev/null
            fi
            ;;
        client)
            [[ -n "${ip}" ]] || ip="$(_lan_default_ip client)"
            [[ -n "${gw}" ]] || gw="$(_lan_default_gw client)"
            nm_ethernet_create "${LAN_PROFILE}" "${iface}" manual "${ip}" "${gw}"
            ;;
        router)
            nm_ethernet_create "${LAN_PROFILE}" "${iface}" auto
            ;;
        auto)
            nm_ethernet_create "${LAN_PROFILE}" "${iface}" auto
            ;;
    esac

    nm_con_set_autoconnect "${LAN_PROFILE}" off

    LAN_IFACE="${iface}"
    LAN_MODE="${mode}"
    LAN_IP="${ip}"
    LAN_GW="${gw}"
    _lan_save_state

    ok "LAN configurado (${mode}) en ${iface} -- perfil '${LAN_PROFILE}' (autoconnect=off)"
    info "para activar: wifi lan up"
}

# ---------------------------------------------------------------------------
# lan_up -- activa el perfil LAN.
# ---------------------------------------------------------------------------
lan_up() {
    nm_require
    _lan_load_state
    nm_con_exists "${LAN_PROFILE}" \
        || die "perfil LAN '${LAN_PROFILE}' no existe -- corre: wifi lan setup <mode>"

    nm_con_up "${LAN_PROFILE}"
}

# ---------------------------------------------------------------------------
# lan_down -- desactiva el perfil LAN.
# ---------------------------------------------------------------------------
lan_down() {
    nm_require
    nm_con_exists "${LAN_PROFILE}" \
        || die "perfil LAN '${LAN_PROFILE}' no existe"

    nm_con_down "${LAN_PROFILE}"
}

# ---------------------------------------------------------------------------
# lan_status -- imprime estado actual del perfil LAN.
# ---------------------------------------------------------------------------
lan_status() {
    nm_require
    _lan_load_state

    if ! nm_con_exists "${LAN_PROFILE}"; then
        echo "LAN: no configurado"
        echo "  uso: wifi lan setup <server|client|router|auto>"
        return 0
    fi

    local active iface method
    active="$(nm_con_get "${LAN_PROFILE}" connection.autoconnect)"
    iface="$(nm_con_get "${LAN_PROFILE}" connection.interface-name)"
    method="$(nm_con_get "${LAN_PROFILE}" ipv4.method)"

    echo "LAN"
    echo "  perfil     : ${LAN_PROFILE}"
    echo "  iface      : ${iface:-—}"
    echo "  modo       : ${LAN_MODE:-—}"
    echo "  ipv4.method: ${method:-—}"
    echo "  IP         : ${LAN_IP:-—}"
    echo "  gateway    : ${LAN_GW:-—}"
    echo "  autoconnect: ${active:-—}"

    if nm_dev_ethernet_list | awk -F: -v i="${iface}" '$1==i && $3=="connected" {found=1} END{exit !found}' 2>/dev/null; then
        echo "  estado     : ACTIVO"
    else
        echo "  estado     : inactivo"
    fi
}

# ---------------------------------------------------------------------------
# lan_remove -- borra el perfil LAN y el state.
# ---------------------------------------------------------------------------
lan_remove() {
    nm_require
    nm_con_delete "${LAN_PROFILE}"
    rm -f "${LAN_STATE_FILE}"
    ok "perfil LAN eliminado"
}
