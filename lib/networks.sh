#!/usr/bin/env bash
# lib/networks.sh -- store central de redes WiFi (fuente unica de verdad).
#
# RESPONSABILIDAD UNICA: mantener un archivo TSV con todas las redes
# conocidas, sin importar de que antena vinieron, y regenerar los
# perfiles NM por antena desde ese store.
#
# MODELO:
#   - networks.tsv: <ssid>\t<psk>\t<iface>\t<autoconnect>\t<priority>\t<updated>
#   - Una fila por (ssid, iface). El mismo SSID puede existir en varias
#     antenas con distinta prioridad y autoconnect.
#   - La PSK se guarda UNA vez por SSID (no por iface). Si el store tiene
#     PSK nueva, se propaga a todas las filas del mismo SSID.
#
# COMANDOS:
#   networks_merge   lee TODOS los perfiles NM WiFi y los funde al store.
#                    Aditivo: nunca borra, siempre agrega o actualiza.
#                    Si un SSID solo estaba en una antena, agrega filas
#                    para las otras con autoconnect=no, priority=0.
#   networks_sync    regenera perfiles NM desde el store (idempotente).
#
# LIMITACION: SSID y PSK no deben contener TAB ni newline. En la practica
# ninguno de los dos los tiene.
#
# Requiere: common.sh + nm.sh + radio.sh cargados antes.

NETWORKS_STORE="${STATE_DIR}/networks.tsv"

# ---------------------------------------------------------------------------
# Helpers de IO
# ---------------------------------------------------------------------------

# _networks_store_init -- crea el store vacio con cabecera si no existe.
_networks_store_init() {
    if [[ ! -f "${NETWORKS_STORE}" ]]; then
        mkdir -p "$(dirname "${NETWORKS_STORE}")"
        {
            printf '# wifi-setup network store -- generado por wifi networks merge\n'
            printf '# ssid\tpsk\tiface\tautoconnect\tpriority\tupdated\n'
        } > "${NETWORKS_STORE}"
        chmod 600 "${NETWORKS_STORE}"
    fi
}

# _networks_store_rows -- imprime todas las filas de datos (sin comentarios).
_networks_store_rows() {
    [[ -f "${NETWORKS_STORE}" ]] || return 0
    grep -v '^#' "${NETWORKS_STORE}" | grep -v '^[[:space:]]*$'
}

# _networks_psk_for_ssid <ssid> -- busca la PSK del SSID en el store.
_networks_psk_for_ssid() {
    local ssid="$1" line _ssid _psk _rest
    while IFS= read -r line; do
        IFS=$'\t' read -r _ssid _psk _rest <<< "${line}"
        if [[ "${_ssid}" == "${ssid}" && -n "${_psk}" ]]; then
            echo "${_psk}"
            return 0
        fi
    done < <(_networks_store_rows)
    return 1
}

# ---------------------------------------------------------------------------
# networks_merge -- funde los perfiles NM actuales al store (aditivo).
#
# Reglas:
#   - Para cada perfil NM WiFi: (ssid, iface, autoconnect, priority, psk).
#   - Agrupa por ssid. La PSK mas reciente (por orden de aparicion) gana.
#   - Genera una fila por (ssid, iface) para cada iface WiFi presente.
#     Si un SSID estaba solo en wlan0, agrega la fila para wlx1 con
#     autoconnect=no, priority=0 -- nunca pierde informacion.
#   - Los valores previos de autoconnect/priority por (ssid, iface) se
#     preservan del store viejo si existen.
# ---------------------------------------------------------------------------
networks_merge() {
    _networks_store_init

    local ts; ts="$(date +%s)"

    # 1. Leer todos los perfiles NM WiFi -> filas (ssid, iface, auto, prio, psk)
    #    en archivos temporales para procesar.
    local tmp_nm; tmp_nm="$(mktemp "${TMPDIR:-/tmp}/wifi-nm.XXXXXX")"
    local tmp_out; tmp_out="$(mktemp "${TMPDIR:-/tmp}/wifi-out.XXXXXX")"

    local name type ssid psk iface auto prio
    while IFS= read -r name; do
        [[ -n "${name}" ]] || continue
        type="$(nm_con_get "${name}" connection.type)"
        [[ "${type}" == "802-11-wireless" ]] || continue

        ssid="$(nmcli -t -g 802-11-wireless.ssid con show "${name}" 2>/dev/null || true)"
        [[ -n "${ssid}" ]] || continue

        psk="$(nmcli -s -t -g 802-11-wireless-security.psk con show "${name}" 2>/dev/null || true)"

        iface="$(nm_con_get "${name}" connection.interface-name)"
        auto="$(nm_con_get "${name}" connection.autoconnect)"
        prio="$(nm_con_get "${name}" connection.autoconnect-priority)"

        # Si el perfil no tiene iface fija, usar la activa si esta conectado.
        if [[ -z "${iface}" ]]; then
            iface="$(nmcli -t -f DEVICE,CONNECTION dev status 2>/dev/null \
                | awk -F: -v c="${name}" '$2==c {print $1; exit}')"
        fi
        [[ -n "${iface}" ]] || continue

        printf '%s\t%s\t%s\t%s\t%s\n' \
            "${ssid}" "${psk:-}" "${iface}" "${auto:-yes}" "${prio:-0}" \
            >> "${tmp_nm}"
    done < <(nmcli -t -f NAME con show 2>/dev/null)

    # 2. Cargar el store viejo en memoria (mapa (ssid,iface) -> auto,prio)
    #    para preservar valores existentes.
    declare -A old_auto=()
    declare -A old_prio=()
    local line _ssid _psk _iface _auto _prio
    while IFS= read -r line; do
        IFS=$'\t' read -r _ssid _psk _iface _auto _prio _rest <<< "${line}"
        [[ -n "${_ssid}" && -n "${_iface}" ]] || continue
        old_auto["${_ssid}|${_iface}"]="${_auto}"
        old_prio["${_ssid}|${_iface}"]="${_prio}"
    done < <(_networks_store_rows)

    # 3. Agrupar por SSID. PSK: la mas reciente en el archivo NM gana.
    #    Guardar un mapa: ssid -> psk ganadora, y ssid -> ifaces con valores.
    declare -A ssid_psk=()
    declare -A ssid_iface_auto=()
    declare -A ssid_iface_prio=()
    declare -A ssid_seen=()

    while IFS=$'\t' read -r ssid psk iface auto prio; do
        [[ -n "${ssid}" && -n "${iface}" ]] || continue
        # PSK: la primera no-vacia que aparezca gana (los perfiles se leen
        # en orden estable; el ultimo que escriba es el mas reciente).
        if [[ -n "${psk}" ]]; then
            ssid_psk["${ssid}"]="${psk}"
        fi
        ssid_iface_auto["${ssid}|${iface}"]="${auto}"
        ssid_iface_prio["${ssid}|${iface}"]="${prio}"
        ssid_seen["${ssid}"]=1
    done < "${tmp_nm}"

    # 4. Todas las ifaces WiFi presentes en el sistema.
    local -a all_ifaces=()
    while IFS= read -r _iface; do
        [[ -n "${_iface}" ]] && all_ifaces+=("${_iface}")
    done < <(radio_ifaces)

    # 5. Emitir filas: por cada ssid visto, por cada iface conocida.
    {
        printf '# wifi-setup network store -- generado por wifi networks merge\n'
        printf '# ssid\tpsk\tiface\tautoconnect\tpriority\tupdated\n'

        local s i a p psk_use
        for s in "${!ssid_seen[@]}"; do
            psk_use="${ssid_psk[$s]:-}"
            for i in "${all_ifaces[@]}"; do
                [[ -n "${i}" ]] || continue
                # auto y prio: preferir el valor del NM actual; si no,
                # el del store viejo; si no, default conservador.
                a="${ssid_iface_auto[${s}|${i}]:-}"
                if [[ -z "${a}" ]]; then
                    a="${old_auto[${s}|${i}]:-no}"
                fi
                p="${ssid_iface_prio[${s}|${i}]:-}"
                if [[ -z "${p}" ]]; then
                    p="${old_prio[${s}|${i}]:-0}"
                fi
                printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
                    "${s}" "${psk_use}" "${i}" "${a}" "${p}" "${ts}"
            done
        done
    } > "${tmp_out}"

    # 6. Reemplazo atomico.
    mv "${tmp_out}" "${NETWORKS_STORE}"
    chmod 600 "${NETWORKS_STORE}"
    rm -f "${tmp_nm}"

    local count
    count="$(grep -cv '^#' "${NETWORKS_STORE}" 2>/dev/null)"
    count="${count:-0}"
    ok "networks: store actualizado (${count} filas en ${NETWORKS_STORE})"
}

# ---------------------------------------------------------------------------
# networks_sync -- regenera perfiles NM WiFi desde el store (idempotente).
# No borra perfiles NM que no esten en el store; solo crea/actualiza.
# ---------------------------------------------------------------------------
networks_sync() {
    if [[ ! -f "${NETWORKS_STORE}" ]]; then
        warn "networks: store no existe (${NETWORKS_STORE})"
        warn "corre primero: wifi networks merge"
        return 1
    fi

    local line ssid psk iface auto prio _ts
    local applied=0 skipped=0

    while IFS= read -r line; do
        IFS=$'\t' read -r ssid psk iface auto prio _ts <<< "${line}"
        [[ -n "${ssid}" && -n "${iface}" ]] || continue
        [[ "${auto}" == "yes" || "${auto}" == "no" ]] || auto="no"

        local profile="wifi-${iface}-${ssid}"

        # Verificar si el perfil existe y ya esta correcto.
        if nm_con_exists "${profile}"; then
            local cur_ssid cur_iface cur_psk cur_auto
            cur_ssid="$(nmcli -t -g 802-11-wireless.ssid con show "${profile}" 2>/dev/null || true)"
            cur_iface="$(nm_con_get "${profile}" connection.interface-name)"
            cur_psk="$(nmcli -s -t -g 802-11-wireless-security.psk con show "${profile}" 2>/dev/null || true)"
            cur_auto="$(nm_con_get "${profile}" connection.autoconnect)"

            if [[ "${cur_ssid}" == "${ssid}" \
                  && "${cur_iface}" == "${iface}" \
                  && ( -z "${psk}" || "${cur_psk}" == "${psk}" ) \
                  && "${cur_auto}" == "${auto}" ]]; then
                nm_con_set_priority "${profile}" "${prio}" >/dev/null 2>&1 || true
                skipped=$((skipped + 1))
                continue
            fi
        fi

        if [[ -n "${psk}" ]]; then
            nm_wifi_create "${profile}" "${iface}" "${ssid}" "${psk}" >/dev/null 2>&1 || {
                warn "networks: no se pudo crear/actualizar ${profile}"
                continue
            }
        else
            # Sin PSK: recrear como perfil abierto o pedir a NM que lo arme.
            nmcli con add type wifi con-name "${profile}" \
                ifname "${iface}" ssid "${ssid}" >/dev/null 2>&1 || {
                warn "networks: no se pudo crear ${profile} (sin PSK)"
                continue
            }
        fi
        nm_con_set_autoconnect "${profile}" "${auto}" >/dev/null 2>&1 || true
        nm_con_set_priority "${profile}" "${prio}" >/dev/null 2>&1 || true
        applied=$((applied + 1))
    done < <(_networks_store_rows)

    ok "networks: sync aplicado (${applied} creados/actualizados, ${skipped} sin cambios)"
}

# ---------------------------------------------------------------------------
# networks_list -- reemplazo de wifi networks: tabla unificada store + NM.
# ---------------------------------------------------------------------------
networks_list() {
    _networks_store_init

    local _nrows=0
    if [[ -f "${NETWORKS_STORE}" ]]; then
        _nrows="$(grep -cv '^#' "${NETWORKS_STORE}" 2>/dev/null)"
        _nrows="${_nrows:-0}"
    fi
    if [[ ! -f "${NETWORKS_STORE}" ]] || [[ "${_nrows}" -eq 0 ]]; then
        echo "(store vacio -- corre: wifi networks merge)"
        return 0
    fi

    printf '%-24s %-16s %-12s %-10s %s\n' \
        "SSID" "IFACE" "AUTOCONNECT" "PRIORITY" "PERFIL NM"
    printf '%s\n' "--------------------------------------------------------------------------------"

    local line ssid psk iface auto prio _ts profile exists
    while IFS= read -r line; do
        IFS=$'\t' read -r ssid psk iface auto prio _ts <<< "${line}"
        [[ -n "${ssid}" && -n "${iface}" ]] || continue
        profile="wifi-${iface}-${ssid}"
        if nm_con_exists "${profile}"; then
            exists="si"
        else
            exists="NO"
        fi
        printf '%-24s %-16s %-12s %-10s %s\n' \
            "${ssid}" "${iface}" "${auto}" "${prio}" "${exists}"
    done < <(_networks_store_rows)
}
