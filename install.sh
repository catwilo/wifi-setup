#!/usr/bin/env bash
# install.sh -- instalador wifi-setup (NetworkManager backbone).
#
# RESPONSABILIDAD UNICA: instalar el stack completo en un equipo Debian.
# No configura el cable LAN (eso es wifi lan setup, activacion manual).
# No conecta Tailscale (eso es wifi vpn up, activacion manual).
#
# FLUJO:
#   1. guarda Debian (Termux/macOS: exit limpio)
#   2. relaunch en tmux:
#        - dentro de tmux       -> ya estamos, seguir
#        - hay servidor tmux    -> nueva ventana + select (ver en vivo)
#        - no hay servidor      -> nueva sesion (attacha automaticamente)
#      La ventana corre "install.sh 2>&1 | tee log" y se cierra al terminar.
#      Todo el output queda en el log para revisar despues.
#   3. auto-elevar via sudo (TTY presente gracias a la ventana tmux)
#   4. deteccion: antenas WiFi, ssh iface
#   5. install_deps (NM + iwd fallback + utilidades)
#   6. pedir SSID/PSK si no hay perfiles previos
#   7. crear perfiles NM en cada antena (SIN activar todavia)
#   8. safe_run migrate-nm: parar iwd/dhcpcd, arrancar NM (canary 120s)
#   9. verificar conectividad
#  10. hardening SSH, install tailscale, symlink, state
#
# Requiere: root, TTY, conexion a internet.
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
  - iwd instalado pero parado (fallback manual)
  - Las antenas con sus perfiles WiFi (PRIMARY=USB, SECONDARY=nativa)
  - Tailscale instalado y apagado
  - El cable LAN NO se configura: usa 'wifi lan setup' cuando lo necesites

Requisitos:
  - Debian 13+, root, conexion a internet
  - Al menos una antena WiFi

Supervivencia SSH: el install se relanza dentro de una ventana tmux.
Si hay servidor tmux abierto, crea ventana nueva y te lleva a ella; si
no, crea la sesion 'wifi-setup' y te attacha. La ventana se cierra sola
al terminar; el output completo queda en
~/.local/state/wifi-setup/install-<timestamp>.log
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
# 2. Si sudo elevo desde SUDO_USER y no estamos en tmux, bajar al usuario
#    original ANTES del relaunch. El servidor tmux es por usuario: como
#    root no veriamos la sesion del usuario, y el relaunch crearia una
#    sesion nueva (invisible) en el server de root. Bajando a SUDO_USER,
#    el relaunch ve SU sesion existente y crea la ventana ahi.
# ---------------------------------------------------------------------------
if [[ "${EUID}" -eq 0 && -n "${SUDO_USER:-}" && -z "${TMUX:-}" ]]; then
    _real_user="${SUDO_USER}"
    _real_home="$(getent passwd "${_real_user}" | cut -d: -f6)"
    [[ -n "${_real_home}" && -d "${_real_home}" ]] || \
        die "no pude resolver el home de ${_real_user}"
    info "sudo: bajando a ${_real_user} para relaunch en SU tmux..."
    exec sudo -u "${_real_user}" HOME="${_real_home}" bash "$0" "$@"
fi

# ---------------------------------------------------------------------------
# 3. Relaunch en tmux (solo si no estamos ya dentro).
#    La ventana ejecuta: WIFI_SETUP_LOG=<log> bash $0 ... 2>&1 | tee -a $log; exit
#    El "exit" al final hace que la ventana se cierre al terminar.
#    El "tee" preserva el output visible Y lo guarda en el log.
# ---------------------------------------------------------------------------
_relaunch_in_tmux() {
    [[ -n "${TMUX:-}" ]] && return 0
    command -v tmux >/dev/null 2>&1 || {
        warn "tmux no instalado -- corriendo sin ventana (output solo en TTY)"
        return 0
    }

    local ts; ts="$(date +%Y%m%d-%H%M%S)"
    local log_dir="${HOME}/.local/state/wifi-setup"
    local log="${log_dir}/install-${ts}.log"
    mkdir -p "${log_dir}"

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
    else
        info "creando sesion tmux 'wifi-setup' (te attacha automaticamente)..."
        info "log: ${log}"
        exec tmux new-session -s wifi-setup -n install "${inner}"
    fi
    exit 0
}

_relaunch_in_tmux "$@"

# ---------------------------------------------------------------------------
# 4. Auto-elevar via sudo (TTY presente: la ventana tmux o el terminal actual).
#    sudo lee el password del TTY, nunca de stdin redirigido/argv/env.
# ---------------------------------------------------------------------------
# Preservar WIFI_SETUP_LOG y HOME explícitamente. sudo -E depende de
# env_keep en sudoers y no es confiable; pasar por línea de comando sí.
# El path no lleva secretos (es un archivo de log en el home del
# usuario), así que verlo en ps no es problema.
_real_home="${HOME}"
_log_from_parent="${WIFI_SETUP_LOG:-}"
if [[ "${EUID}" -ne 0 ]]; then
    if [[ -t 0 && -t 1 ]]; then
        info "elevando a root via sudo..."
        exec sudo WIFI_SETUP_LOG="${_log_from_parent}" HOME="${_real_home}" \
            bash "$0" "$@"
    fi
    die "requiere root y TTY -- corre: nssh -t <alias> 'sudo bash $(realpath "$0")'"
fi

# A partir de aca somos root. WIFI_SETUP_LOG viene de la línea de sudo.
LOG_FILE="${WIFI_SETUP_LOG:-${_real_home}/.local/state/wifi-setup/install-$(date +%Y%m%d-%H%M%S).log}"
mkdir -p "$(dirname "${LOG_FILE}")"

# ---------------------------------------------------------------------------
# Cargar el resto de modulos ahora que somos root
# ---------------------------------------------------------------------------
source "${SCRIPT_DIR}/lib/deps.sh"
source "${SCRIPT_DIR}/lib/detect.sh"
source "${SCRIPT_DIR}/lib/nm.sh"
source "${SCRIPT_DIR}/lib/radio.sh"
source "${SCRIPT_DIR}/lib/vpn.sh"
source "${SCRIPT_DIR}/lib/ssh.sh"

INSTALL_MODE="server"   # conservado por compat, no afecta NM
BIN_DIR="/usr/local/bin"
WIFI_BIN="${BIN_DIR}/wifi"
WIFI_REPO_BIN="${SCRIPT_DIR}/bin/wifi"

# ---------------------------------------------------------------------------
# Limpieza previa (idempotente)
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 5. Deteccion de hardware
# ---------------------------------------------------------------------------
echo ""
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

# ---------------------------------------------------------------------------
# 6. Dependencias
# ---------------------------------------------------------------------------
echo ""
section "Dependencias"
install_deps

# ---------------------------------------------------------------------------
# 7. Perfiles WiFi ANTES de tocar el stack.
#    Al crear los perfiles primero, cuando migrate-nm pare iwd, NM ya tiene
#    con que reconectar -- sin ventana ciega sin WiFi.
# ---------------------------------------------------------------------------
echo ""
section "Configuracion WiFi (perfiles)"

nm_require

_existing_profiles="$(nmcli -t -f NAME,TYPE con show 2>/dev/null | awk -F: '$2=="802-11-wireless"{print $1}')"
if [[ -n "${_existing_profiles}" ]]; then
    info "perfiles WiFi existentes detectados -- se conservan:"
    while IFS= read -r p; do
        [[ -n "${p}" ]] && info "  · ${p}"
    done <<< "${_existing_profiles}"
else
    # Detectar el SSID activo actual (iwd sabe cual esta conectado)
    CURRENT_SSID=""
    if command -v iwctl >/dev/null 2>&1; then
        CURRENT_SSID="$(iwctl station "${WIFI_PRIMARY}" show 2>/dev/null \
            | awk -F': ' '/Connected network/ {print $2}' | tr -d '[:space:]' || true)"
    fi

    if [[ -n "${CURRENT_SSID}" ]]; then
        info "SSID detectado desde iwd: ${CURRENT_SSID}"
        read -r -p "SSID [${CURRENT_SSID}]: " WIFI_SSID
        WIFI_SSID="${WIFI_SSID:-${CURRENT_SSID}}"
    else
        read -r -p "SSID de la red WiFi: " WIFI_SSID
        [[ -n "${WIFI_SSID}" ]] || die "SSID vacio"
    fi

    read -r -s -p "PSK (min 8): " WIFI_PSK; echo
    [[ "${#WIFI_PSK}" -ge 8 ]] || die "PSK minimo 8 caracteres"

    for _if in "${WIFI_IFACES[@]}"; do
        _profile="wifi-${_if}-${WIFI_SSID}"
        nm_wifi_create "${_profile}" "${_if}" "${WIFI_SSID}" "${WIFI_PSK}"
        nm_con_set_autoconnect "${_profile}" on
    done
    unset WIFI_PSK
fi

# Persistir roles de antena
RADIO_PRIMARY="${WIFI_PRIMARY}"
RADIO_SECONDARY="${WIFI_SECONDARY}"
_radio_save_state
radio_sync_priorities

ok "perfiles WiFi creados -- NM tiene con que reconectar"

# ---------------------------------------------------------------------------
# 8. Migracion al stack NM (safe_run: canary 120s + rollback automatico)
# ---------------------------------------------------------------------------
echo ""
section "Migrando stack de red"

_migrate_to_nm() {
    info "deteniendo iwd (fallback manual) y dhcpcd (reemplazado por NM)..."
    systemctl stop    iwd    2>/dev/null || true
    systemctl disable iwd    2>/dev/null || true
    systemctl stop    dhcpcd 2>/dev/null || true
    systemctl disable dhcpcd 2>/dev/null || true
    systemctl stop    systemd-networkd 2>/dev/null || true
    systemctl disable systemd-networkd 2>/dev/null || true

    info "arrancando NetworkManager..."
    systemctl enable NetworkManager >/dev/null 2>&1 || true
    systemctl restart NetworkManager
    sleep 5
    systemctl is-active NetworkManager >/dev/null 2>&1 \
        || die "NetworkManager no arranco -- revisa: journalctl -u NetworkManager -n 40"

    # NM necesita gestionar las antenas explicitamente.
    nmcli dev set "${WIFI_PRIMARY}" managed yes 2>/dev/null || true
    if [[ -n "${WIFI_SECONDARY}" ]]; then
        nmcli dev set "${WIFI_SECONDARY}" managed yes 2>/dev/null || true
    fi

    # Esperar a que NM active los perfiles y obtenga IP.
    info "esperando conexion WiFi (max 45s)..."
    local waited=0 ip=""
    while [[ "${waited}" -lt 45 ]]; do
        ip="$(ip -4 -o addr show "${WIFI_PRIMARY}" 2>/dev/null | awk '{print $4}' | head -1)"
        [[ -n "${ip}" ]] && break
        sleep 3
        waited=$((waited + 3))
    done
    [[ -n "${ip}" ]] \
        || die "la antena ${WIFI_PRIMARY} no obtuvo IP tras 45s -- revisa: nmcli dev status"

    ok "NetworkManager activo, ${WIFI_PRIMARY} con IP ${ip}"
}

if ! safe_run "migrate-nm" 120 _migrate_to_nm; then
    die "migracion a NetworkManager fallo o el acceso se perdio -- revisa ${LOG_DIR}/ops.log"
fi

# ---------------------------------------------------------------------------
# 9. SSH hardening
# ---------------------------------------------------------------------------
echo ""
section "SSH"
configure_ssh

# ---------------------------------------------------------------------------
# 10. Tailscale (install + daemon, sin conectar)
# ---------------------------------------------------------------------------
echo ""
section "VPN (Tailscale)"
vpn_install

# ---------------------------------------------------------------------------
# 11. Symlink + state final
# ---------------------------------------------------------------------------
echo ""
section "Instalando comando"
chmod +x "${SCRIPT_DIR}/bin/wifi"
mkdir -p "${BIN_DIR}"
ln -sfn "${WIFI_REPO_BIN}" "${WIFI_BIN}"
ok "symlink: ${WIFI_BIN} -> ${WIFI_REPO_BIN}"

cat > "${STATE_DIR}/install.state" <<EOF
INSTALL_MODE="${INSTALL_MODE}"
WIFI_PRIMARY="${WIFI_PRIMARY}"
WIFI_SECONDARY="${WIFI_SECONDARY}"
SSH_IFACE="${SSH_IFACE:-}"
EOF
chmod 600 "${STATE_DIR}/install.state"

# BASE_DIR + logs accesibles para el usuario real (SUDO_USER).
if [[ -n "${SUDO_USER:-}" ]]; then
    chown -R "${SUDO_USER}:${SUDO_USER}" "${BASE_DIR}" 2>/dev/null || true
fi
[[ -f "${LOG_FILE}" ]] && chmod 644 "${LOG_FILE}" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 12. Verificacion final
# ---------------------------------------------------------------------------
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
