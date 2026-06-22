#!/usr/bin/env bash
# lib/lan.sh -- rol del cable LAN (enp4s0): server | client | router (#7).
# Manual, persistente a reinicio. server/client = par peer-to-peer con NAT
# bidireccional (cada uno comparte su upstream si lo tiene). router = solo
# conectividad via DHCP del router, sin NAT.
# Persistencia: STATE_DIR/lan-role.conf + systemd unit wifi-setup-lan.service

LAN_CONF="${STATE_DIR}/lan-role.conf"
LAN_UNIT="/etc/systemd/system/wifi-setup-lan.service"

# ---------------------------------------------------------------------------
# Leer config actual. Exporta LAN_IFACE, LAN_MODE, LAN_UPSTREAM.
# ---------------------------------------------------------------------------
lan_load() {
    LAN_IFACE=""; LAN_MODE=""; LAN_UPSTREAM=""
    [[ -f "${LAN_CONF}" ]] || return 1
    # shellcheck source=/dev/null
    source "${LAN_CONF}"
}

# ---------------------------------------------------------------------------
# lan_status: imprime estado actual legible.
# ---------------------------------------------------------------------------
lan_status() {
    if ! lan_load; then
        echo "lan: no configurado. Usa: wifi lan <server|client|router> [iface]"
        return 0
    fi
    echo "IFAZ     : ${LAN_IFACE}"
    echo "MODO     : ${LAN_MODE}"
    echo "UPSTREAM : ${LAN_UPSTREAM:-(ninguno, sin NAT)}"
    echo ""
    echo "IP actual: $(ip -o -4 addr show "${LAN_IFACE}" 2>/dev/null | awk '{print $4}' | head -1 || echo 'sin IP')"
    if systemctl is-active wifi-setup-lan >/dev/null 2>&1; then
        echo "servicio : activo (persistente a reinicio)"
    else
        echo "servicio : inactivo"
    fi
}

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# _lan_ensure_dhcpcd_allows <iface>
# Si dhcpcd.conf restringe interfaces via "allowinterfaces" y <iface> no esta
# en la lista, dhcpcd la rechaza ("invalid configuration") y el modo router
# nunca obtiene DHCP. Esta funcion la anade a la lista (idempotente). Si no
# hay directiva allowinterfaces, dhcpcd ya gestiona todo -> no hace nada.
# Solo ANADE; nunca quita una iface existente (no romper el acceso SSH).
# ---------------------------------------------------------------------------
_lan_ensure_dhcpcd_allows() {
    local iface="$1" conf="/etc/dhcpcd.conf"
    [[ -f "${conf}" ]] || return 0
    grep -qE "^allowinterfaces " "${conf}" || return 0
    if grep -qE "^allowinterfaces .*\b${iface}\b" "${conf}"; then
        log "INFO" "lan: ${iface} ya permitido en dhcpcd allowinterfaces"
        return 0
    fi
    cp -a "${conf}" "${conf}.wifisetup.bak" 2>/dev/null || true
    sed -i "s/^\(allowinterfaces .*\)$/\1 ${iface}/" "${conf}"
    log "INFO" "lan: ${iface} anadido a dhcpcd allowinterfaces (era excluido)"
}

# _lan_write_unit <iface> <mode> <upstream>
# Escribe y arranca el systemd unit que aplica el rol en cada boot.
# ---------------------------------------------------------------------------
_lan_write_unit() {
    local iface="$1" mode="$2" upstream="$3"
    local exec_cmd="/bin/bash -c '\
        ip addr flush dev ${iface} 2>/dev/null || true; \
        ip link set ${iface} up"

    case "${mode}" in
        server)
            exec_cmd+="; ip addr add 1.2.3.2/24 dev ${iface} 2>/dev/null || true"
            if [[ -n "${upstream}" ]]; then
                exec_cmd+="; sysctl -w net.ipv4.ip_forward=1; \
                    iptables -t nat -C POSTROUTING -o ${upstream} -j MASQUERADE 2>/dev/null || \
                        iptables -t nat -A POSTROUTING -o ${upstream} -j MASQUERADE; \
                    iptables -C FORWARD -i ${iface} -o ${upstream} -j ACCEPT 2>/dev/null || \
                        iptables -A FORWARD -i ${iface} -o ${upstream} -j ACCEPT; \
                    iptables -C FORWARD -i ${upstream} -o ${iface} -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
                        iptables -A FORWARD -i ${upstream} -o ${iface} -m state --state RELATED,ESTABLISHED -j ACCEPT"
            fi
            ;;
        client)
            exec_cmd+="; ip addr add 1.2.3.1/24 dev ${iface} 2>/dev/null || true; \
                ip route del default via 1.2.3.2 2>/dev/null || true; \
                ip route add default via 1.2.3.2 dev ${iface} metric 200 2>/dev/null || true"
            if [[ -n "${upstream}" ]]; then
                exec_cmd+="; sysctl -w net.ipv4.ip_forward=1; \
                    iptables -t nat -C POSTROUTING -o ${upstream} -j MASQUERADE 2>/dev/null || \
                        iptables -t nat -A POSTROUTING -o ${upstream} -j MASQUERADE; \
                    iptables -C FORWARD -i ${iface} -o ${upstream} -j ACCEPT 2>/dev/null || \
                        iptables -A FORWARD -i ${iface} -o ${upstream} -j ACCEPT; \
                    iptables -C FORWARD -i ${upstream} -o ${iface} -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
                        iptables -A FORWARD -i ${upstream} -o ${iface} -m state --state RELATED,ESTABLISHED -j ACCEPT"
            fi
            ;;
        router)
            exec_cmd+="; dhcpcd -n ${iface} 2>/dev/null || true"
            ;;
    esac
    exec_cmd+="'"

    cat > "${LAN_UNIT}" <<EOF
[Unit]
Description=wifi-setup: rol LAN persistente (${mode})
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${exec_cmd}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable wifi-setup-lan
    systemctl restart wifi-setup-lan
}

# ---------------------------------------------------------------------------
# lan_set_role <mode> [iface] [upstream]
# mode: server | client | router. iface default enp4s0 si no se indica
# (interfaz plan conocida en este equipo); valida que exista.
# upstream solo aplica a server/client (NAT); router nunca usa NAT.
# ---------------------------------------------------------------------------
lan_set_role() {
    local mode="$1" iface="${2:-enp4s0}" upstream="${3:-}"

    case "${mode}" in
        server|client|router) ;;
        *) die "modo lan invalido: '${mode}' (usa server|client|router)" ;;
    esac

    validate_interface "${iface}"

    local ssh_if
    ssh_if="$(detect_ssh_iface 2>/dev/null || true)"
    if [[ -n "${ssh_if}" && "${ssh_if}" == "${iface}" ]]; then
        log "WARN" "lan: ${iface} lleva la sesion SSH activa -- la config se aplica sin bajar la iface"
    fi

    if [[ "${mode}" != "router" ]] && [[ -z "${upstream}" ]]; then
        upstream="$(detect_usb_wifi 2>/dev/null || true)"
        [[ -n "${upstream}" ]] || log "WARN" "lan: no se detecto upstream wifi -- ${mode} sin NAT (solo conectividad)"
    fi
    [[ "${mode}" == "router" ]] && upstream=""

    mkdir -p "${STATE_DIR}"
    cat > "${LAN_CONF}" <<EOF
LAN_IFACE="${iface}"
LAN_MODE="${mode}"
LAN_UPSTREAM="${upstream}"
EOF
    chmod 600 "${LAN_CONF}"
    log "INFO" "lan roles definidos: IFAZ=${iface} MODO=${mode} UPSTREAM=${upstream:-ninguno}"

    [[ "${mode}" == "router" ]] && _lan_ensure_dhcpcd_allows "${iface}"
    _lan_write_unit "${iface}" "${mode}" "${upstream}"
    log "INFO" "lan: rol '${mode}' aplicado y persistente en ${iface}"
}
