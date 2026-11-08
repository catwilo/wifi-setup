# shellcheck shell=bash
# lib/networks_show.sh -- vista y migracion del store (list, show, export, import, cleanup).
# Requiere common.sh + nm.sh + networks_store.sh.

networks_list() {
    local sort_col="ssid" reverse=0
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --sort) sort_col="${2:-ssid}"; shift 2 ;;
            --sort=*) sort_col="${1#--sort=}"; shift ;;
            --reverse|-r) reverse=1; shift ;;
            *) shift ;;
        esac
    done
    case "${sort_col}" in
        ssid|iface|auto|prio|nm|iwd) ;;
        *) warn "columna invalida: '${sort_col}' (ssid|iface|auto|prio|nm|iwd) -- usando ssid"
           sort_col="ssid" ;;
    esac

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

    # Construir filas con clave de ordenamiento (padded para numericos).
    local -a _rows=()
    local line ssid psk iface auto prio _ts profile
    local nm_ok iwd_ok key formatted
    while IFS= read -r line; do
        IFS=$'\t' read -r ssid psk iface auto prio _ts <<< "${line}"
        [[ -n "${ssid}" && -n "${iface}" ]] || continue
        profile="wifi-${iface}-${ssid}"
        if nm_con_exists "${profile}" 2>/dev/null; then nm_ok="si"; else nm_ok="NO"; fi
        if [[ -r "${IWD_DIR}/${ssid}.psk" ]]; then iwd_ok="si"; else iwd_ok="NO"; fi
        case "${sort_col}" in
            ssid)  key="${ssid}" ;;
            iface) key="${iface}" ;;
            auto)  key="${auto}" ;;
            prio)  key="$(printf '%010d' "${prio}")" ;;
            nm)    key="${nm_ok}" ;;
            iwd)   key="${iwd_ok}" ;;
        esac
        formatted="$(printf '%-24s %-10s %-6s %-6s %-6s %-6s' \
            "${ssid}" "${iface}" "${auto}" "${prio}" "${nm_ok}" "${iwd_ok}")"
        _rows+=("${key}"$'\t'"${formatted}")
    done < <(_networks_store_rows)

    # Ordenar con sort (delegar a coreutils; IFS newline para preservar
    # espacios internos). sort default = ascending.
    local -a _sorted=()
    if [[ "${reverse}" -eq 1 ]]; then
        mapfile -t _sorted < <(printf '%s\n' "${_rows[@]}" | sort -r)
    else
        mapfile -t _sorted < <(printf '%s\n' "${_rows[@]}" | sort)
    fi

    printf '%-24s %-10s %-6s %-6s %-6s %-6s\n' \
        "SSID" "IFACE" "AUTO" "PRIO" "NM" "IWD"
    printf '%s\n' "--------------------------------------------------------------------------"
    local r
    for r in "${_sorted[@]}"; do
        printf '%s\n' "${r#*$'\t'}"
    done
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

# networks_cleanup -- elimina filas del TSV cuyo SSID ya no existe en ningun
# backend (ni perfil NM ni .psk en iwd). Con confirmacion explicita.
networks_cleanup() {
    [[ -f "${NETWORKS_STORE}" ]] || { warn "DB vacia"; return 0; }

    # Sin NM, nm_con_exists siempre falla y TODAS las filas parecen
    # huerfanas. Abortar: prune solo tiene sentido con NM activo.
    if ! systemctl is-active NetworkManager >/dev/null 2>&1; then
        err "prune requiere NM activo (si no, todas las filas parecen huerfanas)"
        err "arranca NM primero: wifi fallback off"
        return 1
    fi
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

        # Conservador: una fila se elimina solo si el SSID no existe en
        # NINGUN backend (ni perfil NM ni .psk en iwd). Filas de una
        # antena desconectada se conservan como historico -- el usuario
        # decide cuando borrarlas con wifi delete.
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

# _networks_store_update_field <ssid> [<iface>] <field> <value>
# Actualiza UN campo de las filas que matchean. iface vacio o "*" matchea
# todas las filas del SSID. field en {psk,autoconnect,priority}.
# rc=0: al menos una fila actualizada. rc=1: ninguna fila matcheo.
