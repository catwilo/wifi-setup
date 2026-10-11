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
# radio_use <iface> -- solo sesion, no persiste.
# ---------------------------------------------------------------------------
radio_use() {
    local iface="${1:-}"
    [[ -n "${iface}" ]] || die "uso: wifi radio use <iface>"
    radio_is_iface "${iface}" || die "'${iface}' no es una interfaz WiFi"

    mkdir -p "${STATE_DIR}"
    printf 'SESSION_OVERRIDE="%s"\n' "${iface}" > "${RADIO_SESSION_FILE}"
    chmod 600 "${RADIO_SESSION_FILE}"
    ok "uso en esta sesion: ${iface} (no persiste)"
}

# ---------------------------------------------------------------------------
# radio_clear_session -- olvida el override de sesion.
# ---------------------------------------------------------------------------
radio_clear_session() {
    rm -f "${RADIO_SESSION_FILE}"
    ok "override de sesion eliminado"
}

# ---------------------------------------------------------------------------
# _radio_iface_con <iface> -- imprime el nombre del perfil activo en iface.
# ---------------------------------------------------------------------------
_radio_iface_con() {
    local iface="$1"
    nm_dev_wifi_list | awk -F: -v i="${iface}" '$1==i {print $4}'
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
