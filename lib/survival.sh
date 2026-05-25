#!/usr/bin/env bash
# lib/survival.sh — supervivencia de sesión SSH durante el install.
# Corre el install en PRIMER PLANO dentro de una ventana byobu (fallback tmux):
# si cae el SSH, byobu mantiene vivo el proceso; el usuario cierra la ventana
# manualmente al terminar para revisar el output.

SURVIVAL_SESSION="wifi-setup"
SURVIVAL_WINDOW="install"
SURVIVAL_FLAG="WIFI_SETUP_INWIN"

# ---------------------------------------------------------------------------
# _mux_bin — backend de multiplexor: prefiere byobu, fallback tmux.
# Instala byobu vía apt si ninguno está (Debian). Imprime el binario a usar.
# ---------------------------------------------------------------------------
_mux_bin() {
    if command -v byobu >/dev/null 2>&1; then echo byobu; return 0; fi
    if command -v tmux  >/dev/null 2>&1; then echo tmux;  return 0; fi
    log "INFO" "instalando byobu (no hay multiplexor)..."
    apt-get update -qq >/dev/null 2>&1 || true
    apt-get install -y -qq byobu >/dev/null 2>&1 || apt-get install -y -qq tmux >/dev/null 2>&1
    if command -v byobu >/dev/null 2>&1; then echo byobu; return 0; fi
    if command -v tmux  >/dev/null 2>&1; then echo tmux;  return 0; fi
    return 1
}

# ---------------------------------------------------------------------------
# relaunch_byobu "<ruta_install.sh>" "$@"
# Relanza el install en primer plano dentro de una ventana byobu/tmux.
#   - Si ya estamos dentro de la ventana (flag) -> retorna y sigue.
#   - Si hay sesión 'wifi-setup' -> crea ventana nueva en ella.
#   - Si no -> crea la sesión y entra.
# Pasa flag + credenciales + MAC por entorno. El usuario cierra la ventana.
# ---------------------------------------------------------------------------
relaunch_byobu() {
    local install_path="$1"; shift

    # Ya estamos dentro de la ventana -> continuar con la instalación
    [[ "${!SURVIVAL_FLAG:-}" == "1" ]] && return 0

    local mux
    mux="$(_mux_bin)" || die "no se pudo obtener byobu/tmux — instálalo y reintenta"

    # tmux es el motor en ambos casos (byobu usa tmux por debajo)
    local engine="tmux"
    command -v tmux >/dev/null 2>&1 || engine="${mux}"

    # Comando interno: exporta contexto y corre el install en primer plano
    local inner
    inner="export ${SURVIVAL_FLAG}=1"
    inner+=" WIFI_SSID=$(printf %q "${WIFI_SSID:-}")"
    inner+=" WIFI_PSK_LINE=$(printf %q "${WIFI_PSK_LINE:-}")"
    inner+=" CHOSEN_MAC=$(printf %q "${CHOSEN_MAC:-}");"
    inner+=" bash $(printf %q "${install_path}")"
    local a; for a in "$@"; do inner+=" $(printf %q "${a}")"; done
    # Mantener la ventana viva tras terminar: muestra aviso y abre un shell
    # interactivo para que el usuario vea el output y cierre cuando quiera.
    # Shell final: volver al usuario real en SU home, con su login shell
    # (carga ~/.zshrc si su shell es zsh). 'su -' = login shell + cd $HOME.
    local _u _fsh
    _u="${SUDO_USER:-${USER:-root}}"
    if [[ "${_u}" != "root" ]]; then
        _fsh="su - ${_u}"
    else
        _fsh="bash -i"
    fi
    inner+="; rc=\$?; echo; echo \"[wifi-setup] instalación finalizada (rc=\$rc). Esta ventana queda abierta — ciérrala con: exit  o  Ctrl-D\"; exec ${_fsh}"

    log "INFO" "lanzando instalador en ventana ${mux} '${SURVIVAL_SESSION}:${SURVIVAL_WINDOW}'..."
    log "INFO" "si cae el SSH, el proceso sigue vivo en la ventana; ciérrala manual al terminar."

    if "${engine}" has-session -t "${SURVIVAL_SESSION}" 2>/dev/null; then
        "${engine}" new-window -t "${SURVIVAL_SESSION}" -n "${SURVIVAL_WINDOW}" "${inner}"
        "${engine}" select-window -t "${SURVIVAL_SESSION}:${SURVIVAL_WINDOW}" 2>/dev/null || true
        if [[ -z "${TMUX:-}" ]]; then
            exec "${engine}" attach-session -t "${SURVIVAL_SESSION}"
        fi
    else
        exec "${engine}" new-session -s "${SURVIVAL_SESSION}" -n "${SURVIVAL_WINDOW}" "${inner}"
    fi
    exit 0
}

# ---------------------------------------------------------------------------
# setup_and_verify_upstream <iface> [<mac>]
# Modelo dhcpcd puro: MAC persistente via .link + dhcpcd toma el lease real
# del AP (subred/gateway que sea). Verifica internet. No fuerza ninguna IP.
# Devuelve 0 si hay internet, 1 si no.
# ---------------------------------------------------------------------------
setup_and_verify_upstream() {
    local iface="$1" mac_explicita="${2:-}"
    setup_upstream_dhcpcd "${iface}" "${mac_explicita}"
    dhcpcd -n "${iface}" 2>/dev/null || true
    log "INFO" "verificando conectividad upstream (máx 25s)..."
    local waited=0
    while [[ "${waited}" -lt 25 ]]; do
        if ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; then
            log "INFO" "upstream con internet (IP del AP)"
            return 0
        fi
        sleep 5; (( waited += 5 )) || true
    done
    log "WARN" "upstream sin internet tras 25s — revisa WiFi/credenciales"
    return 1
}
