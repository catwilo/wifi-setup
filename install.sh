#!/usr/bin/env bash
# install.sh -- instalador wifi-setup (NetworkManager backbone).
#
# RESPONSABILIDAD UNICA: instalar el stack completo en un equipo Debian.
# No configura el cable LAN (eso es wifi lan setup, activacion manual).
# No conecta Tailscale (eso es wifi vpn up, activacion manual).
#
# FLUJO:
#   1. require_root + relaunch en tmux (supervivencia SSH)
#   2. limpieza de instalacion previa (idempotente)
#   3. deteccion: iface SSH, antenas WiFi (nativa + USB), ethernet
#   4. instalacion de paquetes (NM + iwd fallback + utilidades)
#   5. migracion de stack: parar iwd/dhcpcd, arrancar NM
#   6. credenciales WiFi + crear perfiles en cada antena
#   7. hardening SSH
#   8. tailscale install (sin conectar)
#   9. verificar estado, guardar install.state
#
# Requiere: root, conexion a internet.
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/deps.sh"
source "${SCRIPT_DIR}/lib/detect.sh"
source "${SCRIPT_DIR}/lib/nm.sh"
source "${SCRIPT_DIR}/lib/radio.sh"
source "${SCRIPT_DIR}/lib/vpn.sh"
source "${SCRIPT_DIR}/lib/ssh.sh"

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

Supervivencia SSH: el install corre dentro de tmux session 'wifi-setup'
para que si cae el SSH el proceso siga vivo. Cierra la ventana al terminar.
HELP
    exit 0
fi

require_root

INSTALL_MODE="server"   # conservado por compat, no afecta NM
BIN_DIR="/usr/local/bin"
WIFI_BIN="${BIN_DIR}/wifi"
WIFI_REPO_BIN="${SCRIPT_DIR}/bin/wifi"

# ---------------------------------------------------------------------------
# 1. Relaunch en tmux (supervivencia SSH)
# ---------------------------------------------------------------------------
_ensure_tmux() {
    command -v tmux >/dev/null 2>&1 && return 0
    info "instalando tmux..."
    apt-get update -qq >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq tmux >/dev/null 2>&1
    command -v tmux >/dev/null 2>&1 \
        || die "no se pudo instalar tmux"
}

_relaunch_in_tmux() {
    [[ "${WIFI_SETUP_INWIN:-0}" == "1" ]] && return 0
    _ensure_tmux

    local inner
    inner="export WIFI_SETUP_INWIN=1; "
    inner+="bash $(printf '%q' "${SCRIPT_DIR}/install.sh")"
    local a; for a in "$@"; do inner+=" $(printf '%q' "${a}")"; done
    inner+="; rc=\$?; echo; echo \"[wifi-setup] fin (rc=\$rc). Esta ventana queda abierta\"; exec bash -i"

    info "lanzando installer en tmux 'wifi-setup'..."
    if tmux has-session -t wifi-setup 2>/dev/null; then
        tmux new-window -t wifi-setup -n install "${inner}"
        tmux select-window -t wifi-setup:install 2>/dev/null || true
    else
        exec tmux new-session -s wifi-setup -n install "${inner}"
    fi
    exit 0
}

_relaunch_in_tmux "$@"

# Directorios base necesarios antes de cualquier operacion con snapshot.
require_dirs

# ---------------------------------------------------------------------------
# 2. Limpieza previa (idempotente)
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

    # Limpiar reglas iptables del proyecto (dirigido, no -F)
    while iptables -t nat -D POSTROUTING -j MASQUERADE 2>/dev/null; do :; done

    rm -f /etc/systemd/network/10-wifi-setup-*.network
    rm -f /etc/systemd/network/10-wifi-setup-*.link
    rm -f /etc/ssh/sshd_config.d/99-wifi-setup.conf
    rm -f /etc/sysctl.d/99-wifi-setup-forward.conf

    info "limpieza completada"
fi

# ---------------------------------------------------------------------------
# 3. Deteccion
# ---------------------------------------------------------------------------
echo ""
section "Deteccion de hardware"

SSH_IFACE="$(detect_ssh_iface 2>/dev/null || true)"
if [[ -n "${SSH_IFACE}" ]]; then
    info "sesion SSH entra por: ${SSH_IFACE}"
else
    info "sin sesion SSH detectada -- continuo"
fi

# Antenas WiFi
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
# Fallback: solo una antena -> PRIMARY
if [[ -z "${WIFI_PRIMARY}" && -n "${WIFI_SECONDARY}" ]]; then
    WIFI_PRIMARY="${WIFI_SECONDARY}"
    WIFI_SECONDARY=""
fi

info "antena PRIMARY  : ${WIFI_PRIMARY}"
info "antena SECONDARY: ${WIFI_SECONDARY:-—}"

# ---------------------------------------------------------------------------
# 4. Dependencias
# ---------------------------------------------------------------------------
echo ""
section "Dependencias"
install_deps

# ---------------------------------------------------------------------------
# 5. Migracion al stack NM
# ---------------------------------------------------------------------------
echo ""
section "Migrando stack de red"

# _migrate_to_nm: para iwd/dhcpcd/networkd, arranca NM. Se corre
# dentro de safe_run: snapshot + canary a tx1 + rollback automatico
# si el canary pierde contacto (NM mal -> sin WiFi -> sin Tailscale).
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
    sleep 3
    systemctl is-active NetworkManager >/dev/null 2>&1 \
        || die "NetworkManager no arranco -- revisa: journalctl -u NetworkManager -n 40"

    # NM necesita ver las antenas para gestionarlas.
    nmcli dev set "${WIFI_PRIMARY}" managed yes 2>/dev/null || true
    if [[ -n "${WIFI_SECONDARY}" ]]; then
        nmcli dev set "${WIFI_SECONDARY}" managed yes 2>/dev/null || true
    fi

    ok "NetworkManager activo"
}

if ! safe_run "migrate-nm" 120 _migrate_to_nm; then
    die "migracion a NetworkManager fallo o el acceso se perdio -- revisa ${LOG_DIR}/ops.log"
fi

# ---------------------------------------------------------------------------
# 6. Credenciales WiFi + perfiles
# ---------------------------------------------------------------------------
echo ""
section "Configuracion WiFi"

nm_require

declare -A SSID_BY_IFACE
declare -A PSK_BY_IFACE

# Reutilizar perfiles existentes si los hay
_existing_profiles="$(nmcli -t -f NAME,TYPE con show 2>/dev/null | awk -F: '$2=="802-11-wireless"{print $1}')"
if [[ -n "${_existing_profiles}" ]]; then
    info "perfiles WiFi existentes detectados -- se conservan"
    while IFS= read -r p; do
        [[ -n "${p}" ]] && info "  · ${p}"
    done <<< "${_existing_profiles}"
else
    info "no hay perfiles WiFi previos -- se requieren credenciales"
    read -r -p "SSID de la red WiFi: " WIFI_SSID
    [[ -n "${WIFI_SSID}" ]] || die "SSID vacio"
    read -r -s -p "PSK (min 8): " WIFI_PSK; echo
    [[ "${#WIFI_PSK}" -ge 8 ]] || die "PSK minimo 8 caracteres"

    for _if in "${WIFI_IFACES[@]}"; do
        SSID_BY_IFACE["${_if}"]="${WIFI_SSID}"
        PSK_BY_IFACE["${_if}"]="${WIFI_PSK}"
    done
    unset WIFI_PSK
fi

# Crear perfiles en cada antena (si no existian)
if [[ "${#SSID_BY_IFACE[@]}" -gt 0 ]]; then
    for _if in "${!SSID_BY_IFACE[@]}"; do
        _profile="wifi-${_if}-${SSID_BY_IFACE[$_if]}"
        nm_wifi_create "${_profile}" "${_if}" "${SSID_BY_IFACE[$_if]}" "${PSK_BY_IFACE[$_if]}"
        nm_con_set_autoconnect "${_profile}" on
    done
    unset PSK_BY_IFACE
fi

# Persistir roles de antena
RADIO_PRIMARY="${WIFI_PRIMARY}"
RADIO_SECONDARY="${WIFI_SECONDARY}"
_radio_save_state
radio_sync_priorities

# ---------------------------------------------------------------------------
# 7. SSH hardening
# ---------------------------------------------------------------------------
echo ""
section "SSH"
configure_ssh

# ---------------------------------------------------------------------------
# 8. Tailscale (install + daemon, sin conectar)
# ---------------------------------------------------------------------------
echo ""
section "VPN (Tailscale)"
vpn_install

# ---------------------------------------------------------------------------
# 9. Symlink + estado final
# ---------------------------------------------------------------------------
echo ""
section "Instalando comando"
chmod +x "${SCRIPT_DIR}/bin/wifi"
mkdir -p "${BIN_DIR}"
ln -sfn "${WIFI_REPO_BIN}" "${WIFI_BIN}"
ok "symlink: ${WIFI_BIN} -> ${WIFI_REPO_BIN}"

# Guardar install.state
cat > "${STATE_DIR}/install.state" <<EOF
INSTALL_MODE="${INSTALL_MODE}"
WIFI_PRIMARY="${WIFI_PRIMARY}"
WIFI_SECONDARY="${WIFI_SECONDARY}"
SSH_IFACE="${SSH_IFACE:-}"
EOF
chmod 600 "${STATE_DIR}/install.state"

# ---------------------------------------------------------------------------
# 10. Verificacion final
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
echo -e "${C_GREEN}  Log    : ${LOG_DIR}/wifi-setup.log${C_RESET}"
echo -e "${C_GREEN}  Comando: sudo wifi help${C_RESET}"
echo ""
