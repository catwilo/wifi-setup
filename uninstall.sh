#!/usr/bin/env bash
# uninstall.sh -- desinstalador wifi-setup.
#
# RESPONSABILIDAD UNICA: deshacer lo que install.sh hizo. No toca la
# configuracion WiFi/ethernet del sistema (los perfiles NM se borran
# a peticion, no automaticamente).
#
# FLUJO:
#   1. confirmar
#   2. parar unidades wifi-setup-*
#   3. sweep legacy
#   4. restaurar servicios de red (iwd disponible, NM sigue)
#   5. borrar symlink
#   6. limpiar sysctl/iptables/networkd/ssh
#   7. preguntar si borrar BASE_DIR (perfiles NM wifi-setup-*)
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    cat <<'HELP'
uso: sudo wifi uninstall

Desinstala wifi-setup:
  · detiene units wifi-setup-{forward,client,lan}
  · barre restos de instaladores viejos
  · desenmascara NetworkManager e iwd
  · elimina symlink /usr/local/bin/wifi
  · limpia sysctl, iptables, networkd configs, ssh config
  · pregunta si borrar /usr/local/share/wifi-setup (state, logs, config)

NO borra:
  · los perfiles NM del usuario (usa: nmcli con delete <name>)
  · los paquetes NetworkManager/iwd/tailscale
  · la config WiFi del sistema
HELP
    exit 0
fi

require_root

echo ""
echo -e "${C_BOLD}${C_RED}  wifi-setup uninstaller${C_RESET}"
echo ""
read -r -p "Confirmas desinstalar wifi-setup? [s/N]: " CONFIRM
[[ "${CONFIRM}" =~ ^[sS]$ ]] || { echo "cancelado."; exit 0; }

# ---------------------------------------------------------------------------
# 1. Unidades propias
# ---------------------------------------------------------------------------
for svc in wifi-setup-forward wifi-setup-client wifi-setup-lan; do
    if systemctl list-unit-files "${svc}.service" >/dev/null 2>&1; then
        systemctl stop    "${svc}" 2>/dev/null || true
        systemctl disable "${svc}" 2>/dev/null || true
        rm -f "/etc/systemd/system/${svc}.service"
        info "servicio eliminado: ${svc}"
    fi
done
systemctl daemon-reload

# ---------------------------------------------------------------------------
# 2. Sweep legacy (units wifi-setup@, binarios sueltos, /opt)
# ---------------------------------------------------------------------------
sweep_legacy_install

# ---------------------------------------------------------------------------
# 3. Desenmascarar NM + iwd (install los pudo haber enmascarado en v1)
# ---------------------------------------------------------------------------
for _unmask_svc in NetworkManager NetworkManager-wait-online iwd; do
    if systemctl is-enabled "${_unmask_svc}" 2>&1 | grep -q "masked"; then
        if systemctl unmask "${_unmask_svc}" 2>/dev/null; then
            info "${_unmask_svc} desenmascarado"
        else
            warn "no se pudo desenmascarar ${_unmask_svc}"
        fi
    fi
done

# ---------------------------------------------------------------------------
# 4. Symlink
# ---------------------------------------------------------------------------
rm -f "/usr/local/bin/wifi"
info "symlink eliminado"

# ---------------------------------------------------------------------------
# 5. sysctl
# ---------------------------------------------------------------------------
rm -f /etc/sysctl.d/99-wifi-setup-forward.conf
sysctl -w net.ipv4.ip_forward=0 >/dev/null 2>/dev/null || true
info "ip_forward=0"

# ---------------------------------------------------------------------------
# 6. iptables (dirigido, nunca -F)
# ---------------------------------------------------------------------------
if [[ -f "${STATE_DIR}/install.state" ]]; then
    # shellcheck source=/dev/null
    source "${STATE_DIR}/install.state"
    if [[ -n "${UPSTREAM_IFACE:-}" && -n "${PLAN_IFACE:-}" ]]; then
        iptables -t nat -D POSTROUTING -o "${UPSTREAM_IFACE}" -j MASQUERADE 2>/dev/null || true
        iptables -D FORWARD -i "${PLAN_IFACE}" -o "${UPSTREAM_IFACE}" -j ACCEPT 2>/dev/null || true
        iptables -D FORWARD -i "${UPSTREAM_IFACE}" -o "${PLAN_IFACE}" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    fi
fi
iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
info "reglas iptables limpiadas"

# ---------------------------------------------------------------------------
# 7. networkd + ssh configs
# ---------------------------------------------------------------------------
rm -f /etc/systemd/network/10-wifi-setup-*.network
rm -f /etc/systemd/network/10-wifi-setup-*.link
systemctl restart systemd-networkd 2>/dev/null || true
info "configs networkd eliminadas"

rm -f /etc/ssh/sshd_config.d/99-wifi-setup.conf
systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
info "config SSH wifi-setup eliminada"

# ---------------------------------------------------------------------------
# 8. BASE_DIR (state, logs, config) -- opcional
# ---------------------------------------------------------------------------
echo ""
read -r -p "Eliminar tambien ${BASE_DIR} (logs, state, config)? [s/N]: " DEL_DATA
if [[ "${DEL_DATA}" =~ ^[sS]$ ]]; then
    rm -rf "${BASE_DIR}"
    info "${BASE_DIR} eliminado"
else
    info "${BASE_DIR} preservado"
fi

echo ""
echo -e "${C_GREEN}  Desinstalacion completa.${C_RESET}"
echo ""
echo "  Los perfiles NM wifi-setup-* siguen existiendo."
echo "  Para borrarlos: nmcli con delete <nombre>  (ver: nmcli con show)"
echo ""
