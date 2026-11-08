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
