#!/usr/bin/env bash
# lib/forward.sh — configuración de IP estática, NAT e IP forwarding

# ---------------------------------------------------------------------------
# Asignar IP estática a una interfaz (sin DHCP)
# apply_static_ip <iface> <ip/prefix> [<gateway>]
# ---------------------------------------------------------------------------
apply_static_ip() {
    local iface="$1" cidr="$2" gw="${3:-}"

    # Bajar la interfaz limpiamente
    ip addr flush dev "${iface}" 2>/dev/null || true
    ip link set "${iface}" up

    ip addr add "${cidr}" dev "${iface}" \
        || die "no se pudo asignar ${cidr} a ${iface} — verifica que la interfaz exista: ip link show ${iface}"

    if [[ -n "${gw}" ]]; then
        # Eliminar ruta default previa si existe
        ip route del default 2>/dev/null || true
        ip route add default via "${gw}" dev "${iface}" \
            || die "no se pudo agregar ruta default via ${gw} — verifica que ${gw} sea alcanzable en ${iface}"
    fi

    log "INFO" "IP estática aplicada: ${iface} → ${cidr} gw=${gw:-none}"
}

# ---------------------------------------------------------------------------
# Habilitar IP forwarding (inmediato + persistente en sysctl.conf)
# ---------------------------------------------------------------------------
enable_ip_forward() {
    sysctl -w net.ipv4.ip_forward=1 >/dev/null \
        || die "no se pudo habilitar ip_forward — revisa permisos: sysctl net.ipv4.ip_forward"

    # Persistente: escribe o actualiza la línea en sysctl.conf
    local sysctl_conf="/etc/sysctl.d/99-wifi-setup-forward.conf"
    cat > "${sysctl_conf}" <<EOF
# wifi-setup: IP forwarding — generado automáticamente
net.ipv4.ip_forward = 1
EOF
    sysctl -p "${sysctl_conf}" >/dev/null
    log "INFO" "ip_forward habilitado y persistente (${sysctl_conf})"
}

# ---------------------------------------------------------------------------
# Instalar y persistir reglas iptables NAT MASQUERADE
# apply_nat <iface_upstream> <iface_plan>
# ---------------------------------------------------------------------------
apply_nat() {
    local upstream="$1" plan="$2"

    # Asegurar iptables-persistent instalado
    if ! command -v iptables-save >/dev/null 2>&1; then
        ensure_apt
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
            iptables iptables-persistent netfilter-persistent \
            || die "no se pudo instalar iptables-persistent — verifica conexión a internet y repositorios apt"
    fi

    # Limpiar reglas previas de este proyecto para idempotencia
    iptables -t nat -D POSTROUTING -o "${upstream}" -j MASQUERADE 2>/dev/null || true
    iptables -D FORWARD -i "${plan}" -o "${upstream}" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i "${upstream}" -o "${plan}" -m state \
        --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true

    # Aplicar reglas
    iptables -t nat -A POSTROUTING -o "${upstream}" -j MASQUERADE \
        || die "no se pudo crear regla NAT MASQUERADE en ${upstream} — verifica que iptables esté operativo"
    iptables -A FORWARD -i "${plan}" -o "${upstream}" -j ACCEPT \
        || die "no se pudo crear regla FORWARD ${plan}→${upstream}"
    iptables -A FORWARD -i "${upstream}" -o "${plan}" \
        -m state --state RELATED,ESTABLISHED -j ACCEPT \
        || die "no se pudo crear regla FORWARD estado RELATED,ESTABLISHED"

    # Persistir
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4 \
        || die "no se pudo guardar reglas iptables en /etc/iptables/rules.v4"

    systemctl enable netfilter-persistent 2>/dev/null || true
    log "INFO" "NAT MASQUERADE activo: ${plan} → ${upstream}, reglas persistidas"
}

# ---------------------------------------------------------------------------
# Configurar interfaz con systemd-networkd SOLO para IP estática persistente
# (usado en modo cliente — sin DHCP, sin fallback)
# write_networkd_static <iface> <ip/prefix> <gateway>
# ---------------------------------------------------------------------------
write_networkd_static() {
    local iface="$1" cidr="$2" gw="$3"
    local net_dir="/etc/systemd/network"
    mkdir -p "${net_dir}"

    cat > "${net_dir}/10-wifi-setup-${iface}.network" <<EOF
[Match]
Name=${iface}

[Network]
Address=${cidr}
Gateway=${gw}
DNS=1.1.1.1
DNS=8.8.8.8
EOF
    log "INFO" "networkd config estática escrita para ${iface}"
}

# ---------------------------------------------------------------------------
# Generar una MAC aleatoria con OUI de aspecto Windows (Dell/Intel/Realtek).
# suggest_windows_mac   → imprime una MAC nueva en stdout (no persiste)
# Las OUIs son unicast globales reales (2º bit del 1er octeto = 0), para que
# parezca de fábrica y no una MAC "local-admin" claramente falsa.
# ---------------------------------------------------------------------------
suggest_windows_mac() {
    local -a ouis=("00:1A:A0" "18:03:73" "00:16:EA" "00:24:21" "E0:CB:4E" \
                   "00:21:6A" "3C:97:0E" "B8:AC:6F" "00:1E:68" "00:26:B9")
    local oui="${ouis[$(( RANDOM % ${#ouis[@]} ))]}"
    printf '%s:%02x:%02x:%02x\n' "${oui}" \
        "$(( RANDOM % 256 ))" "$(( RANDOM % 256 ))" "$(( RANDOM % 256 ))" \
        | tr 'A-Z' 'a-z'
}

# ---------------------------------------------------------------------------
# Validar y normalizar una MAC. Imprime la MAC normalizada (lowercase, ':')
# en stdout y retorna 0 si es válida; retorna 1 si el formato es inválido.
# Avisa (a stderr) si es multicast o local-admin (aspecto "raro"/falso).
# validate_mac <mac>
# ---------------------------------------------------------------------------
validate_mac() {
    local raw="$1" mac
    # Normalizar: minúsculas, aceptar separador ':' o '-'
    mac="$(tr 'A-Z-' 'a-z:' <<<"${raw}")"
    # Formato estricto: 6 octetos hex separados por ':'
    if [[ ! "${mac}" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]]; then
        return 1
    fi
    # Primer octeto: bit0=multicast, bit1=local-admin
    local first="0x${mac%%:*}"
    if (( (first & 0x01) != 0 )); then
        log "WARN" "MAC ${mac} es MULTICAST (bit I/G) — inusual para una NIC, puede no levantar"
    fi
    if (( (first & 0x02) != 0 )); then
        log "WARN" "MAC ${mac} es de administración LOCAL — se ve aleatoria/falsa, no de fábrica"
    fi
    echo "${mac}"
}

# ---------------------------------------------------------------------------
# Obtener (o generar y persistir) la MAC para una interfaz.
# generate_persistent_mac <iface> [<mac_explicita>]
#   - con <mac_explicita>: valida, persiste y usa esa (sobrescribe)
#   - sin argumento: si ya hay archivo, lo reusa; si no, genera Windows-like
#   → imprime la MAC en stdout
# ---------------------------------------------------------------------------
generate_persistent_mac() {
    local iface="$1"
    local explicit="${2:-}"
    local mac_file="${STATE_DIR}/mac-${iface}.mac"
    local mac

    if [[ -n "${explicit}" ]]; then
        mac="$(validate_mac "${explicit}")" \
            || die "MAC inválida: '${explicit}' — formato esperado AA:BB:CC:DD:EE:FF"
        mkdir -p "${STATE_DIR}"
        echo "${mac}" > "${mac_file}"
        chmod 600 "${mac_file}"
        log "INFO" "MAC explícita persistida para ${iface}: ${mac} → ${mac_file}"
        echo "${mac}"
        return 0
    fi

    if [[ -f "${mac_file}" ]]; then
        cat "${mac_file}"
        return 0
    fi

    mac="$(suggest_windows_mac)"
    mkdir -p "${STATE_DIR}"
    echo "${mac}" > "${mac_file}"
    chmod 600 "${mac_file}"
    log "INFO" "MAC persistente generada para ${iface}: ${mac} → ${mac_file}"
    echo "${mac}"
}

# ---------------------------------------------------------------------------
# apply_persistent_mac_link <iface> [<mac_explicita>]
# Escribe un .link de systemd que fija la MAC Windows-like a nivel udev,
# aplicada en cada boot/hotplug ANTES de que dhcpcd pida lease. Persiste reboot.
# Match por permanent MAC real (sobrevive aunque el kernel renombre la iface).
# ---------------------------------------------------------------------------
apply_persistent_mac_link() {
    local iface="$1"
    local mac_explicita="${2:-}"
    local net_dir="/etc/systemd/network"
    mkdir -p "${net_dir}"

    local mac perm
    mac=$(generate_persistent_mac "${iface}" "${mac_explicita}")
    # MAC permanente de fábrica para el [Match] (estable ante renombrado).
    # Fuente nativa: 'permaddr' de ip link (persiste aunque la MAC actual ya
    # esté spoofeada). Fallbacks: ethtool si existe, luego address actual.
    perm=$(ip link show "${iface}" 2>/dev/null | grep -oE 'permaddr ([0-9a-f]{2}:){5}[0-9a-f]{2}' | awk '{print $2}')
    if [[ -z "${perm}" ]] && command -v ethtool >/dev/null 2>&1; then
        perm=$(ethtool -P "${iface}" 2>/dev/null | grep -oE '([0-9a-f]{2}:){5}[0-9a-f]{2}' | head -1)
    fi
    [[ -z "${perm}" ]] && perm=$(cat "/sys/class/net/${iface}/address" 2>/dev/null)

    local fixed_name
    if readlink -f "/sys/class/net/${iface}/device" 2>/dev/null | grep -q "/usb"; then
        fixed_name="wlx"
    else
        fixed_name="wlan0"
    fi
    cat > "${net_dir}/10-wifi-setup-${fixed_name}.link" <<EOF
# wifi-setup — MAC persistente Windows-like (aplicada por udev)
# Generado automáticamente — no editar a mano
[Match]
PermanentMACAddress=${perm}

[Link]
MACAddress=${mac}
Name=${fixed_name}
EOF
    log "INFO" "MAC link escrito: ${iface} perm=${perm} -> ${mac}"

    # Aplicar YA en caliente (sin esperar reboot)
    ip link set "${iface}" down 2>/dev/null || true
    ip addr flush dev "${iface}" 2>/dev/null || true
    ip link set "${iface}" address "${mac}" 2>/dev/null \
        || log "WARN" "no se pudo aplicar MAC ${mac} en caliente a ${iface}"
    ip link set "${iface}" up 2>/dev/null || true
    sleep 1
}

# ---------------------------------------------------------------------------
# setup_upstream_dhcpcd <iface> [<mac_explicita>]
# Configura el upstream para que dhcpcd tome subred+gateway REALES del AP,
# con MAC persistente vía .link. La IP la asigna el AP (subred/gateway reales).
# No asume .1 ni subred fija. Idempotente.
# ---------------------------------------------------------------------------
setup_upstream_dhcpcd() {
    local iface="$1"
    local mac_explicita="${2:-}"

    # 0. dhcpcd es el gestor del upstream: asegurar que NO esté enmascarado
    #    (corridas viejas del modelo networkd lo enmascaraban).
    systemctl unmask dhcpcd 2>/dev/null || true
    systemctl enable dhcpcd 2>/dev/null || true

    # 1. MAC persistente (via .link + en caliente)
    apply_persistent_mac_link "${iface}" "${mac_explicita}"

    # 2. Limpiar config networkd vieja del proyecto en esta iface (modelo viejo)
    rm -f "/etc/systemd/network/10-wifi-setup-${iface}.network"

    # 3. Comentar cualquier static viejo en dhcpcd.conf (IP/gateway hardcodeados)
    if [[ -f /etc/dhcpcd.conf ]]; then
        cp -a /etc/dhcpcd.conf "/etc/dhcpcd.conf.wifisetup.bak" 2>/dev/null || true
        # Comenta líneas static dentro del bloque de esta interfaz
        sed -i "/^interface ${iface}/,/^interface /{/^static /s/^/#wifisetup /}" /etc/dhcpcd.conf 2>/dev/null || true
        # Caso último bloque del archivo (sin 'interface' siguiente)
        sed -i "/^static ip_address=/s/^/#wifisetup /;/^static routers=/s/^/#wifisetup /" /etc/dhcpcd.conf 2>/dev/null || true
    fi

    # 4. Matar dhcpcd zombies que defiendan IPs viejas
    dhcpcd -k "${iface}" 2>/dev/null || true
    ip addr flush dev "${iface}" 2>/dev/null || true
    sleep 1
    dhcpcd "${iface}" 2>/dev/null || true

    log "INFO" "upstream ${iface} configurado vía dhcpcd (subred/gateway reales del AP)"
}


# ---------------------------------------------------------------------------
# Mostrar MAC y IP actuales de la interfaz upstream (diagnóstico rápido)
# show_upstream_config <iface>
# ---------------------------------------------------------------------------
show_upstream_config() {
    local iface="$1"
    local mac_file="${STATE_DIR}/mac-${iface}.mac"

    echo ""
    echo "=== Configuración upstream: ${iface} ==="
    echo "  MAC persistente : $(cat "${mac_file}" 2>/dev/null || echo '(no generada aún)')"
    echo "  MAC actual      : $(ip link show "${iface}" 2>/dev/null | awk '/ether/{print $2}' || echo 'interfaz no disponible')"
    echo "  IP actual       : $(ip addr show "${iface}" 2>/dev/null | awk '/inet /{print $2}' | head -1 || echo 'sin IP')"
    echo "  Estado          : $(ip link show "${iface}" 2>/dev/null | awk '/^[0-9]+:/{print $3}' | tr -d '<>' || echo 'desconocido')"
    echo ""
}

# ---------------------------------------------------------------------------
# Cambiar la MAC de una interfaz EN CALIENTE, persistente y con auto-rollback.
# set_mac_hot <iface> <mac|random|windows>
#   - 'random'/'windows' → genera una Windows-like nueva
#   - <mac>              → valida y usa esa
# Procedimiento sin romper nada:
#   1. Resolver MAC objetivo (validada)
#   2. Guardar MAC actual para rollback
#   3. Reescribir el .network ([Match]/[Link]) con la nueva MAC + persistir mac file
#   4. down → ip link set address → up → networkd reload/restart
#   5. Esperar IP + verificar internet; si falla, revertir todo
# ---------------------------------------------------------------------------
set_mac_hot() {
    local iface="$1" arg="$2"
    local mac_file="${STATE_DIR}/mac-${iface}.mac"
    local net_file="/etc/systemd/network/10-wifi-setup-${iface}.network"

    # 1. Resolver MAC objetivo
    local new_mac
    case "${arg}" in
        random|windows|RANDOM|WINDOWS)
            new_mac="$(suggest_windows_mac)"
            log "INFO" "MAC generada (Windows-like): ${new_mac}"
            ;;
        *)
            new_mac="$(validate_mac "${arg}")" \
                || die "MAC inválida: '${arg}' — formato AA:BB:CC:DD:EE:FF"
            ;;
    esac

    # 2. Estado previo para rollback
    local old_mac old_net_backup
    old_mac="$(ip link show "${iface}" 2>/dev/null | awk '/ether/{print $2}')"
    [[ -n "${old_mac}" ]] || die "no se pudo leer la MAC actual de ${iface}"
    old_net_backup=""
    if [[ -f "${net_file}" ]]; then
        old_net_backup="$(mktemp /tmp/wifisetup.netbak.XXXXXX)"
        cp -a "${net_file}" "${old_net_backup}"
    fi
    local old_mac_file_existed=0
    [[ -f "${mac_file}" ]] && old_mac_file_existed=1
    local prev_persisted=""
    [[ "${old_mac_file_existed}" -eq 1 ]] && prev_persisted="$(cat "${mac_file}")"

    log "INFO" "cambiando MAC de ${iface}: ${old_mac} → ${new_mac}"

    # 3. Persistir nueva MAC + reescribir .network si existe (preservar IP/gw)
    mkdir -p "${STATE_DIR}"
    echo "${new_mac}" > "${mac_file}"
    chmod 600 "${mac_file}"

    if [[ -f "${net_file}" ]]; then
        # Sustituir cualquier línea MACAddress= por la nueva (en [Match] y [Link])
        sed -i "s/^MACAddress=.*/MACAddress=${new_mac}/" "${net_file}"
    fi

    # 4. Aplicar en caliente
    local restored_ip
    restored_ip="$(ip addr show "${iface}" 2>/dev/null | awk '/inet /{print $2}' | head -1)"
    ip link set "${iface}" down 2>/dev/null || true
    if ! ip link set "${iface}" address "${new_mac}" 2>/dev/null; then
        log "ERROR" "el driver/interfaz rechazó la MAC ${new_mac} — revirtiendo"
        ip link set "${iface}" address "${old_mac}" 2>/dev/null || true
        ip link set "${iface}" up 2>/dev/null || true
        [[ -n "${old_net_backup}" ]] && cp -f "${old_net_backup}" "${net_file}"
        if [[ "${old_mac_file_existed}" -eq 1 ]]; then
            echo "${prev_persisted}" > "${mac_file}"
        else
            rm -f "${mac_file}"
        fi
        rm -f "${old_net_backup}" 2>/dev/null || true
        die "no se pudo aplicar la MAC en ${iface} (rollback hecho)"
    fi
    ip link set "${iface}" up
    systemctl restart systemd-networkd 2>/dev/null || true

    # 5. Verificar conectividad; rollback si falla
    log "INFO" "verificando conectividad tras cambio de MAC (máx 25s)..."
    local waited=0 ok=0
    while [[ "${waited}" -lt 25 ]]; do
        if ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; then ok=1; break; fi
        sleep 5; (( waited += 5 )) || true
    done

    if [[ "${ok}" -eq 1 ]]; then
        rm -f "${old_net_backup}" 2>/dev/null || true
        log "INFO" "MAC cambiada y verificada: ${iface} → ${new_mac} (persistente)"
        show_upstream_config "${iface}"
        echo "ok: MAC de ${iface} ahora es ${new_mac} — persistente y con internet"
        return 0
    fi

    # Rollback completo
    log "WARN" "sin internet tras el cambio — revirtiendo a ${old_mac}..."
    ip link set "${iface}" down 2>/dev/null || true
    ip link set "${iface}" address "${old_mac}" 2>/dev/null || true
    ip link set "${iface}" up 2>/dev/null || true
    if [[ -n "${old_net_backup}" ]]; then
        cp -f "${old_net_backup}" "${net_file}"
    fi
    if [[ "${old_mac_file_existed}" -eq 1 ]]; then
        echo "${prev_persisted}" > "${mac_file}"
    else
        rm -f "${mac_file}"
    fi
    rm -f "${old_net_backup}" 2>/dev/null || true
    systemctl restart systemd-networkd 2>/dev/null || true
    sleep 3
    die "el cambio de MAC dejó la interfaz sin internet — se revirtió a ${old_mac}"
}

