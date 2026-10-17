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
    # Una sola pasada con awk: descarta comentarios y lineas vacias.
    # Con grep en pipe + pipefail, "grep -v" devuelve 1 cuando no hay
    # lineas que filtrar y mata el script bajo set -e. awk no tiene
    # ese problema: no matchear es exito.
    awk '!/^#/ && !/^[[:space:]]*$/' "${NETWORKS_STORE}"
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
    count="$(grep -cv '^#' "${NETWORKS_STORE}" 2>/dev/null || true)"
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
    local -a applied_names=()

    while IFS= read -r line; do
        IFS=$'\t' read -r ssid psk iface auto prio _ts <<< "${line}"
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
networks_list() {
    _networks_store_init

    local _nrows=0
    if [[ -f "${NETWORKS_STORE}" ]]; then
        _nrows="$(grep -cv '^#' "${NETWORKS_STORE}" 2>/dev/null || true)"
        _nrows="${_nrows:-0}"
    fi
    if [[ ! -f "${NETWORKS_STORE}" ]] || [[ "${_nrows}" -eq 0 ]]; then
        echo "(store vacio -- corre: wifi networks merge)"
        return 0
    fi

    printf '%-24s %-10s %-6s %-6s %-6s %-6s\n' \
        "SSID" "IFACE" "AUTO" "PRIO" "NM" "IWD"
    printf '%s\n' "--------------------------------------------------------------------------"

    local line ssid psk iface auto prio _ts profile
    local nm_ok iwd_ok
    while IFS= read -r line; do
        IFS=$'\t' read -r ssid psk iface auto prio _ts <<< "${line}"
        [[ -n "${ssid}" && -n "${iface}" ]] || continue
        profile="wifi-${iface}-${ssid}"
        if nm_con_exists "${profile}" 2>/dev/null; then nm_ok="si"; else nm_ok="NO"; fi
        if [[ -r "${IWD_DIR}/${ssid}.psk" ]]; then iwd_ok="si"; else iwd_ok="NO"; fi
        printf '%-24s %-10s %-6s %-6s %-6s %-6s\n' \
            "${ssid}" "${iface}" "${auto}" "${prio}" "${nm_ok}" "${iwd_ok}"
    done < <(_networks_store_rows)
}

# ---------------------------------------------------------------------------
# iwd -- SOLO LECTURA. wifi-setup no gestiona iwd: el usuario lo maneja
# manual con iwctl. Pero cuando iwd conoce una red que la DB no tiene, se
# importa a la DB para que al volver a NM exista el perfil equivalente con
# la misma PSK. iwd nunca se modifica desde aca.
# ---------------------------------------------------------------------------

# Directorio del store de iwd. Override por env para tests.
IWD_DIR="${IWD_DIR:-/var/lib/iwd}"

# _iwd_ssid_from_filename <basename> -- reconstruye el SSID desde el nombre
# del archivo .psk. iwd escapa no-printables como \xHH; printf %b los
# decodifica. '_' (escape de '/') se deja como esta -- SSIDs reales con
# '/' son virtualmente inexistentes.
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

# networks_import_from_iwd -- agrega a la DB las redes que iwd conoce y la
# DB no tiene. Aditivo: nunca borra ni reemplaza PSK existentes. Crea una
# fila por (ssid, iface) para cada antena WiFi presente.
networks_import_from_iwd() {
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
_networks_store_upsert() {
    local ssid="$1" psk="$2" iface="$3" auto="${4:-yes}" prio="${5:-0}"
    local ts; ts="$(date +%s)"
    _networks_store_init
    local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/wifi-tsv.XXXXXX")"
    grep '^#' "${NETWORKS_STORE}" > "${tmp}" || true
    awk -F'\t' -v s="${ssid}" -v p="${psk}" -v i="${iface}" -v a="${auto}" \
        -v pr="${prio}" -v u="${ts}" '
        BEGIN { OFS="\t"; found=0 }
        /^#/ { next }
        NF < 3 { next }
        $1==s && $3==i { print s,p,i,a,pr,u; found=1; next }
        { print }
        END { if (!found) print s,p,i,a,pr,u }
    ' "${NETWORKS_STORE}" >> "${tmp}"
    mv "${tmp}" "${NETWORKS_STORE}"
    chmod 600 "${NETWORKS_STORE}"
}

# _networks_store_delete <ssid> -- quita todas las filas del SSID.
_networks_store_delete() {
    local ssid="$1"
    [[ -f "${NETWORKS_STORE}" ]] || return 0
    local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/wifi-tsv.XXXXXX")"
    awk -F'\t' -v s="${ssid}" '
        /^#/ { print; next }
        $1==s { next }
        { print }
    ' "${NETWORKS_STORE}" > "${tmp}"
    mv "${tmp}" "${NETWORKS_STORE}"
    chmod 600 "${NETWORKS_STORE}"
}

# _iwd_store_write <ssid> <psk> -- escribe /var/lib/iwd/<ssid>.psk.
# Solo toca el archivo de ese SSID; no toca el resto del store de iwd.
_iwd_store_write() {
    local ssid="$1" psk="$2"
    mkdir -p "${IWD_DIR}" 2>/dev/null || return 0
    local f="${IWD_DIR}/${ssid}.psk"
    printf '[Security]\nPassphrase=%s\n' "${psk}" > "${f}" 2>/dev/null || return 1
    chmod 600 "${f}" 2>/dev/null || true
}

# networks_apply_to_iwd -- propaga la DB al store de iwd (una vez por SSID
# unico). Idempotente: reescribe los .psk con la PSK actual.
networks_apply_to_iwd() {
    [[ -d "${IWD_DIR}" ]] || return 0
    [[ -f "${NETWORKS_STORE}" ]] || return 0
    declare -A seen=()
    local line ssid psk _if _auto _prio _ts
    local applied=0
    while IFS= read -r line; do
        IFS=$'\t' read -r ssid psk _if _auto _prio _ts <<< "${line}"
        [[ -n "${ssid}" && -n "${psk}" ]] || continue
        [[ -n "${seen[${ssid}]:-}" ]] && continue
        seen["${ssid}"]=1
        _iwd_store_write "${ssid}" "${psk}" && applied=$((applied + 1))
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
networks_show() {
    local ssid="$1"
    [[ -f "${NETWORKS_STORE}" ]] || { warn "DB vacia -- corre: wifi networks merge"; return 1; }

    local line _s _p _i _a _pr _ts
    local psk="" found=0
    local -a rows=()
    while IFS= read -r line; do
        IFS=$'\t' read -r _s _p _i _a _pr _ts <<< "${line}"
        [[ "${_s}" == "${ssid}" ]] || continue
        found=1
        [[ -n "${psk}" ]] || psk="${_p}"
        rows+=("${_i}"$'\t'"${_a}"$'\t'"${_pr}")
    done < <(_networks_store_rows)

    if [[ "${found}" -eq 0 ]]; then
        warn "SSID '${ssid}' no esta en la DB"
        return 1
    fi

    echo "SSID: ${ssid}"
    echo "PSK : ${psk:-<sin PSK>}"
    echo ""
    printf '  %-10s %-8s %-6s %-8s %-6s\n' "IFACE" "AUTO" "PRIO" "NM" "IWD"
    local _if _auto _prio nm_ok iwd_ok
    for row in "${rows[@]}"; do
        IFS=$'\t' read -r _if _auto _prio <<< "${row}"
        if nm_con_exists "wifi-${_if}-${ssid}" 2>/dev/null; then nm_ok="si"; else nm_ok="NO"; fi
        if [[ -r "${IWD_DIR}/${ssid}.psk" ]]; then iwd_ok="si"; else iwd_ok="NO"; fi
        printf '  %-10s %-8s %-6s %-8s %-6s\n' "${_if}" "${_auto}" "${_prio}" "${nm_ok}" "${iwd_ok}"
    done
}

# networks_export <path> -- copia la DB a <path>. Preserva permisos.
networks_export() {
    local path="$1"
    [[ -n "${path}" ]] || { err "uso: networks_export <path>"; return 1; }
    [[ -f "${NETWORKS_STORE}" ]] || { err "DB no existe -- corre: wifi networks merge"; return 1; }
    cp -f "${NETWORKS_STORE}" "${path}" || { err "no se pudo exportar a ${path}"; return 1; }
    chmod 600 "${path}" 2>/dev/null || true
    ok "DB exportada a ${path} ($(wc -l < "${path}") lineas)"
}

# networks_import <path> -- merge desde <path>. Aditivo: no borra filas
# existentes; solo agrega las que no estan (por (ssid, iface)).
networks_import() {
    local path="$1"
    [[ -n "${path}" ]] || { err "uso: networks_import <path>"; return 1; }
    [[ -r "${path}" ]] || { err "archivo no legible: ${path}"; return 1; }
    _networks_store_init

    local out; out="$(mktemp "${TMPDIR:-/tmp}/wifi-tsv.XXXXXX")"

    # Un solo awk: lee la DB actual (FNR==NR) y el archivo a importar.
    # Emite todo (DB actual) + solo las (ssid, iface) nuevas del archivo.
    # Portable: split por TAB con -F'\t'. Escribe a <out>.
    awk -F'\t' '
        FNR==NR {
            print
            if ($0 !~ /^#/ && NF>=3) seen[$1"\x1f"$3]=1
            next
        }
        /^#/ { next }
        NF<3 { next }
        !($1"\x1f"$3 in seen) {
            print
            seen[$1"\x1f"$3]=1
            added++
        }
        END { printf "%d", added+0 > "/dev/stderr" }
    ' "${NETWORKS_STORE}" "${path}" > "${out}" 2> "${out}.n"

    local added
    added="$(cat "${out}.n" 2>/dev/null || echo 0)"
    mv "${out}" "${NETWORKS_STORE}"
    rm -f "${out}.n"
    chmod 600 "${NETWORKS_STORE}"
    ok "DB importada desde ${path} (${added} fila(s) nuevas)"
}

# networks_prune -- elimina filas del TSV cuyo SSID ya no existe en ningun
# backend (ni perfil NM ni .psk en iwd). Con confirmacion explicita.
networks_prune() {
    [[ -f "${NETWORKS_STORE}" ]] || { warn "DB vacia"; return 0; }
    local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/wifi-tsv.XXXXXX")"
    grep '^#' "${NETWORKS_STORE}" > "${tmp}" || true

    local line _s _p _i _a _pr _ts
    local kept=0 dropped=0
    local -a drop_list=()
    while IFS= read -r line; do
        IFS=$'\t' read -r _s _p _i _a _pr _ts <<< "${line}"
        [[ -n "${_s}" && -n "${_i}" ]] || continue
        local has_nm=0 has_iwd=0
        if nm_con_exists "wifi-${_i}-${_s}" 2>/dev/null; then has_nm=1; fi
        if [[ -r "${IWD_DIR}/${_s}.psk" ]]; then has_iwd=1; fi
        if [[ "${has_nm}" -eq 1 || "${has_iwd}" -eq 1 ]]; then
            printf '%s\n' "${line}" >> "${tmp}"
            kept=$((kept + 1))
        else
            drop_list+=("${_s} (${_i})")
            dropped=$((dropped + 1))
        fi
    done < <(_networks_store_rows)

    if [[ "${dropped}" -eq 0 ]]; then
        info "nada que podar (${kept} fila(s) validas)"
        rm -f "${tmp}"
        return 0
    fi

    echo "filas huerfanas a eliminar (${dropped}):"
    local d
    for d in "${drop_list[@]}"; do
        printf '  - %s\n' "${d}"
    done
    read -r -p "confirmar prune? [s/N]: " _ans
    if [[ ! "${_ans}" =~ ^[sS]$ ]]; then
        info "cancelado -- DB intacta"
        rm -f "${tmp}"
        return 0
    fi

    mv "${tmp}" "${NETWORKS_STORE}"
    chmod 600 "${NETWORKS_STORE}"
    ok "DB podada: ${dropped} eliminadas, ${kept} conservadas"
}
