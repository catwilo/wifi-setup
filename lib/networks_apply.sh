# shellcheck shell=bash
# lib/networks_apply.sh -- regenerar perfiles NM + escribir .psk iwd.
# Requiere common.sh + nm.sh + radio.sh + networks_store.sh.

networks_sync() {
    if [[ ! -f "${NETWORKS_STORE}" ]]; then
        warn "networks: store no existe (${NETWORKS_STORE})"
        warn "corre primero: wifi networks merge"
        return 1
    fi

    local line ssid psk iface auto prio
    local applied=0 skipped=0
    local -a applied_names=()

    while IFS= read -r line; do
        _networks_row "$line"
        ssid="${_N_SSID}"; psk="${_N_PSK}"; iface="${_N_IFACE}"
        auto="${_N_AUTO}"; prio="${_N_PRIO}"
        [[ -n "${ssid}" && -n "${iface}" ]] || continue
        [[ "${auto}" == "yes" || "${auto}" == "no" ]] || auto="no"

        local profile="wifi-${iface}-${ssid}"

        # Verificar si el perfil existe y ya esta correcto.
        if nm_con_exists "${profile}"; then
            local cur_ssid cur_iface cur_psk cur_auto
            # head -1: si por un bug previo hay perfiles duplicados con el
            # mismo NAME, nmcli devuelve el valor una vez por perfil. Nos
            # quedamos con el primero; el resto se limpia en nm_wifi_create
            # (nm_con_delete por UUID).
            cur_ssid="$(nmcli -t -g 802-11-wireless.ssid con show "${profile}" 2>/dev/null | head -1 || true)"
            cur_iface="$(nm_con_get "${profile}" connection.interface-name 2>/dev/null | head -1 || true)"
            cur_psk="$(nmcli -s -t -g 802-11-wireless-security.psk con show "${profile}" 2>/dev/null | head -1 || true)"
            cur_auto="$(nm_con_get "${profile}" connection.autoconnect 2>/dev/null | head -1 || true)"

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
        applied_names+=("${profile}")
    done < <(_networks_store_rows)

    ok "networks: sync aplicado (${applied} creados/actualizados, ${skipped} sin cambios)"
    if [[ "${applied}" -gt 0 ]]; then
        info "perfiles aplicados:"
        local _n
        for _n in "${applied_names[@]}"; do
            printf '  + %s\n' "${_n}" >&2
        done
    fi
}

# ---------------------------------------------------------------------------
# networks_list -- reemplazo de wifi networks: tabla unificada store + NM.
# ---------------------------------------------------------------------------
_iwd_store_write() {
    local ssid="$1" psk="$2"
    # Si /var/lib/iwd no existe o no se puede crear, es un fallo real:
    # propagar 1 para que networks_apply_to_iwd NO cuente el SSID como
    # propagado. Un exito silencioso aqui enganaria al usuario.
    mkdir -p "${IWD_DIR}" 2>/dev/null || return 1
    local f="${IWD_DIR}/${ssid}.psk"
    printf '[Security]\nPassphrase=%s\n' "${psk}" > "${f}" 2>/dev/null || return 1
    chmod 600 "${f}" 2>/dev/null || true
    return 0
}

# networks_apply_to_iwd -- propaga la DB al store de iwd (una vez por SSID
# unico). Idempotente: reescribe los .psk con la PSK actual.
networks_apply_to_iwd() {
    [[ -d "${IWD_DIR}" ]] || return 0
    [[ -f "${NETWORKS_STORE}" ]] || return 0
    # _networks_row preserva psk vacio sin correr los campos siguientes.
    local line applied=0
    local -A seen=()
    while IFS= read -r line; do
        _networks_row "$line"
        [[ -n "${_N_SSID}" && -n "${_N_PSK}" ]] || continue
        [[ -n "${seen[${_N_SSID}]:-}" ]] && continue
        seen["${_N_SSID}"]=1
        _iwd_store_write "${_N_SSID}" "${_N_PSK}" && applied=$((applied + 1))
    done < <(_networks_store_rows)
    [[ "${applied}" -gt 0 ]] && info "iwd: ${applied} red(es) propagadas desde la DB"
    return 0
}

# networks_apply -- propaga la DB a NM (si corre) y a iwd. Un solo
# punto de entrada para los comandos que escriben.
networks_apply() {
    if systemctl is-active NetworkManager >/dev/null 2>&1; then
        networks_sync
    fi
    networks_apply_to_iwd
}


# ---------------------------------------------------------------------------
# Gestion avanzada de la DB (criticos: show, export/import, prune).
# ---------------------------------------------------------------------------

# networks_show <ssid> -- ficha completa del SSID.
# Muestra: PSK, filas por antena, prioridad, autoconnect, si el perfil
# existe en NM, y si el .psk existe en iwd. Una vista para diagnosticar
# sin correr 3 comandos.
