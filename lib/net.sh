#!/usr/bin/env bash
# lib/net.sh — detección de interfaces y limpieza de stack de red previo

# ---------------------------------------------------------------------------
# Detectar todas las interfaces WiFi disponibles
# Devuelve lista separada por newline
# ---------------------------------------------------------------------------
detect_wifi_interfaces() {
    local ifaces=()
    for p in /sys/class/net/wl* /sys/class/net/wlan*; do
        [[ -e "${p}" ]] || continue
        ifaces+=("${p##*/}")
    done
    # deduplicar
    printf '%s\n' "${ifaces[@]}" | sort -u
}

# ---------------------------------------------------------------------------
# Detectar interfaz USB WiFi (busca el que tiene un path USB en su symlink)
# ---------------------------------------------------------------------------
detect_usb_wifi() {
    for p in /sys/class/net/wl*; do
        [[ -e "${p}" ]] || continue
        local iface="${p##*/}"
        local real
        real=$(readlink -f "${p}" 2>/dev/null || true)
        if echo "${real}" | grep -q '/usb'; then
            echo "${iface}"
            return 0
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# Detectar interfaz ethernet/plan (no WiFi, no loopback, no virtual)
# ---------------------------------------------------------------------------
detect_plan_interface() {
    for p in /sys/class/net/e*; do
        [[ -e "${p}" ]] || continue
        local iface="${p##*/}"
        # excluir virtuales conocidos
        [[ "${iface}" =~ ^(lo|docker|virbr|veth|br-) ]] && continue
        echo "${iface}"
        return 0
    done
    # fallback: cualquier no-lo no-wl
    for p in /sys/class/net/*; do
        [[ -e "${p}" ]] || continue
        local iface="${p##*/}"
        [[ "${iface}" == "lo" ]] && continue
        [[ "${iface}" =~ ^wl ]] && continue
        [[ "${iface}" =~ ^(docker|virbr|veth|br-) ]] && continue
        echo "${iface}"
        return 0
    done
    return 1
}

# ---------------------------------------------------------------------------
# Detectar qué stack de red está activo
# ---------------------------------------------------------------------------
detect_network_stack() {
    local stacks=()
    systemctl is-active NetworkManager >/dev/null 2>&1  && stacks+=("NetworkManager")
    systemctl is-active dhcpcd          >/dev/null 2>&1  && stacks+=("dhcpcd")
    systemctl is-active systemd-networkd >/dev/null 2>&1 && stacks+=("systemd-networkd")
    systemctl is-active wpa_supplicant  >/dev/null 2>&1  && stacks+=("wpa_supplicant")
    printf '%s\n' "${stacks[@]:-}"
}

# ---------------------------------------------------------------------------
# Limpiar stack previo de forma segura
# Detiene y deshabilita todo lo que pueda interferir
# ---------------------------------------------------------------------------
purge_network_stack() {
    log "INFO" "detectando y limpiando stack de red previo..."

    # NOTA: dhcpcd NO se enmascara — es el gestor del upstream USB en el
    # modelo dhcpcd. systemd-networkd se conserva para el plan (enp4s0).
    local services=(
        NetworkManager
        NetworkManager-wait-online
    )

    for svc in "${services[@]}"; do
        if systemctl list-unit-files "${svc}.service" 2>/dev/null | grep -q "${svc}"; then
            if systemctl is-active "${svc}" >/dev/null 2>&1; then
                log "INFO" "deteniendo ${svc}..."
                systemctl stop "${svc}" 2>/dev/null || log "WARN" "no se pudo detener ${svc}"
            fi
            systemctl disable "${svc}" 2>/dev/null || true
            systemctl mask "${svc}" 2>/dev/null || true
            log "INFO" "deshabilitado: ${svc}"
        fi
    done

    # NO matar dhcpcd: es el gestor del upstream en el modelo nuevo. Solo
    # liberar leases viejos para evitar IPs duplicadas; dhcpcd repedirá limpio.
    if pgrep -x dhcpcd >/dev/null 2>&1; then
        log "INFO" "liberando leases dhcpcd previos (evita IPs duplicadas)..."
        dhcpcd -k 2>/dev/null || true
        sleep 1
    fi
    if pgrep -x dhclient >/dev/null 2>&1; then
        log "INFO" "matando procesos dhclient sueltos..."
        pkill -x dhclient 2>/dev/null || true
        sleep 1
    fi

    # Limpiar leases DHCP viejos
    rm -f /var/lib/dhcp/dhclient*.leases 2>/dev/null || true
    rm -f /var/lib/dhcpcd/*.lease 2>/dev/null || true

    # Limpiar configs NetworkManager antiguas (preservar solo lo de este proyecto)
    if [[ -d /etc/NetworkManager/system-connections ]]; then
        log "INFO" "backup de conexiones NM previas → ${STATE_DIR}/nm-connections.bak/"
        mkdir -p "${STATE_DIR}/nm-connections.bak"
        cp -a /etc/NetworkManager/system-connections/. "${STATE_DIR}/nm-connections.bak/" 2>/dev/null || true
        rm -f /etc/NetworkManager/system-connections/*.nmconnection 2>/dev/null || true
    fi

    log "INFO" "limpieza de stack previo completada"
}

# ---------------------------------------------------------------------------
# Configurar wpa_supplicant para una interfaz
# ---------------------------------------------------------------------------
configure_wpa() {
    local iface="$1" ssid="$2" psk_line="$3" bssid="${4:-}"
    local wpa_conf="/etc/wpa_supplicant/wpa_supplicant-${iface}.conf"

    backup_file "${wpa_conf}"

    cat > "${wpa_conf}" <<EOF
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=US
bgscan=""
scan_cur_freq=1

network={
    ssid="${ssid}"
    ${bssid:+bssid=${bssid}}
    ${psk_line}
    key_mgmt=WPA-PSK
    proto=RSN
    pairwise=CCMP
    group=CCMP
    priority=10
}
EOF
    chmod 600 "${wpa_conf}"
    log "INFO" "wpa_supplicant config escrita: ${wpa_conf}"
}

# ---------------------------------------------------------------------------
# Levantar wpa_supplicant como servicio systemd por interfaz
# ---------------------------------------------------------------------------
enable_wpa_service() {
    local iface="$1"
    systemctl unmask "wpa_supplicant@${iface}.service" 2>/dev/null || true
    systemctl enable "wpa_supplicant@${iface}.service"
    systemctl restart "wpa_supplicant@${iface}.service"
    sleep 2
    if ! systemctl is-active "wpa_supplicant@${iface}.service" >/dev/null 2>&1; then
        log "ERROR" "wpa_supplicant@${iface} no arrancó"
        journalctl -u "wpa_supplicant@${iface}.service" -n 20 --no-pager >&2
        die "fallo en wpa_supplicant — revisa el log anterior para el detalle exacto"
    fi
    log "INFO" "wpa_supplicant@${iface} activo y persistente"
}
