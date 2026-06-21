#!/usr/bin/env bash
# lib/net.sh  deteccin de interfaces y limpieza de stack de red previo

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
        [[ "${iface}" =~ ^(lo|docker|virbr|veth|br-) ]] && continue
        echo "${iface}"
        return 0
    done
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
# Detectar qu stack de red est activo
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
# ---------------------------------------------------------------------------
purge_network_stack() {
    log "INFO" "detectando y limpiando stack de red previo..."

    local services=(
        NetworkManager
        NetworkManager-wait-online
        iwd
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

    rm -f /var/lib/dhcp/dhclient*.leases 2>/dev/null || true
    rm -f /var/lib/dhcpcd/*.lease 2>/dev/null || true

    if [[ -d /etc/NetworkManager/system-connections ]]; then
        log "INFO" "backup de conexiones NM previas  ${STATE_DIR}/nm-connections.bak/"
        mkdir -p "${STATE_DIR}/nm-connections.bak"
        cp -a /etc/NetworkManager/system-connections/. "${STATE_DIR}/nm-connections.bak/" 2>/dev/null || true
        rm -f /etc/NetworkManager/system-connections/*.nmconnection 2>/dev/null || true
    fi

    log "INFO" "limpieza de stack previo completada"
}

# ---------------------------------------------------------------------------
# Helpers internos: bloques network={} dentro de un wpa_supplicant-<iface>.conf
# Cada bloque se identifica por su linea ssid="...". KISS: texto plano, sin
# parser real -- suficiente porque el formato lo generamos nosotros mismos.
# ---------------------------------------------------------------------------
_wpa_conf_path() {
    echo "/etc/wpa_supplicant/wpa_supplicant-$1.conf"
}

_wpa_conf_header() {
    cat <<'EOF'
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=US
bgscan=""
scan_cur_freq=1
EOF
}

# wpa_network_exists <iface> <ssid>  ->  0 si ya hay un bloque para ese ssid
wpa_network_exists() {
    local iface="$1" ssid="$2" conf
    conf="$(_wpa_conf_path "${iface}")"
    [[ -f "${conf}" ]] || return 1
    grep -q "ssid=\"${ssid}\"" "${conf}"
}

# _wpa_extract_other_blocks <conf> <ssid_to_exclude>
# Imprime todos los bloques network={} cuyo ssid NO sea el indicado.
_wpa_extract_other_blocks() {
    local conf="$1" exclude_ssid="$2"
    [[ -f "${conf}" ]] || return 0
    awk -v exclude="ssid=\"${exclude_ssid}\"" '
        /^network=\{/ { buf=$0 "\n"; in_block=1; skip=0; next }
        in_block {
            buf = buf $0 "\n"
            if ($0 ~ exclude) skip=1
            if ($0 ~ /^\}/) {
                if (!skip) printf "%s", buf
                in_block=0; buf=""
            }
            next
        }
    ' "${conf}"
}

# configure_wpa <iface> <ssid> <psk_line> <bssid>
# Crea el archivo si no existe. Si existe, preserva todos los demas bloques
# network={} y solo reemplaza (o agrega) el del ssid dado.
configure_wpa() {
    local iface="$1" ssid="$2" psk_line="$3" bssid="${4:-}"
    local conf
    conf="$(_wpa_conf_path "${iface}")"

    backup_file "${conf}"

    local new_block
    new_block="$(cat <<EOF
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
)"

    {
        _wpa_conf_header
        echo ""
        if [[ -f "${conf}" ]]; then
            _wpa_extract_other_blocks "${conf}" "${ssid}"
        fi
        echo "${new_block}"
    } > "${conf}.new"

    chmod 600 "${conf}.new"
    mv -f "${conf}.new" "${conf}"
    log "INFO" "wpa_supplicant config actualizada (red '${ssid}'): ${conf}"
}

# remove_wpa_network <iface> <ssid>  -- borra solo ese bloque, preserva el resto
remove_wpa_network() {
    local iface="$1" ssid="$2" conf
    conf="$(_wpa_conf_path "${iface}")"
    [[ -f "${conf}" ]] || { log "WARN" "no existe config para ${iface}"; return 1; }
    wpa_network_exists "${iface}" "${ssid}" || { log "WARN" "ssid '${ssid}' no estaba en ${conf}"; return 1; }

    backup_file "${conf}"
    {
        _wpa_conf_header
        echo ""
        _wpa_extract_other_blocks "${conf}" "${ssid}"
    } > "${conf}.new"
    chmod 600 "${conf}.new"
    mv -f "${conf}.new" "${conf}"
    log "INFO" "red '${ssid}' eliminada de ${conf}"
}

# set_wpa_disabled <iface> <ssid> <on|off>
# on = permitir autoconnect (quita disabled=1). off = deshabilitar (agrega disabled=1).
set_wpa_disabled() {
    local iface="$1" ssid="$2" mode="$3" conf
    conf="$(_wpa_conf_path "${iface}")"
    wpa_network_exists "${iface}" "${ssid}" \
        || { log "ERROR" "ssid '${ssid}' no encontrado en ${conf}"; return 1; }

    backup_file "${conf}"

    case "${mode}" in
        off)
            awk -v target="ssid=\"${ssid}\"" '
                /^network=\{/ { print; in_block=1; matched=0; next }
                in_block && $0 ~ target { matched=1; print; next }
                in_block && /^\}/ {
                    if (matched) print "    disabled=1"
                    print; in_block=0; next
                }
                { print }
            ' "${conf}" > "${conf}.new"
            ;;
        on)
            awk -v target="ssid=\"${ssid}\"" '
                /^network=\{/ { print; in_block=1; matched=0; next }
                in_block && $0 ~ target { matched=1; print; next }
                in_block && matched && /disabled=1/ { next }
                in_block && /^\}/ { print; in_block=0; next }
                { print }
            ' "${conf}" > "${conf}.new"
            ;;
        *)
            log "ERROR" "modo invalido: ${mode} (usa on|off)"; return 1 ;;
    esac

    chmod 600 "${conf}.new"
    mv -f "${conf}.new" "${conf}"
    log "INFO" "autoconnect '${ssid}' -> ${mode}"
}

# set_wpa_freqlist <iface> <ssid> <freq_list_string>
# freq_list_string: frecuencias separadas por espacio, ej "2412 2417 2422"
set_wpa_freqlist() {
    local iface="$1" ssid="$2" freqs="$3" conf
    conf="$(_wpa_conf_path "${iface}")"
    wpa_network_exists "${iface}" "${ssid}" \
        || { log "ERROR" "ssid '${ssid}' no encontrado en ${conf}"; return 1; }

    backup_file "${conf}"
    awk -v target="ssid=\"${ssid}\"" -v freqs="${freqs}" '
        /^network=\{/ { print; in_block=1; matched=0; next }
        in_block && $0 ~ target { matched=1; print; next }
        in_block && matched && /freq_list=/ { next }
        in_block && matched && /^\}/ {
            print "    freq_list=" freqs
            print; in_block=0; next
        }
        in_block && /^\}/ { print; in_block=0; next }
        { print }
    ' "${conf}" > "${conf}.new"

    chmod 600 "${conf}.new"
    mv -f "${conf}.new" "${conf}"
    log "INFO" "freq_list de '${ssid}' -> ${freqs}"
}

# scan_ssid_frequencies <iface> <ssid>
# Escanea e imprime, separadas por espacio, las frecuencias (MHz) vistas
# para ese ssid exacto. Vacio si no se vio nada.
scan_ssid_frequencies() {
    local iface="$1" ssid="$2"
    iw dev "${iface}" scan 2>/dev/null \
        | awk -v target="SSID: ${ssid}" '
            /^BSS / { freq="" }
            /freq:/ { freq=$2 }
            $0 ~ target && freq != "" { print freq; freq="" }
        ' | sort -u | tr '\n' ' ' | sed 's/ $//'
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
        log "ERROR" "wpa_supplicant@${iface} no arranc"
        journalctl -u "wpa_supplicant@${iface}.service" -n 20 --no-pager >&2
        die "fallo en wpa_supplicant  revisa el log anterior para el detalle exacto"
    fi
    log "INFO" "wpa_supplicant@${iface} activo y persistente"
}
