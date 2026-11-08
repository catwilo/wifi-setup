# shellcheck shell=bash
# lib/networks_pull.sh -- leer NM/iwd y fundir al store (aditivo).
# Requiere common.sh + nm.sh + radio.sh + networks_store.sh.

networks_pull_nm() {
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
    local line
    while IFS= read -r line; do
        _networks_row "$line"
        [[ -n "${_N_SSID}" && -n "${_N_IFACE}" ]] || continue
        old_auto["${_N_SSID}|${_N_IFACE}"]="${_N_AUTO}"
        old_prio["${_N_SSID}|${_N_IFACE}"]="${_N_PRIO}"
    done < <(_networks_store_rows)

    # 3. Agrupar por SSID. PSK: la mas reciente en el archivo NM gana.
    #    Guardar un mapa: ssid -> psk ganadora, y ssid -> ifaces con valores.
    declare -A ssid_psk=()
    declare -A ssid_iface_auto=()
    declare -A ssid_iface_prio=()
    declare -A ssid_seen=()

    local _line
    while IFS= read -r _line; do
        _networks_row "$_line"
        [[ -n "${_N_SSID}" && -n "${_N_IFACE}" ]] || continue
        if [[ -n "${_N_PSK}" ]]; then
            ssid_psk["${_N_SSID}"]="${_N_PSK}"
        fi
        ssid_iface_auto["${_N_SSID}|${_N_IFACE}"]="${_N_AUTO}"
        ssid_iface_prio["${_N_SSID}|${_N_IFACE}"]="${_N_PRIO}"
        ssid_seen["${_N_SSID}"]=1
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
                    a="${old_auto[${s}|${i}]:-yes}"
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
    count="$(grep -cv '^#' "${NETWORKS_STORE}" 2>/dev/null || true)"
    count="${count:-0}"
    ok "networks: store actualizado (${count} filas en ${NETWORKS_STORE})"
}

# ---------------------------------------------------------------------------
# networks_sync -- regenera perfiles NM WiFi desde el store (idempotente).
# No borra perfiles NM que no esten en el store; solo crea/actualiza.
# ---------------------------------------------------------------------------
_iwd_ssid_from_filename() {
    local base="$1"
    base="${base%.psk}"
    printf '%b' "${base}"
}

# _iwd_psk_for_ssid <ssid> -- Passphrase del .psk, o vacio si no existe.
_iwd_psk_for_ssid() {
    local ssid="$1" f
    f="${IWD_DIR}/${ssid}.psk"
    [[ -r "$f" ]] || return 1
    sed -n 's/^Passphrase=//p' "$f"
}

# networks_pull_iwd -- agrega a la DB las redes que iwd conoce y la
# DB no tiene. Aditivo: nunca borra ni reemplaza PSK existentes. Crea una
# fila por (ssid, iface) para cada antena WiFi presente.
networks_pull_iwd() {
    local iwd_dir="${IWD_DIR}"
    [[ -d "$iwd_dir" ]] || {
        info "networks: iwd no tiene store (${iwd_dir} ausente)"
        return 0
    }
    # /var/lib/iwd es root-only: sin sudo el glob no matchea y el for no
    # itera, lo que se ve como "no hay redes" (mentira). Diferenciar
    # no-listable de vacio para no reportar exito falso.
    if [[ ! -r "$iwd_dir" ]]; then
        warn "networks: ${iwd_dir} no es legible sin root -- import omitido"
        warn "           corre este comando con sudo: sudo wifi networks import-iwd"
        return 1
    fi

    _networks_store_init
    local ts; ts="$(date +%s)"

    # SSIDs ya en la DB (no tocar).
    declare -A in_db=()
    local line _s _p _i _r
    while IFS= read -r line; do
        IFS=$'\t' read -r _s _p _i _r <<< "${line}"
        [[ -n "${_s}" ]] && in_db["${_s}"]=1
    done < <(_networks_store_rows)

    # Antenas WiFi presentes. Lectura directa del kernel (o del override
    # IWD_IFACES_CMD, para tests). Esta funcion corre durante fallback_off
    # ANTES de arrancar NM, asi que no puede depender de nmcli/radio_ifaces.
    local -a ifaces=()
    local _w _if
    if [[ -n "${IWD_IFACES_CMD:-}" ]]; then
        while IFS= read -r _if; do
            [[ -n "${_if}" ]] && ifaces+=("${_if}")
        done < <(eval "${IWD_IFACES_CMD}")
    else
        for _w in /sys/class/net/*/wireless; do
            [[ -d "${_w}" ]] || continue
            _if="${_w%/wireless}"; _if="${_if##*/}"
            [[ -n "${_if}" ]] && ifaces+=("${_if}")
        done
    fi
    if [[ "${#ifaces[@]}" -eq 0 ]]; then
        warn "networks: no hay antenas WiFi -- import desde iwd omitido"
        return 0
    fi

    local f ssid psk added=0
    for f in "$iwd_dir"/*.psk; do
        [[ -e "$f" ]] || continue
        ssid="$(_iwd_ssid_from_filename "$(basename "$f")")"
        [[ -n "${ssid}" ]] || continue
        [[ -n "${in_db[${ssid}]:-}" ]] && continue
        psk="$(_iwd_psk_for_ssid "${ssid}" || true)"

        for _if in "${ifaces[@]}"; do
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
                "${ssid}" "${psk}" "${_if}" "yes" "0" "${ts}" \
                >> "${NETWORKS_STORE}"
            added=$((added + 1))
        done
        in_db["${ssid}"]=1
    done

    if [[ "${added}" -gt 0 ]]; then
        ok "networks: ${added} fila(s) importadas desde iwd"
    else
        info "networks: iwd no tiene redes nuevas para importar"
    fi
}


# ---------------------------------------------------------------------------
# Escritura en la DB y propagacion a los dos backends.
# La DB (networks.tsv) es la fuente de verdad; NM e iwd son caches.
# ---------------------------------------------------------------------------

# _networks_store_upsert <ssid> <psk> <iface> [<auto>] [<prio>]
# Agrega o actualiza la fila (ssid, iface). Preserva otras filas del mismo
# SSID (distintas ifaces). Idempotente: si la fila ya existe, la reemplaza.
