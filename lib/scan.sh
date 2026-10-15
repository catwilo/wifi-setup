#!/usr/bin/env bash
# lib/scan.sh -- escaneo de redes WiFi visibles.
#
# RESPONSABILIDAD UNICA: disparar un rescan sobre las antenas WiFi y
# listar las redes visibles. Solo lectura: no crea perfiles, no conecta,
# no toca el estado persistente de NetworkManager.
#
# MODELO (4 combinaciones):
#   wifi scan                 tabla completa, una foto, termina
#   wifi scan --names         lista plana de SSID, una foto, termina
#   wifi scan --live          tabla completa, refresca cada 5s, Ctrl-C
#   wifi scan --live --names  lista plana de SSID, refresca cada 5s
#   --iface X limita a la antena X en cualquiera de los 4 modos.
#
# El paginador se desactiva en cada invocacion de nmcli (PAGER=cat
# NMPAGER=cat). nmcli paginaria la salida cuando stdout es TTY; sin
# paginador, la salida se imprime entera -- ni less, ni prompts de
# "lines N-M".
#
# Help: help_scan en lib/help.sh (el dispatcher enruta -h alli).
#
# Requiere: common.sh + nm.sh + radio.sh cargados antes.
# Requiere root: el rescan usa la accion polkit
#   org.freedesktop.NetworkManager.wifi.scan.

SCAN_LIVE_INTERVAL=5

# ---------------------------------------------------------------------------
# _scan_parse_args [args...] -- setea SCAN_IFACE, SCAN_LIVE y SCAN_NAMES.
# ---------------------------------------------------------------------------
_scan_parse_args() {
    SCAN_IFACE=""
    SCAN_LIVE=0
    SCAN_NAMES=0
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --iface) SCAN_IFACE="${2:-}"; shift 2 ;;
            --live)  SCAN_LIVE=1; shift ;;
            --names) SCAN_NAMES=1; shift ;;
            *) die "flag desconocido: $1 (uso: wifi scan [--iface X] [--live] [--names])" ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# _scan_resolve_iface <iface> -- si vacio, devuelve RADIO_PRIMARY o vacio.
# Valida contra radio_is_iface cuando hay valor. Imprime el resultado.
# ---------------------------------------------------------------------------
_scan_resolve_iface() {
    local iface="$1"
    if [[ -z "${iface}" ]]; then
        _radio_load_state
        iface="${RADIO_PRIMARY:-}"
    fi
    if [[ -n "${iface}" ]]; then
        radio_is_iface "${iface}" || die "'${iface}' no es una interfaz WiFi"
    fi
    printf '%s\n' "${iface}"
}

# ---------------------------------------------------------------------------
# _scan_nmcli_table <iface> -- tabla completa. Pager desactivado.
# ---------------------------------------------------------------------------
_scan_nmcli_table() {
    local iface="$1"
    if [[ -n "${iface}" ]]; then
        PAGER=cat NMPAGER=cat nmcli dev wifi list ifname "${iface}" --rescan yes
    else
        PAGER=cat NMPAGER=cat nmcli dev wifi list --rescan yes
    fi
}

# ---------------------------------------------------------------------------
# _scan_nmcli_names <iface> -- solo SSID, uno por linea, deduplicado.
# Filtra SSID vacios (redes ocultas). Orden: como los devuelve nmcli,
# sin ordenar -- preserva la cercania (SIGNAL) del escaneo.
# ---------------------------------------------------------------------------
_scan_nmcli_names() {
    local iface="$1" raw line
    if [[ -n "${iface}" ]]; then
        raw="$(PAGER=cat NMPAGER=cat nmcli -t -f SSID dev wifi list ifname "${iface}" --rescan yes)"
    else
        raw="$(PAGER=cat NMPAGER=cat nmcli -t -f SSID dev wifi list --rescan yes)"
    fi
    declare -A seen=()
    while IFS= read -r line; do
        [[ -n "${line}" ]] || continue
        [[ -n "${seen[${line}]:-}" ]] && continue
        seen["${line}"]=1
        printf '%s\n' "${line}"
    done <<< "${raw}"
}

# ---------------------------------------------------------------------------
# _scan_render -- elige que nmcli-wrapper invocar segun SCAN_NAMES.
# ---------------------------------------------------------------------------
_scan_render() {
    local iface="$1"
    if [[ "${SCAN_NAMES}" -eq 1 ]]; then
        _scan_nmcli_names "${iface}"
    else
        _scan_nmcli_table "${iface}"
    fi
}

# ---------------------------------------------------------------------------
# _scan_snapshot <iface> -- una sola invocacion: foto del momento.
# ---------------------------------------------------------------------------
_scan_snapshot() {
    local iface="$1"
    if [[ "${SCAN_NAMES}" -eq 0 ]]; then
        if [[ -n "${iface}" ]]; then
            info "escaneando en ${iface}..."
        else
            info "escaneando en todas las antenas WiFi..."
        fi
    fi
    _scan_render "${iface}"
    _scan_persist_ssids "${iface}"
}

# _scan_persist_ssids <iface> -- guarda la lista de SSID visibles en
# STATE_DIR/last-scan.txt para que 'wifi add' sin <ssid> la use como
# picker fzf. Reutiliza la cache de nmcli (sin --rescan): no dispara un
# escaneo adicional. Best-effort: si falla, no rompe el flujo del scan.
_scan_persist_ssids() {
    local iface="$1"
    local cache="${STATE_DIR}/last-scan.txt"
    mkdir -p "${STATE_DIR}" || return 0

    local raw
    if [[ -n "${iface}" ]]; then
        raw="$(PAGER=cat NMPAGER=cat nmcli -t -f SSID dev wifi list ifname "${iface}" 2>/dev/null || true)"
    else
        raw="$(PAGER=cat NMPAGER=cat nmcli -t -f SSID dev wifi list 2>/dev/null || true)"
    fi
    [[ -n "${raw}" ]] || return 0

    local tmp
    tmp="$(mktemp "${STATE_DIR}/last-scan.XXXXXX")" || return 0
    declare -A seen=()
    local line
    while IFS= read -r line; do
        [[ -n "${line}" ]] || continue
        [[ -n "${seen[${line}]:-}" ]] && continue
        seen["${line}"]=1
        printf '%s\n' "${line}"
    done <<< "${raw}" > "${tmp}"
    mv "${tmp}" "${cache}"
    chmod 600 "${cache}"
}

# ---------------------------------------------------------------------------
# _scan_live <iface> -- refresca cada SCAN_LIVE_INTERVAL hasta Ctrl-C.
# ---------------------------------------------------------------------------
_scan_live() {
    local iface="$1"
    trap 'printf "\n"; exit 0' INT TERM
    while true; do
        if [[ -t 1 ]]; then
            clear
        fi
        printf 'wifi scan live -- %s' "$(date '+%H:%M:%S')"
        [[ -n "${iface}" ]] && printf '  iface=%s' "${iface}"
        printf '  (Ctrl-C para detener)\n\n'
        _scan_render "${iface}"
        sleep "${SCAN_LIVE_INTERVAL}"
    done
}

# ---------------------------------------------------------------------------
# scan_run [--iface X] [--live] [--names] -- escaneo de redes WiFi visibles.
# ---------------------------------------------------------------------------
scan_run() {
    _scan_parse_args "$@"

    nm_require
    local iface
    iface="$(_scan_resolve_iface "${SCAN_IFACE}")"

    if [[ "${SCAN_LIVE}" -eq 1 ]]; then
        _scan_live "${iface}"
    else
        _scan_snapshot "${iface}"
    fi
}
