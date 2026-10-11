#!/usr/bin/env bash
# lib/radio.sh -- gestion de antenas WiFi (nativa + USB externa).
#
# RESPONSABILIDAD UNICA: enumerar antenas, definir su rol (primary/
# secondary), subirlas/bajarlas, y persistir las decisiones entre
# reinicios.
#
# MODELO:
#   - El equipo tiene 2 antenas WiFi: una nativa (wlan0) y una USB (wlx*).
#   - Cada antena puede tener su propio perfil NM con su propia red.
#   - Ambas pueden estar conectadas simultaneamente a redes distintas.
#   - PRIMARY/SECONDARY solo controla la PRIORIDAD de ruta cuando ambas
#     tienen internet; no impide que la otra este activa.
#   - Cambio persistente (sobrevive reboot): wifi radio primary <iface>
#     Cambio de sesion (solo ahora):            wifi radio use <iface>
#   - Up/down individuales: wifi radio up|down <iface> [--persist]
#
# Persistencia: STATE_DIR/radio.state con RADIO_PRIMARY/RADIO_SECONDARY.
# Sesion:      STATE_DIR/radio.session con SESSION_OVERRIDE.
#
# Requiere: common.sh + nm.sh + log.sh cargados antes.

RADIO_STATE_FILE="${STATE_DIR}/radio.state"
RADIO_SESSION_FILE="${STATE_DIR}/radio.session"
RADIO_PRIO_PRIMARY=100
RADIO_PRIO_SECONDARY=50

# ---------------------------------------------------------------------------
# _radio_load_state -- carga RADIO_PRIMARY/RADIO_SECONDARY del state.
# ---------------------------------------------------------------------------
_radio_load_state() {
    RADIO_PRIMARY=""
    RADIO_SECONDARY=""
    [[ -f "${RADIO_STATE_FILE}" ]] || return 0
    # shellcheck source=/dev/null
    source "${RADIO_STATE_FILE}"
}

# _radio_save_state -- persiste RADIO_PRIMARY/RADIO_SECONDARY.
_radio_save_state() {
    mkdir -p "${STATE_DIR}"
    cat > "${RADIO_STATE_FILE}" <<EOF
RADIO_PRIMARY="${RADIO_PRIMARY}"
RADIO_SECONDARY="${RADIO_SECONDARY}"
EOF
    chmod 600 "${RADIO_STATE_FILE}"
}

# _radio_load_session -- carga SESSION_OVERRIDE (iface preferida en sesion).
_radio_load_session() {
    SESSION_OVERRIDE=""
    [[ -f "${RADIO_SESSION_FILE}" ]] || return 0
    # shellcheck source=/dev/null
    source "${RADIO_SESSION_FILE}"
}

# ---------------------------------------------------------------------------
# radio_ifaces -- lista interfaces WiFi conocidas por NM.
# ---------------------------------------------------------------------------
radio_ifaces() {
    nm_dev_wifi_list | awk -F: '{print $1}'
}

# radio_is_iface <iface> -- 0 si es WiFi.
radio_is_iface() {
    local iface="$1"
    nm_dev_wifi_list | awk -F: '{print $1}' | grep -qxF "${iface}"
}

# radio_is_usb <iface> -- 0 si es USB (path en /sys tiene /usb).
radio_is_usb() {
    local iface="$1"
    local path; path="$(readlink -f "/sys/class/net/${iface}" 2>/dev/null || true)"
    [[ "${path}" == *"/usb"* ]]
}

# radio_autodetect_roles -- asigna PRIMARY=USB, SECONDARY=nativa.
# Convencion: la USB es la antena de trabajo (mejor control, reemplazable),
# la nativa es la de respaldo (siempre presente).
radio_autodetect_roles() {
    local iface
    RADIO_PRIMARY=""
    RADIO_SECONDARY=""

    while IFS= read -r iface; do
        [[ -n "${iface}" ]] || continue
        if radio_is_usb "${iface}"; then
            [[ -z "${RADIO_PRIMARY}" ]] && RADIO_PRIMARY="${iface}"
        else
            [[ -z "${RADIO_SECONDARY}" ]] && RADIO_SECONDARY="${iface}"
        fi
    done < <(radio_ifaces)

    # Fallback: si solo hay una antena, es PRIMARY.
    if [[ -z "${RADIO_PRIMARY}" && -n "${RADIO_SECONDARY}" ]]; then
        RADIO_PRIMARY="${RADIO_SECONDARY}"
        RADIO_SECONDARY=""
    fi
}

# ---------------------------------------------------------------------------
# radio_sync_priorities -- aplica los valores de prioridad a los perfiles
# WiFi segun los roles actuales. Los perfiles WiFi activos de la antena
# PRIMARY reciben prioridad alta, los de SECONDARY baja.
# ---------------------------------------------------------------------------
radio_sync_priorities() {
    _radio_load_state
    local iface name dev prio

    while IFS=: read -r name _uuid _type dev; do
        [[ "${_type}" == "802-11-wireless" ]] || continue
        [[ -n "${dev}" ]] || continue

        if [[ "${dev}" == "${RADIO_PRIMARY}" ]]; then
            prio="${RADIO_PRIO_PRIMARY}"
        elif [[ "${dev}" == "${RADIO_SECONDARY}" ]]; then
            prio="${RADIO_PRIO_SECONDARY}"
        else
            continue
        fi

        nm_con_set_priority "${name}" "${prio}"
    done < <(nm_con_list)

    info "prioridades aplicadas: primary=${RADIO_PRIMARY:-none} secondary=${RADIO_SECONDARY:-none}"
}

# ---------------------------------------------------------------------------
# radio_list -- imprime tabla de antenas con rol y estado.
# ---------------------------------------------------------------------------
radio_list() {
    nm_require
    _radio_load_state
    _radio_load_session

    printf '%-20s %-8s %-12s %-20s %s\n' \
        "IFACE" "TIPO" "ESTADO" "CONEXION" "ROL"
    printf '%s\n' "------------------------------------------------------------------------"

    local iface state conn rol tipo
    while IFS=: read -r iface _type state conn; do
        [[ -n "${iface}" ]] || continue
        if radio_is_usb "${iface}"; then
            tipo="USB"
        else
            tipo="nativa"
        fi

        rol=""
        [[ "${iface}" == "${RADIO_PRIMARY}"   ]] && rol="primary"
        [[ "${iface}" == "${RADIO_SECONDARY}" ]] && rol="secondary"
        [[ "${iface}" == "${SESSION_OVERRIDE:-}" ]] && rol="${rol:+${rol}+}session"

        printf '%-20s %-8s %-12s %-20s %s\n' \
            "${iface}" "${tipo}" "${state}" "${conn:-—}" "${rol:-—}"
    done < <(nm_dev_wifi_list)
}

# ---------------------------------------------------------------------------
# radio_set_primary <iface> -- persistente.
# ---------------------------------------------------------------------------
radio_set_primary() {
    local iface="${1:-}"
    [[ -n "${iface}" ]] || die "uso: wifi radio primary <iface>"
    radio_is_iface "${iface}" || die "'${iface}' no es una interfaz WiFi"

    _radio_load_state
    if [[ "${iface}" == "${RADIO_SECONDARY}" ]]; then
        RADIO_SECONDARY="${RADIO_PRIMARY}"
    fi
    RADIO_PRIMARY="${iface}"
    _radio_save_state
    radio_sync_priorities
    ok "PRIMARY persistente: ${iface} (secondary=${RADIO_SECONDARY:-none})"
}

# ---------------------------------------------------------------------------
# radio_set_secondary <iface> -- persistente.
# ---------------------------------------------------------------------------
radio_set_secondary() {
    local iface="${1:-}"
    [[ -n "${iface}" ]] || die "uso: wifi radio secondary <iface>"
    radio_is_iface "${iface}" || die "'${iface}' no es una interfaz WiFi"

    _radio_load_state
    if [[ "${iface}" == "${RADIO_PRIMARY}" ]]; then
        RADIO_PRIMARY="${RADIO_SECONDARY}"
    fi
    RADIO_SECONDARY="${iface}"
    _radio_save_state
    radio_sync_priorities
    ok "SECONDARY persistente: ${iface} (primary=${RADIO_PRIMARY:-none})"
}

# ---------------------------------------------------------------------------
# radio_use <iface> [--persist]
# Deja SOLO esta antena encendida y apaga la otra. Sin --persist, el
# cambio no sobrevive reboot; con --persist, autoconnect queda ON en
# esta y OFF en la otra.
# ---------------------------------------------------------------------------
radio_use() {
    local iface="${1:-}" persist=0
    shift || true
    for a in "$@"; do [[ "${a}" == "--persist" ]] && persist=1; done
    [[ -n "${iface}" ]] || die "uso: wifi radio use <iface> [--persist]"
    radio_is_iface "${iface}" || die "'${iface}' no es una interfaz WiFi"

    # Orden correcto para no cortar el acceso remoto:
    #   1. Encender la nueva.
    #   2. Esperar a que tenga IP (hasta 45s).
    #   3. Solo entonces apagar la vieja.
    # Si la nueva no llega a conectar, no se toca la vieja.

    local -a _up_args=("${iface}")
    [[ "${persist}" -eq 1 ]] && _up_args+=(--persist)
    info "encendiendo ${iface} (sin tocar las demas)..."
    radio_up "${_up_args[@]}"

    info "esperando IP en ${iface} (max 45s)..."
    local waited=0 ip=""
    while [[ "${waited}" -lt 45 ]]; do
        ip="$(ip -4 -o addr show "${iface}" 2>/dev/null \
            | awk '{print $4}' | head -1)"
        [[ -n "${ip}" ]] && break
        sleep 3
        waited=$((waited + 3))
    done
    if [[ -z "${ip}" ]]; then
        warn "${iface} no obtuvo IP tras 45s -- no se apaga ninguna otra antena"
        warn "revisa: wifi doctor"
        return 1
    fi
    ok "${iface} con IP ${ip}"

    # Ahora apagar la vieja (o las viejas).
    local other
    while IFS= read -r other; do
        [[ -n "${other}" ]] || continue
        [[ "${other}" == "${iface}" ]] && continue
        # No apagar si todavia no esta conectada la nueva.
        local -a _down_args=("${other}")
        [[ "${persist}" -eq 1 ]] && _down_args+=(--persist)
        info "apagando ${other}..."
        radio_down "${_down_args[@]}"
    done < <(radio_ifaces)

    if [[ "${persist}" -eq 1 ]]; then
        mkdir -p "${STATE_DIR}"
        printf 'SESSION_OVERRIDE="%s"\n' "${iface}" > "${RADIO_SESSION_FILE}"
        chmod 600 "${RADIO_SESSION_FILE}"
        ok "solo ${iface} activa, persistente"
    else
        ok "solo ${iface} activa (no persiste -- reboot vuelve a config previa)"
    fi
}

# ---------------------------------------------------------------------------
# radio_clear_session -- olvida el override de sesion.
# ---------------------------------------------------------------------------
radio_clear_session() {
    rm -f "${RADIO_SESSION_FILE}"
    ok "override de sesion eliminado"
}

# ---------------------------------------------------------------------------
# _radio_iface_con <iface> -- imprime el nombre del perfil WiFi asociado
# a la iface. Busca entre todos los perfiles por connection.interface-name;
# si no encuentra, cae al perfil activo del device (compatibilidad).
# ---------------------------------------------------------------------------
_radio_iface_con() {
    local iface="$1"
    local n iname active

    # Perfil activo del device (si esta conectado).
    active="$(nmcli -t -f DEVICE,CONNECTION dev status 2>/dev/null \
        | awk -F: -v i="${iface}" '$1==i && $2!="" {print $2; exit}')"
    if [[ -n "${active}" ]]; then
        echo "${active}"
        return 0
    fi

    # Buscar por interface-name en todos los perfiles WiFi.
    while IFS= read -r n; do
        [[ -n "${n}" ]] || continue
        iname="$(nmcli -t -g connection.interface-name con show "${n}" 2>/dev/null || true)"
        if [[ "${iname}" == "${iface}" ]]; then
            echo "${n}"
            return 0
        fi
    done < <(nmcli -t -f NAME,TYPE con show 2>/dev/null \
        | awk -F: '$2=="802-11-wireless"{print $1}')
    return 1
}

# ---------------------------------------------------------------------------
# radio_up <iface> [--persist]
# Activa el perfil WiFi activo de esa antena.
# ---------------------------------------------------------------------------
radio_up() {
    local iface="${1:-}" persist=0
    shift || true
    for a in "$@"; do [[ "${a}" == "--persist" ]] && persist=1; done
    [[ -n "${iface}" ]] || die "uso: wifi radio up <iface> [--persist]"
    radio_is_iface "${iface}" || die "'${iface}' no es una interfaz WiFi"

    local con; con="$(_radio_iface_con "${iface}")"
    [[ -n "${con}" ]] || die "no hay conexion WiFi asociada a ${iface} -- corre 'wifi add <ssid> ${iface}' primero"

    nm_con_up "${con}"

    if [[ "${persist}" -eq 1 ]]; then
        nm_con_set_autoconnect "${con}" on
        ok "autoconnect ON persistente: ${con}"
    fi
}

# ---------------------------------------------------------------------------
# radio_down <iface> [--persist]
# ---------------------------------------------------------------------------
radio_down() {
    local iface="${1:-}" persist=0
    shift || true
    for a in "$@"; do [[ "${a}" == "--persist" ]] && persist=1; done
    [[ -n "${iface}" ]] || die "uso: wifi radio down <iface> [--persist]"
    radio_is_iface "${iface}" || die "'${iface}' no es una interfaz WiFi"

    local con; con="$(_radio_iface_con "${iface}")"
    [[ -n "${con}" ]] || { warn "${iface} ya esta inactiva"; return 0; }

    nm_con_down "${con}"

    if [[ "${persist}" -eq 1 ]]; then
        nm_con_set_autoconnect "${con}" off
        ok "autoconnect OFF persistente: ${con}"
    fi
}

# ---------------------------------------------------------------------------
# Inventario fisico de antenas WiFi.
# ---------------------------------------------------------------------------

# _radio_kernel_ifaces -- lista ifaces WiFi presentes en el kernel, no en NM.
# Una iface WiFi tiene /sys/class/net/<iface>/wireless/ o phy80211.
_radio_kernel_ifaces() {
    local p iface
    for p in /sys/class/net/*/wireless; do
        [[ -d "${p}" ]] || continue
        iface="${p%/wireless}"
        echo "${iface##*/}"
    done | sort -u
}

# _radio_bus_of <iface> -- imprime PCI|USB|? segun el path del device.
_radio_bus_of() {
    local iface="$1"
    local path
    path="$(readlink -f "/sys/class/net/${iface}/device" 2>/dev/null || true)"
    case "${path}" in
        *"/usb"*)  echo "USB" ;;
        *"/pci"*)  echo "PCI" ;;
        "")        echo "?" ;;
        *)         echo "?" ;;
    esac
}

# _radio_driver_of <iface> -- imprime el driver de red real.
# USB WiFi expone varias interfaces; la de red es la que no es usb/hub/btusb.
_radio_driver_of() {
    local iface="$1"
    local ifdir="/sys/class/net/${iface}/device"
    local sub driver

    if [[ -d "${ifdir}" ]]; then
        for sub in "${ifdir}"/*/driver; do
            [[ -L "${sub}" ]] || continue
            driver="$(basename "$(readlink -f "${sub}" 2>/dev/null)" 2>/dev/null)"
            case "${driver}" in
                usb|hub|btusb|"") continue ;;
            esac
            echo "${driver}"
            return 0
        done
    fi

    driver="$(basename "$(readlink -f "${ifdir}/driver" 2>/dev/null)" 2>/dev/null)"
    echo "${driver:-?}"
}

# _radio_permanent_mac_of <iface> -- MAC de fabrica (permaddr) o la actual.
_radio_permanent_mac_of() {
    local iface="$1"
    local perm
    perm="$(ip link show "${iface}" 2>/dev/null \
        | grep -oE 'permaddr [0-9a-f:]+' | awk '{print $2}' | head -1)"
    if [[ -z "${perm}" ]]; then
        perm="$(cat "/sys/class/net/${iface}/address" 2>/dev/null || echo "?")"
    fi
    echo "${perm}"
}

# _radio_kernel_state_of <iface> -- UP|DOWN|? segun el kernel.
_radio_kernel_state_of() {
    local iface="$1"
    local state
    state="$(cat "/sys/class/net/${iface}/operstate" 2>/dev/null || echo "?")"
    case "${state}" in
        up)              echo "UP" ;;
        down|dormant)    echo "DOWN" ;;
        *)               echo "${state}" ;;
    esac
}

# _radio_nm_state_of <iface> -- estado en NM + perfil, o "no en NM".
_radio_nm_state_of() {
    local iface="$1"
    if ! nmcli -t -f DEVICE,TYPE dev status 2>/dev/null \
            | awk -F: -v i="${iface}" '$1==i && $2=="wifi"{found=1} END{exit !found}'; then
        echo "no en NM"
        return 0
    fi
    local state conn
    state="$(nmcli -t -f DEVICE,STATE dev status 2>/dev/null \
        | awk -F: -v i="${iface}" '$1==i {print $2}')"
    conn="$(nmcli -t -f DEVICE,CONNECTION dev status 2>/dev/null \
        | awk -F: -v i="${iface}" '$1==i {print $2}')"
    if [[ -n "${conn}" ]]; then
        echo "${state} (${conn})"
    else
        echo "${state}"
    fi
}

# radio_ifaces_list -- tabla: inventario fisico completo (kernel + NM).
radio_ifaces_list() {
    nm_require

    printf '%-10s %-5s %-16s %-20s %-8s %s\n' \
        "IFACE" "BUS" "DRIVER" "MAC PERMANENTE" "KERNEL" "NM"
    printf '%s\n' "--------------------------------------------------------------------------------"

    local iface bus driver mac kstate nstate found_any=0
    while IFS= read -r iface; do
        [[ -n "${iface}" ]] || continue
        found_any=1
        bus="$(_radio_bus_of "${iface}")"
        driver="$(_radio_driver_of "${iface}")"
        mac="$(_radio_permanent_mac_of "${iface}")"
        kstate="$(_radio_kernel_state_of "${iface}")"
        nstate="$(_radio_nm_state_of "${iface}")"
        printf '%-10s %-5s %-16s %-20s %-8s %s\n' \
            "${iface}" "${bus}" "${driver}" "${mac}" "${kstate}" "${nstate}"
    done < <(_radio_kernel_ifaces)

    if [[ "${found_any}" -eq 0 ]]; then
        warn "no se detecto ninguna antena WiFi en el kernel"
        warn "verifica: ls /sys/class/net/*/wireless, lsusb, lspci"
        return 1
    fi
}

