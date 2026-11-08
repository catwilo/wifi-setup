# shellcheck shell=bash
# lib/radio_roles.sh -- PRIMARY/SECONDARY/session, list, apply_autoconnect.
# Requiere common.sh + nm.sh + networks.sh + radio_state.sh.

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
# radio_apply_autoconnect -- alinea autoconnect con el rol actual.
#
# PRIMARY -> todos sus perfiles WiFi en autoconnect=yes.
# SECONDARY -> todos sus perfiles WiFi en autoconnect=no.
#
# El rol es la unica palanca automatica sobre autoconnect. Ningun otro
# subcomando lo escribe. El override manual del usuario es
# `wifi autoconnect set <perfil> on|off`; ese valor persiste hasta el
# proximo cambio de rol. Para usar un SSID de SECONDARY ahora:
# `wifi connect <ssid> <iface>` funciona igual (nm_device_connect ignora
# autoconnect=no).
# ---------------------------------------------------------------------------
radio_apply_autoconnect() {
    _radio_load_state
    local primary="${RADIO_PRIMARY:-}" secondary="${RADIO_SECONDARY:-}"
    [[ -n "${primary}" || -n "${secondary}" ]] || return 0

    local n iface target applied=0
    while IFS= read -r n; do
        [[ -n "${n}" ]] || continue
        iface="$(nm_con_get "${n}" connection.interface-name 2>/dev/null | head -1 || true)"
        [[ -n "${iface}" ]] || continue
        target=""
        [[ "${iface}" == "${primary}"   ]] && target="yes"
        [[ "${iface}" == "${secondary}" ]] && target="no"
        [[ -n "${target}" ]] || continue
        nm_con_set_autoconnect "${n}" "${target}" >/dev/null 2>&1 || continue
        applied=$((applied + 1))
    done < <(nmcli -t -f NAME,TYPE con show 2>/dev/null \
        | awk -F: '$2=="802-11-wireless"{print $1}')
    info "autoconnect: ${applied} perfil(es) alineados (primary=${primary:-none} secondary=${secondary:-none})"
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
    radio_apply_autoconnect
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
    radio_apply_autoconnect
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

    # Sin carrier check previo: una antena apagada por software (SECONDARY)
    # esta DOWN con NO-CARRIER, pero sigue siendo capaz de escanear y
    # conectarse. Bloquearla impedia usar radio use para encenderla.
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
        warn "revisa: wifi status"
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
        # Con --persist, la iface elegida pasa a ser la unica activa: se
        # promueve a PRIMARY y la otra pasa a SECONDARY (o se limpia).
        local _other
        RADIO_SECONDARY=""
        while IFS= read -r _other; do
            [[ -n "${_other}" && "${_other}" != "${iface}" ]] || continue
            RADIO_SECONDARY="${_other}"
            break
        done < <(radio_ifaces)
        RADIO_PRIMARY="${iface}"
        _radio_save_state
        radio_apply_autoconnect
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


# _radio_db_set_autoconnect <ssid> <iface> <yes|no>
# Actualiza la DB para que networks_sync no revierta el cambio aplicado
# a NM. No-op si la fila no existe en la DB (el perfil no esta gestionado).
_radio_db_set_autoconnect() {
    local ssid="$1" iface="$2" mode="$3"
    [[ -f "${NETWORKS_STORE}" ]] || return 0
    local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/wifi-tsv.XXXXXX")"
    grep '^#' "${NETWORKS_STORE}" > "${tmp}" || true
    local _s _p _i _a _pr _ts _changed=0
    while IFS= read -r _line; do
        IFS=$'\t' read -r _s _p _i _a _pr _ts <<< "${_line}"
        if [[ "${_s}" == "${ssid}" && "${_i}" == "${iface}" ]]; then
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
                "${_s}" "${_p}" "${_i}" "${mode}" "${_pr}" "$(date +%s)" >> "${tmp}"
            _changed=1
        else
            printf '%s\n' "${_line}" >> "${tmp}"
        fi
    done < <(_networks_store_rows)
    mv "${tmp}" "${NETWORKS_STORE}"
    chmod 600 "${NETWORKS_STORE}"
    return 0
}

