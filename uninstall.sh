#!/usr/bin/env bash
# scripts/uninstall.sh — limpieza completa
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
    echo "uso: sudo wifi uninstall"
    echo ""
    echo "Desinstala wifi-setup completamente:"
    echo "  · detiene y elimina servicios wifi-setup-forward y wifi-setup-client"
    echo "  · elimina symlinks en /usr/local/bin"
    echo "  · deshabilita ip_forward y limpia sysctl"
    echo "  · limpia reglas iptables del proyecto"
    echo "  · elimina configs systemd-networkd del proyecto"
    echo "  · elimina config SSH del proyecto (sshd_config base intacto)"
    echo "  · pregunta si eliminar /opt/wifi-setup (datos, logs, config)"
    exit 0
fi

require_root

echo ""
echo -e "${C_BOLD}${C_RED}╔══════════════════════════════════════════╗${C_RESET}"
echo -e "${C_BOLD}${C_RED}║         wifi-setup  uninstaller          ║${C_RESET}"
echo -e "${C_BOLD}${C_RED}╚══════════════════════════════════════════╝${C_RESET}"
echo ""
read -r -p "¿Confirmas desinstalar wifi-setup completamente? [s/N]: " CONFIRM
[[ "${CONFIRM}" =~ ^[sS]$ ]] || { echo "cancelado."; exit 0; }

# Servicios propios
for svc in wifi-setup-forward wifi-setup-client; do
    if systemctl list-unit-files "${svc}.service" >/dev/null 2>&1; then
        systemctl stop "${svc}" 2>/dev/null || true
        systemctl disable "${svc}" 2>/dev/null || true
        rm -f "/etc/systemd/system/${svc}.service"
        log "INFO" "servicio eliminado: ${svc}"
    fi
done
systemctl daemon-reload

# Barrer restos de instaladores VIEJOS (wifi-setup@.service, wifi-panic, services/)
sweep_legacy_install

# Symlinks
rm -f "/usr/local/bin/wifi"
log "INFO" "symlinks eliminados"

# sysctl
rm -f /etc/sysctl.d/99-wifi-setup-forward.conf
sysctl -w net.ipv4.ip_forward=0 >/dev/null 2>/dev/null || true
log "INFO" "ip_forward deshabilitado"

# iptables (limpiar reglas de este proyecto)
iptables -t nat -F POSTROUTING 2>/dev/null || true
iptables -F FORWARD 2>/dev/null || true
iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
log "INFO" "reglas iptables limpiadas"

# networkd configs
rm -f /etc/systemd/network/10-wifi-setup-*.network
systemctl restart systemd-networkd 2>/dev/null || true
log "INFO" "configs networkd eliminadas"

# SSH config propia (no toca sshd_config base)
rm -f /etc/ssh/sshd_config.d/99-wifi-setup.conf
systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
log "INFO" "config SSH wifi-setup eliminada (sshd_config base intacto)"

echo ""
read -r -p "¿Eliminar también /opt/wifi-setup (logs, state, config)? [s/N]: " DEL_DATA
if [[ "${DEL_DATA}" =~ ^[sS]$ ]]; then
    rm -rf /opt/wifi-setup
    log "INFO" "/opt/wifi-setup eliminado"
else
    log "INFO" "/opt/wifi-setup preservado"
fi

echo ""
echo -e "${C_GREEN}ok: desinstalación completa${C_RESET}"
