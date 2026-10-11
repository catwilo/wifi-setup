#!/usr/bin/env bash
# install.sh -- instalador wifi-setup (NetworkManager backbone).
#
# MODELO DE PRIVILEGIOS:
#   El script corre como usuario normal. Solo la fase que muta el sistema
#   (apt, systemctl, nmcli con add, /etc/, /usr/local/bin) se eleva con
#   sudo, una sola vez, con: exec sudo bash $0 --root-phase ...
#   Los nombres de ifaces viajan por argv; la PSK se pide DENTRO del sudo
#   (asi el password de sudo y la PSK nunca comparten linea de comando).
#
# FLUJO:
#   Fase usuario:
#     1. guarda Debian
#     2. si sudo + sin tmux -> bajar a SUDO_USER (relaunch en SU tmux)
#     3. relaunch en tmux (crea ventana o sesion, attach)
#     4. deteccion HW (antenas, ssh iface)
#     5. exec sudo bash $0 --root-phase <ifaces>
#   Fase root (dentro de sudo, mismo TTY, misma ventana tmux):
#     6. install_deps (apt)
#     7. prompt SSID/PSK, crear perfiles NM en cada antena
#     8. migrar stack: parar iwd/dhcpcd, arrancar NM
#     9. SSH hardening
#    10. tailscale install (sin conectar)
#    11. symlink /usr/local/bin/wifi
#    12. state + verificacion
#
# Requiere: Debian, TTY, conexion a internet.
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# ---------------------------------------------------------------------------
# --help
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    cat <<'HELP'
uso: sudo wifi install

Instala wifi-setup. Auto-detecta antenas (nativa + USB), pregunta SSID y
PSK solo si no existe config previa, y deja:
  - NetworkManager como gestor de red
  - iwd instalado y parado (fallback manual)
  - Las antenas con sus perfiles WiFi (PRIMARY=USB, SECONDARY=nativa)
  - Tailscale instalado y apagado
  - El cable LAN NO se configura: usa 'wifi lan setup' cuando lo necesites

El script corre como usuario y eleva con sudo solo la fase que muta el
sistema. El output completo queda en
~/.local/state/wifi-setup/install-<timestamp>.log

Requisitos: Debian 13+, TTY, conexion a internet, al menos una antena WiFi.
HELP
    exit 0
fi

# ---------------------------------------------------------------------------
# 1. Guarda Debian: en otras plataformas salir limpio.
# ---------------------------------------------------------------------------
_require_debian() {
    [[ -n "${PREFIX:-}" ]] && [[ -d "${PREFIX}/bin" ]] && return 1  # Termux
    [[ -r /etc/os-release ]] || return 1
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}${ID_LIKE:-}" in
        *debian*|*ubuntu*) return 0 ;;
    esac
    return 1
}

if ! _require_debian; then
    info "wifi-setup: plataforma no-Debian -- nada que hacer aqui (exit 0)"
    exit 0
fi

# ---------------------------------------------------------------------------
# _root_phase <primary> <secondary> <ssh_iface>
# Corre como root (dentro de sudo). Instala, crea perfiles, migra el
# stack, hardening SSH, tailscale, symlink, state.
# ---------------------------------------------------------------------------
_root_phase() {
    [[ "${EUID}" -eq 0 ]] || die "_root_phase invocado sin root"

    local WIFI_PRIMARY="${1:-}"
    local WIFI_SECONDARY="${2:-}"
    local SSH_IFACE="${3:-}"
    [[ -n "${WIFI_PRIMARY}" ]] || die "root-phase sin iface primaria"

    source "${SCRIPT_DIR}/lib/deps.sh"
    source "${SCRIPT_DIR}/lib/nm.sh"
    source "${SCRIPT_DIR}/lib/radio.sh"
    source "${SCRIPT_DIR}/lib/vpn.sh"
    source "${SCRIPT_DIR}/lib/ssh.sh"

    local INSTALL_MODE="server"
    local BIN_DIR="/usr/local/bin"
    local WIFI_BIN="${BIN_DIR}/wifi"
    local WIFI_REPO_BIN="${SCRIPT_DIR}/bin/wifi"

    LOG_FILE="${WIFI_SETUP_LOG:-/var/log/wifi-setup-install-$(date +%Y%m%d-%H%M%S).log}"
    mkdir -p "$(dirname "${LOG_FILE}")"

    # ---------------------------------------------------------------------
    # Limpieza previa (idempotente)
    # ---------------------------------------------------------------------
    if [[ -f "${STATE_DIR}/install.state" || -L "${WIFI_BIN}" ]]; then
        info "instalacion previa detectada -- limpiando..."
        sweep_legacy_install

        for svc in wifi-setup-forward wifi-setup-client wifi-setup-lan; do
            systemctl stop    "${svc}" 2>/dev/null || true
            systemctl disable "${svc}" 2>/dev/null || true
            rm -f "/etc/systemd/system/${svc}.service"
        done
        systemctl daemon-reload 2>/dev/null || true

        for old_bin in wifi-panic wfs wifi-status wifi-list wifi-passwd wifi-showpass; do
            rm -f "/usr/local/bin/${old_bin}"
        done

        while iptables -t nat -D POSTROUTING -j MASQUERADE 2>/dev/null; do :; done

        rm -f /etc/systemd/network/10-wifi-setup-*.network
        rm -f /etc/systemd/network/10-wifi-setup-*.link
        rm -f /etc/ssh/sshd_config.d/99-wifi-setup.conf
        rm -f /etc/sysctl.d/99-wifi-setup-forward.conf

        info "limpieza completada"
    fi

    # ---------------------------------------------------------------------
    # 1. Dependencias (apt)
    # ---------------------------------------------------------------------
    echo ""
    section "Dependencias"
    install_deps

    # ---------------------------------------------------------------------
    # 2. Perfiles WiFi ANTES de tocar el stack.
    #    Con los perfiles creados, cuando migrate pare iwd, NM ya sabe con
    #    que reconectar. Sin esta inversion, NM arranca sin red conocida y
    #    el equipo queda sin WiFi hasta el siguiente boot.
    # ---------------------------------------------------------------------
    echo ""
    section "Configuracion WiFi (perfiles)"

    nm_require

    local existing
    existing="$(nmcli -t -f NAME,TYPE con show 2>/dev/null \
        | awk -F: '$2=="802-11-wireless"{print $1}')"
    if [[ -n "${existing}" ]]; then
        info "perfiles WiFi existentes -- se conservan:"
        while IFS= read -r p; do
            [[ -n "${p}" ]] && info "  · ${p}"
        done <<< "${existing}"
    else
        # Detectar SSID activo via iwd (que aun esta conectado).
        local current_ssid=""
        if command -v iwctl >/dev/null 2>&1; then
            current_ssid="$(iwctl station "${WIFI_PRIMARY}" show 2>/dev/null \
                | awk -F': ' '/Connected network/ {print $2}' | tr -d '[:space:]' || true)"
        fi

        local wifi_ssid="" wifi_psk=""
        if [[ -n "${current_ssid}" ]]; then
            info "SSID detectado desde iwd: ${current_ssid}"
            read -r -p "SSID [${current_ssid}]: " wifi_ssid
            wifi_ssid="${wifi_ssid:-${current_ssid}}"
        else
            read -r -p "SSID de la red WiFi: " wifi_ssid
            [[ -n "${wifi_ssid}" ]] || die "SSID vacio"
        fi

        read -r -s -p "PSK (min 8): " wifi_psk; echo
        [[ "${#wifi_psk}" -ge 8 ]] || die "PSK minimo 8 caracteres"

        local ifc profile
        for ifc in "${WIFI_PRIMARY}" ${WIFI_SECONDARY}; do
            [[ -n "${ifc}" ]] || continue
            profile="wifi-${ifc}-${wifi_ssid}"
            nm_wifi_create "${profile}" "${ifc}" "${wifi_ssid}" "${wifi_psk}"
            nm_con_set_autoconnect "${profile}" on
        done
        unset wifi_psk
    fi

    RADIO_PRIMARY="${WIFI_PRIMARY}"
    RADIO_SECONDARY="${WIFI_SECONDARY}"
    _radio_save_state
    radio_sync_priorities

    ok "perfiles WiFi listos -- NM tiene con que reconectar"

    # ---------------------------------------------------------------------
    # 3. Migracion al stack NM
    # ---------------------------------------------------------------------
    echo ""
    section "Migrando stack de red"

    info "parando iwd (queda instalado, disabled, fallback manual)..."
    systemctl stop    iwd 2>/dev/null || true
    systemctl disable iwd 2>/dev/null || true

    info "parando dhcpcd (NM trae su propio cliente)..."
    systemctl stop    dhcpcd 2>/dev/null || true
    systemctl disable dhcpcd 2>/dev/null || true

    info "parando systemd-networkd..."
    systemctl stop    systemd-networkd 2>/dev/null || true
    systemctl disable systemd-networkd 2>/dev/null || true

    info "arrancando NetworkManager..."
    systemctl enable NetworkManager >/dev/null 2>&1 || true
    systemctl restart NetworkManager
    sleep 5
    systemctl is-active NetworkManager >/dev/null 2>&1 \
        || die "NetworkManager no arranco -- revisa: journalctl -u NetworkManager -n 40"

    local ifc
    for ifc in "${WIFI_PRIMARY}" ${WIFI_SECONDARY}; do
        [[ -n "${ifc}" ]] || continue
        nmcli dev set "${ifc}" managed yes 2>/dev/null || true
    done

    info "esperando IP en ${WIFI_PRIMARY} (max 45s)..."
    local waited=0 ip=""
    while [[ "${waited}" -lt 45 ]]; do
        ip="$(ip -4 -o addr show "${WIFI_PRIMARY}" 2>/dev/null \
            | awk '{print $4}' | head -1)"
        [[ -n "${ip}" ]] && break
        sleep 3
        waited=$((waited + 3))
    done
    [[ -n "${ip}" ]] \
        || die "la antena ${WIFI_PRIMARY} no obtuvo IP tras 45s -- revisa: nmcli dev status"

    ok "NetworkManager activo, ${WIFI_PRIMARY} con IP ${ip}"

    # ---------------------------------------------------------------------
    # 4. SSH hardening
    # ---------------------------------------------------------------------
    echo ""
    section "SSH"
    configure_ssh

    # ---------------------------------------------------------------------
    # 5. Tailscale (install + daemon, sin conectar)
    # ---------------------------------------------------------------------
    echo ""
    section "VPN (Tailscale)"
    vpn_install

    # ---------------------------------------------------------------------
    # 6. Symlink + state
    # ---------------------------------------------------------------------
    echo ""
    section "Instalando comando"
    chmod +x "${SCRIPT_DIR}/bin/wifi"
    mkdir -p "${BIN_DIR}"
    ln -sfn "${WIFI_REPO_BIN}" "${WIFI_BIN}"
    ok "symlink: ${WIFI_BIN} -> ${WIFI_REPO_BIN}"

    mkdir -p "${STATE_DIR}"
    cat > "${STATE_DIR}/install.state" <<EOF
INSTALL_MODE="${INSTALL_MODE}"
WIFI_PRIMARY="${WIFI_PRIMARY}"
WIFI_SECONDARY="${WIFI_SECONDARY}"
SSH_IFACE="${SSH_IFACE}"
EOF
    chmod 600 "${STATE_DIR}/install.state"

    if [[ -n "${SUDO_USER:-}" ]]; then
        chown -R "${SUDO_USER}:${SUDO_USER}" "${BASE_DIR}" 2>/dev/null || true
    fi

    # ---------------------------------------------------------------------
    # 7. Verificacion final
    # ---------------------------------------------------------------------
    echo ""
    section "Verificacion"
    nm_dev_list

    echo ""
    if ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; then
        ok "conectividad OK"
    else
        warn "sin conectividad -- revisa: wifi status"
    fi

    echo ""
    vpn_print_help

    echo ""
    echo -e "${C_GREEN}${C_BOLD}  Instalacion completa.${C_RESET}"
    echo -e "${C_GREEN}  Log    : ${LOG_FILE}${C_RESET}"
    echo -e "${C_GREEN}  Comando: sudo wifi help${C_RESET}"
    echo ""
}

# ---------------------------------------------------------------------------
# Handler de la fase root: se dispara cuando el script se re-invoca con
# --root-phase via sudo. Carga los libs que necesitan root y corre las
# mutaciones del sistema. Los ifaces vienen por argv (no secretos).
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--root-phase" ]]; then
    shift
    _root_phase "$@"
    exit $?
fi

# ---------------------------------------------------------------------------
# 2. Si sudo elevo desde SUDO_USER y no estamos en tmux, bajar al usuario
#    original ANTES del relaunch. El server tmux es por usuario; como root
#    no vemos la sesion del usuario.
# ---------------------------------------------------------------------------
if [[ "${EUID}" -eq 0 && -n "${SUDO_USER:-}" && -z "${TMUX:-}" ]]; then
    _real_user="${SUDO_USER}"
    _real_home="$(getent passwd "${_real_user}" | cut -d: -f6)"
    [[ -n "${_real_home}" && -d "${_real_home}" ]] \
        || die "no pude resolver el home de ${_real_user}"
    info "sudo: bajando a ${_real_user} para relaunch en SU tmux..."
    exec sudo -u "${_real_user}" HOME="${_real_home}" bash "$0" "$@"
fi

# ---------------------------------------------------------------------------
# 3. Preparar el directorio de logs en el HOME del usuario.
#    Si existe con dueno root (instalacion previa que corrio todo como
#    root), borrarlo con sudo una vez. sudo cachea el timestamp 15 min;
#    el resto del script no vuelve a pedir password hasta --root-phase.
# ---------------------------------------------------------------------------
if [[ "${EUID}" -eq 0 ]]; then
    die "install.sh debe correr como usuario, no como root -- usa: bash install.sh"
fi

LOG_DIR_USER="${HOME}/.local/state/wifi-setup"
if [[ -e "${LOG_DIR_USER}" && ! -w "${LOG_DIR_USER}" ]]; then
    warn "${LOG_DIR_USER} no es escribible (instalacion previa como root) -- limpiando con sudo..."
    sudo rm -rf "${LOG_DIR_USER}" \
        || die "no pude limpiar ${LOG_DIR_USER} -- borra a mano: sudo rm -rf ${LOG_DIR_USER}"
fi
mkdir -p "${LOG_DIR_USER}"

# ---------------------------------------------------------------------------
# 4. Relaunch en tmux.
#    - Ya dentro de tmux: seguir aqui.
#    - Hay servidor tmux: crear ventana 'wifi-install' y saltar a ella.
#    - No hay servidor: crear sesion 'wifi-setup' (attacha si hay TTY).
#    La ventana corre: bash $0 2>&1 | tee -a $log; exit
#    El 'exit' la cierra al terminar. El 'tee' deja todo en el log.
# ---------------------------------------------------------------------------
_relaunch_in_tmux() {
    [[ -n "${TMUX:-}" ]] && return 0
    command -v tmux >/dev/null 2>&1 || {
        warn "tmux no instalado -- corriendo sin ventana (output solo en TTY)"
        return 0
    }

    local ts; ts="$(date +%Y%m%d-%H%M%S)"
    local log="${LOG_DIR_USER}/install-${ts}.log"

    local inner
    inner="WIFI_SETUP_LOG=$(printf '%q' "${log}") bash $(printf '%q' "$0")"
    local a; for a in "$@"; do inner+=" $(printf '%q' "${a}")"; done
    inner="${inner} 2>&1 | tee -a $(printf '%q' "${log}"); exit"

    local first_session
    first_session="$(tmux ls 2>/dev/null | head -1 | cut -d: -f1 || true)"

    if [[ -n "${first_session}" ]]; then
        info "creando ventana 'wifi-install' en sesion tmux '${first_session}'..."
        tmux new-window -t "${first_session}" -n wifi-install "${inner}"
        tmux select-window -t "${first_session}:wifi-install"
        info "log: ${log}"
        exit 0
    fi

    # No hay servidor tmux. Si no hay TTY externo no podemos attachar;
    # crear una sesion detached dejaria un proceso huerfano invisible.
    if [[ ! -t 0 && ! -t 1 ]]; then
        die "no hay sesion tmux y no hay TTY -- conectate con: nssh -t <alias>
y vuelve a correr: bash install.sh"
    fi

    info "creando sesion tmux 'wifi-setup' (te attacha automaticamente)..."
    info "log: ${log}"
    exec tmux new-session -s wifi-setup -n install "${inner}"
}

_relaunch_in_tmux "$@"

LOG_FILE="${WIFI_SETUP_LOG:-${LOG_DIR_USER}/install-$(date +%Y%m%d-%H%M%S).log}"

# ---------------------------------------------------------------------------
# Deteccion HW (usuario, sin root).
# ---------------------------------------------------------------------------
section "Deteccion de hardware"

SSH_IFACE="$(detect_ssh_iface 2>/dev/null || true)"
if [[ -n "${SSH_IFACE}" ]]; then
    info "sesion SSH entra por: ${SSH_IFACE}"
else
    info "sin sesion SSH detectada -- continuo"
fi

WIFI_IFACES=()
while IFS= read -r _if; do
    [[ -n "${_if}" ]] && WIFI_IFACES+=("${_if}")
done < <(for p in /sys/class/net/wl* /sys/class/net/wlan*; do
    [[ -e "$p" ]] && echo "${p##*/}"
done | sort -u)

[[ "${#WIFI_IFACES[@]}" -gt 0 ]] \
    || die "no se detecto ninguna antena WiFi -- conecta el adaptador USB y reintenta"

WIFI_PRIMARY=""
WIFI_SECONDARY=""
for _if in "${WIFI_IFACES[@]}"; do
    _path="$(readlink -f "/sys/class/net/${_if}" 2>/dev/null || true)"
    if [[ "${_path}" == *"/usb"* ]]; then
        [[ -z "${WIFI_PRIMARY}" ]] && WIFI_PRIMARY="${_if}"
    else
        [[ -z "${WIFI_SECONDARY}" ]] && WIFI_SECONDARY="${_if}"
    fi
done
if [[ -z "${WIFI_PRIMARY}" && -n "${WIFI_SECONDARY}" ]]; then
    WIFI_PRIMARY="${WIFI_SECONDARY}"
    WIFI_SECONDARY=""
fi

info "antena PRIMARY  : ${WIFI_PRIMARY}"
info "antena SECONDARY: ${WIFI_SECONDARY:-—}"
info "log: ${LOG_FILE}"

# ---------------------------------------------------------------------------
# Elevar SOLO la fase que muta. Los ifaces viajan por argv (no son secretos).
# La PSK se pide dentro de sudo, no aqui.
# ---------------------------------------------------------------------------
info "elevando a root para la fase de instalacion..."
exec sudo WIFI_SETUP_LOG="${LOG_FILE}" \
     bash "$0" --root-phase \
     "${WIFI_PRIMARY}" "${WIFI_SECONDARY}" "${SSH_IFACE:-}"
