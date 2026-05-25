#!/usr/bin/env bash
# scripts/checks.sh — verificación final con diagnóstico explícito
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
    echo "uso: sudo wifi check <server|client>"
    echo ""
    echo "Verifica que la instalación esté correcta y funcionando."
    echo "Lee el estado guardado en /opt/wifi-setup/state/install.state"
    echo ""
    echo "Checks comunes (ambos modos):"
    echo "  · SSH activo en puerto 22 y habilitado en boot"
    echo "  · Tailscale instalado y daemon activo"
    echo "  · interfaz WiFi upstream UP con IP"
    echo "  · conectividad a internet (1.1.1.1, 8.8.8.8)"
    echo "  · resolución DNS"
    echo ""
    echo "Checks modo servidor:"
    echo "  · IP 1.2.3.2 en interfaz plan"
    echo "  · ip_forward=1 y persistencia sysctl"
    echo "  · regla NAT MASQUERADE activa y persistida"
    echo "  · servicio wifi-setup-forward activo"
    echo "  · ping al cliente 1.2.3.1"
    echo ""
    echo "Checks modo cliente:"
    echo "  · IP 1.2.3.1 en interfaz plan"
    echo "  · ruta default vía 1.2.3.2"
    echo "  · servicio wifi-setup-client activo"
    exit 0
fi

require_root

MODE="${1:-}"  # server | client

# ---------------------------------------------------------------------------
# Helpers de output
# ---------------------------------------------------------------------------
CHECKS_PASSED=0
CHECKS_FAILED=0

check_ok() {
    echo -e "  ${C_GREEN}[OK]${C_RESET}  $*"
    (( CHECKS_PASSED++ )) || true
}

check_fail() {
    echo -e "  ${C_RED}[FAIL]${C_RESET} $*"
    (( CHECKS_FAILED++ )) || true
}

check_warn() {
    echo -e "  ${C_YELLOW}[WARN]${C_RESET} $*"
}

section() {
    echo ""
    echo -e "${C_BOLD}${C_CYAN}▶ $*${C_RESET}"
}

hint() {
    echo -e "         ${C_YELLOW}→ causa : $1${C_RESET}"
    echo -e "         ${C_YELLOW}→ fix   : $2${C_RESET}"
}

# ---------------------------------------------------------------------------
# Cargar estado del install
# ---------------------------------------------------------------------------
STATE_FILE="${STATE_DIR}/install.state"
if [[ -f "${STATE_FILE}" ]]; then
    # shellcheck source=/dev/null
    source "${STATE_FILE}"
else
    log "WARN" "no se encontró ${STATE_FILE} — ejecuta install.sh primero"
fi

MODE="${MODE:-${INSTALL_MODE:-}}"
[[ -n "${MODE}" ]] || { echo "uso: checks.sh <server|client>"; exit 1; }

UPSTREAM_IFACE="${UPSTREAM_IFACE:-}"
PLAN_IFACE="${PLAN_IFACE:-}"
WIFI_IFACE="${WIFI_IFACE:-}"
PLAN_IP="${PLAN_IP:-1.2.3.2}"
PLAN_CIDR="${PLAN_CIDR:-1.2.3.2/24}"
CLIENT_IP="${CLIENT_IP:-1.2.3.1}"
STATIC_IFACE="${STATIC_IFACE:-}"
STATIC_CIDR="${STATIC_CIDR:-}"
GATEWAY="${GATEWAY:-}"

echo ""
echo -e "${C_BOLD}════════════════════════════════════════════${C_RESET}"
echo -e "${C_BOLD}  wifi-setup — verificación modo: ${MODE^^}${C_RESET}"
echo -e "${C_BOLD}════════════════════════════════════════════${C_RESET}"

# ===========================================================================
# CHECKS COMUNES
# ===========================================================================

section "SSH"
if systemctl is-active ssh >/dev/null 2>&1 || systemctl is-active sshd >/dev/null 2>&1; then
    check_ok "SSH activo (puerto 22)"
else
    check_fail "SSH no está activo"
    hint "sshd no corriendo" "systemctl start ssh && systemctl enable ssh"
fi

if ss -tlnp 2>/dev/null | grep -q ':22 '; then
    check_ok "puerto 22 escuchando"
else
    check_fail "puerto 22 no está escuchando"
    hint "sshd puede estar en otro puerto o falló el bind" \
         "sshd -t && journalctl -u ssh -n 20"
fi

if systemctl is-enabled ssh >/dev/null 2>&1 || systemctl is-enabled sshd >/dev/null 2>&1; then
    check_ok "SSH habilitado en boot"
else
    check_fail "SSH no está habilitado en boot"
    hint "el servicio existe pero no está en autostart" "systemctl enable ssh"
fi

section "Tailscale"
if command -v tailscale >/dev/null 2>&1; then
    check_ok "tailscale instalado: $(tailscale version 2>/dev/null | head -1)"
else
    check_fail "tailscale no encontrado"
    hint "no se instaló correctamente" "curl -fsSL https://tailscale.com/install.sh | bash"
fi

if systemctl is-active tailscaled >/dev/null 2>&1; then
    check_ok "tailscaled daemon activo (túnel inactivo hasta 'tailscale up')"
else
    check_warn "tailscaled no está activo — normal si aún no se ejecutó install.sh"
fi

section "Interfaz WiFi principal (upstream)"
if [[ -n "${UPSTREAM_IFACE}" ]]; then
    if ip link show "${UPSTREAM_IFACE}" >/dev/null 2>&1; then
        STATE=$(ip link show "${UPSTREAM_IFACE}" | grep -oP '(?<=state )\w+' || echo "UNKNOWN")
        if [[ "${STATE}" == "UP" ]]; then
            check_ok "interfaz ${UPSTREAM_IFACE} UP"
        else
            check_fail "interfaz ${UPSTREAM_IFACE} estado: ${STATE}"
            hint "la interfaz existe pero no está activa" \
                 "ip link set ${UPSTREAM_IFACE} up && systemctl restart wpa_supplicant@${UPSTREAM_IFACE}"
        fi
    else
        check_fail "interfaz ${UPSTREAM_IFACE} no encontrada en el sistema"
        hint "puede haber cambiado de nombre o no estar conectada" \
             "ip link show — verifica qué interfaces están disponibles"
    fi

    # Verificar IP en upstream (DHCP)
    IP_UPSTREAM=$(ip addr show "${UPSTREAM_IFACE}" 2>/dev/null | grep -oP '(?<=inet )\S+' | head -1 || true)
    if [[ -n "${IP_UPSTREAM}" ]]; then
        check_ok "${UPSTREAM_IFACE} tiene IP: ${IP_UPSTREAM}"
    else
        check_fail "${UPSTREAM_IFACE} no tiene IP asignada"
        hint "wpa_supplicant puede no haberse autenticado o DHCP falló" \
             "systemctl status wpa_supplicant@${UPSTREAM_IFACE} && dhcpcd -n ${UPSTREAM_IFACE}"
    fi
else
    check_warn "UPSTREAM_IFACE no definido en state — omitiendo checks de upstream"
fi

section "Conectividad a Internet"
if ping -c2 -W3 1.1.1.1 >/dev/null 2>&1; then
    check_ok "ping 1.1.1.1 OK"
else
    check_fail "sin conectividad a 1.1.1.1"
    hint "no hay ruta hacia internet" \
         "ip route show && ping -c1 \$(ip route | awk '/default/{print \$3}') — verifica gateway"
fi

if ping -c2 -W3 8.8.8.8 >/dev/null 2>&1; then
    check_ok "ping 8.8.8.8 OK"
else
    check_fail "sin conectividad a 8.8.8.8"
    hint "posible bloqueo de ICMP o sin ruta" "ip route show default"
fi

if getent hosts one.one.one.one >/dev/null 2>&1; then
    check_ok "resolución DNS OK (one.one.one.one)"
else
    check_fail "DNS no resuelve"
    hint "sin resolución DNS" \
         "cat /etc/resolv.conf — agrega 'nameserver 1.1.1.1' si está vacío"
fi

# ===========================================================================
# CHECKS MODO SERVIDOR
# ===========================================================================
if [[ "${MODE}" == "server" ]]; then

    section "IP estática en interfaz plan"
    if [[ -n "${PLAN_IFACE}" ]]; then
        IP_PLAN=$(ip addr show "${PLAN_IFACE}" 2>/dev/null | grep -oP '(?<=inet )\S+' | head -1 || true)
        if [[ "${IP_PLAN}" == "${PLAN_CIDR}" ]] || [[ "${IP_PLAN}" == "${PLAN_IP}"* ]]; then
            check_ok "${PLAN_IFACE} tiene IP plan: ${IP_PLAN}"
        else
            check_fail "${PLAN_IFACE} no tiene la IP plan esperada (esperado: ${PLAN_CIDR}, actual: ${IP_PLAN:-ninguna})"
            hint "la IP no se aplicó o se perdió tras reinicio" \
                 "ip addr add ${PLAN_CIDR} dev ${PLAN_IFACE} && systemctl restart wifi-setup-forward"
        fi
    else
        check_warn "PLAN_IFACE no definido — omitiendo checks de IP plan"
    fi

    section "IP Forwarding"
    FWD=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo "0")
    if [[ "${FWD}" == "1" ]]; then
        check_ok "ip_forward = 1 (habilitado)"
    else
        check_fail "ip_forward = 0 — el forwarding está DESACTIVADO"
        hint "/proc/sys/net/ipv4/ip_forward = 0" \
             "sysctl -w net.ipv4.ip_forward=1 && systemctl restart wifi-setup-forward"
    fi

    if [[ -f /etc/sysctl.d/99-wifi-setup-forward.conf ]]; then
        check_ok "sysctl persistente: /etc/sysctl.d/99-wifi-setup-forward.conf"
    else
        check_fail "sysctl persistente no encontrado — ip_forward se perderá al reiniciar"
        hint "el archivo no fue creado" \
             "echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-wifi-setup-forward.conf && sysctl -p /etc/sysctl.d/99-wifi-setup-forward.conf"
    fi

    section "NAT / iptables"
    if iptables -t nat -L POSTROUTING -n 2>/dev/null | grep -q 'MASQUERADE'; then
        check_ok "regla NAT MASQUERADE activa en iptables"
    else
        check_fail "regla NAT MASQUERADE NO encontrada en iptables"
        hint "las reglas no se aplicaron o se perdieron" \
             "iptables -t nat -A POSTROUTING -o ${UPSTREAM_IFACE:-<upstream>} -j MASQUERADE"
    fi

    if [[ -f /etc/iptables/rules.v4 ]] && grep -q 'MASQUERADE' /etc/iptables/rules.v4 2>/dev/null; then
        check_ok "reglas iptables persistidas en /etc/iptables/rules.v4"
    else
        check_fail "reglas iptables NO persistidas — se perderán al reiniciar"
        hint "/etc/iptables/rules.v4 no tiene MASQUERADE" \
             "iptables-save > /etc/iptables/rules.v4 && systemctl enable netfilter-persistent"
    fi

    section "Servicio wifi-setup-forward (persistencia)"
    if systemctl is-active wifi-setup-forward >/dev/null 2>&1; then
        check_ok "wifi-setup-forward activo"
    else
        check_fail "wifi-setup-forward no está activo"
        hint "el servicio falló o no está instalado" \
             "systemctl status wifi-setup-forward && journalctl -u wifi-setup-forward -n 20"
    fi

    if systemctl is-enabled wifi-setup-forward >/dev/null 2>&1; then
        check_ok "wifi-setup-forward habilitado en boot"
    else
        check_fail "wifi-setup-forward no habilitado en boot"
        hint "el servicio existe pero no está en autostart" \
             "systemctl enable wifi-setup-forward"
    fi

    section "Conectividad al cliente plan"
    if ping -c2 -W2 "${CLIENT_IP}" >/dev/null 2>&1; then
        check_ok "ping al cliente ${CLIENT_IP} OK"
    else
        check_warn "ping al cliente ${CLIENT_IP} sin respuesta — puede que el cliente no esté encendido o ICMP bloqueado"
    fi

fi

# ===========================================================================
# CHECKS MODO CLIENTE
# ===========================================================================
if [[ "${MODE}" == "client" ]]; then

    section "IP estática en interfaz plan"
    if [[ -n "${STATIC_IFACE}" ]]; then
        IP_STATIC=$(ip addr show "${STATIC_IFACE}" 2>/dev/null | grep -oP '(?<=inet )\S+' | head -1 || true)
        if [[ "${IP_STATIC}" == "${CLIENT_IP}"* ]]; then
            check_ok "${STATIC_IFACE} tiene IP: ${IP_STATIC}"
        else
            check_fail "${STATIC_IFACE} no tiene la IP esperada (esperado: ${CLIENT_IP}/24, actual: ${IP_STATIC:-ninguna})"
            hint "la IP estática no se aplicó" \
                 "ip addr add ${CLIENT_IP}/24 dev ${STATIC_IFACE} && systemctl restart wifi-setup-client"
        fi
    else
        check_warn "STATIC_IFACE no definido en state"
    fi

    section "Ruta default hacia servidor"
    DEFAULT_GW=$(ip route show default 2>/dev/null | grep -oP '(?<=via )\S+' | head -1 || true)
    if [[ "${DEFAULT_GW}" == "1.2.3.2" ]]; then
        check_ok "ruta default vía 1.2.3.2 (servidor) OK"
    else
        check_fail "ruta default apunta a '${DEFAULT_GW:-ninguna}' — debería ser 1.2.3.2"
        hint "la ruta default no está configurada correctamente" \
             "ip route del default 2>/dev/null; ip route add default via 1.2.3.2"
    fi

    section "Servicio wifi-setup-client (persistencia)"
    if systemctl is-active wifi-setup-client >/dev/null 2>&1; then
        check_ok "wifi-setup-client activo"
    else
        check_fail "wifi-setup-client no está activo"
        hint "el servicio falló o no está instalado" \
             "systemctl status wifi-setup-client && journalctl -u wifi-setup-client -n 20"
    fi

    if systemctl is-enabled wifi-setup-client >/dev/null 2>&1; then
        check_ok "wifi-setup-client habilitado en boot"
    else
        check_fail "wifi-setup-client no habilitado en boot"
        hint "" "systemctl enable wifi-setup-client"
    fi

fi

# ===========================================================================
# RESUMEN FINAL
# ===========================================================================
echo ""
echo -e "${C_BOLD}════════════════════════════════════════════${C_RESET}"
if [[ "${CHECKS_FAILED}" -eq 0 ]]; then
    echo -e "${C_GREEN}${C_BOLD}  ✓ TODOS LOS CHECKS PASARON (${CHECKS_PASSED} OK)${C_RESET}"
else
    echo -e "${C_RED}${C_BOLD}  ✗ ${CHECKS_FAILED} CHECK(S) FALLARON — ${CHECKS_PASSED} OK${C_RESET}"
fi
echo -e "${C_BOLD}════════════════════════════════════════════${C_RESET}"
echo ""

[[ "${CHECKS_FAILED}" -eq 0 ]]
