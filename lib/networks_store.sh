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
#   networks_pull_nm lee TODOS los perfiles NM WiFi y los funde al store.
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
# networks_pull_nm -- funde los perfiles NM actuales al store (aditivo).
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
_networks_store_update_field() {
    local ssid="$1" iface="${2:-*}" field="$3" value="$4"
    [[ -f "${NETWORKS_STORE}" ]] || return 1
    local col
    case "${field}" in
        psk)         col=2 ;;
        autoconnect) col=4 ;;
        priority)    col=5 ;;
        *) die "campo desconocido: ${field}" ;;
    esac
    local ts; ts="$(date +%s)"
    local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/wifi-tsv.XXXXXX")"
    local rc=0
    awk -F'\t' -v s="${ssid}" -v i="${iface}" -v c="${col}" -v v="${value}" -v u="${ts}" '
        BEGIN { OFS="\t"; n=0 }
        /^#/ { print; next }
        NF < 3 { print; next }
        {
            if ($1==s && (i=="*" || $3==i)) { $c=v; $6=u; n++ }
            print
        }
        END { exit (n==0 ? 1 : 0) }
    ' "${NETWORKS_STORE}" > "${tmp}" || rc=$?
    mv "${tmp}" "${NETWORKS_STORE}"
    chmod 600 "${NETWORKS_STORE}"
    return "${rc}"
}
