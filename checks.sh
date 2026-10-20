#!/usr/bin/env bash
# checks.sh -- verificacion post-install (solo lectura).
#
# RESPONSABILIDAD UNICA: verificar que el stack este sano. Nunca muta
# nada. Imprime PASS/FAIL con hints de causa/fix.
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/nm.sh"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    cat <<'HELP'
uso: sudo bash checks.sh

Verifica que el stack wifi-setup este operativo:
  · NetworkManager activo
  · Antenas WiFi (PRIMARY/SECONDARY) visibles
  · Al menos una antena conectada con IP
  · Conectividad a internet + DNS
  · SSH escuchando en :22
  · Tailscale instalado (daemon activo)
  · iwd parado (fallback manual)
HELP
    exit 0
fi

# ---------------------------------------------------------------------------
# Guarda de plataforma: wifi-setup es Debian-only. En otras plataformas
# (Termux, macOS) sale limpiamente sin error -- el repo se distribuye a
# todos los nodos, pero solo instala en Debian.
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

# Auto-elevacion: si no somos root y hay TTY (via nssh -t), re-exec
# con sudo. sudo lee el password del TTY -- nunca de stdin redirigido,
# argv ni variables de entorno. Sin TTY, falla claro sin intentar
# (evita prompts colgados en contextos no interactivos).
if [[ "${EUID}" -ne 0 ]]; then
    if [[ -t 0 && -t 1 ]]; then
        info "elevando a root via sudo..."
        exec sudo bash "$0" "$@"
    fi
    die "requiere root y TTY -- corre: nssh -t <alias> 'sudo bash $(realpath "$0")'"
fi

PASS=0
FAIL=0

_pass() { echo -e "  ${C_GREEN}[OK]${C_RESET}    $*"; PASS=$((PASS + 1)); }
_fail() { echo -e "  ${C_RED}[FAIL]${C_RESET}  $*"; FAIL=$((FAIL + 1)); }
_warn() { echo -e "  ${C_YELLOW}[WARN]${C_RESET}  $*"; }
_hint() { echo -e "         ${C_YELLOW}→ $1${C_RESET}"; }

echo ""
echo -e "${C_BOLD}  wifi-setup check${C_RESET}"
echo ""

# ---------------------------------------------------------------------------
# NetworkManager
# ---------------------------------------------------------------------------
section "NetworkManager"
if systemctl is-active NetworkManager >/dev/null 2>&1; then
    _pass "NetworkManager activo"
else
    _fail "NetworkManager inactivo"
    _hint "systemctl start NetworkManager"
fi
if systemctl is-enabled NetworkManager >/dev/null 2>&1; then
    _pass "NetworkManager habilitado en boot"
else
    _fail "NetworkManager no habilitado"
    _hint "systemctl enable NetworkManager"
fi

# ---------------------------------------------------------------------------
# Antenas WiFi
# ---------------------------------------------------------------------------
section "Antenas WiFi"
_wifi_ifaces="$(nm_dev_wifi_list | awk -F: '{print $1}')"
if [[ -z "${_wifi_ifaces}" ]]; then
    _fail "ninguna antena WiFi detectada por NM"
    _hint "verifica: nmcli dev status"
else
    while IFS=: read -r _if _type _state _conn; do
        [[ -n "${_if}" ]] || continue
        _kind="nativa"
        _path="$(readlink -f "/sys/class/net/${_if}" 2>/dev/null || true)"
        [[ "${_path}" == *"/usb"* ]] && _kind="USB"
        if [[ "${_state}" == "connected" ]]; then
            _pass "${_if} (${_kind}): connected -> ${_conn}"
        else
            _warn "${_if} (${_kind}): ${_state}"
        fi
    done < <(nm_dev_wifi_list)
fi

# ---------------------------------------------------------------------------
# IP + internet
# ---------------------------------------------------------------------------
section "Conectividad"
_got_ip=0
while IFS= read -r _if; do
    [[ -n "${_if}" ]] || continue
    _ip="$(ip -4 -o addr show "${_if}" 2>/dev/null | awk '{print $4}' | head -1)"
    [[ -n "${_ip}" ]] && _got_ip=1
done <<< "${_wifi_ifaces}"

if [[ "${_got_ip}" -eq 1 ]]; then
    _pass "al menos una antena con IP"
else
    _fail "ninguna antena tiene IP"
    _hint "wifi status  &&  journalctl -u NetworkManager -n 30"
fi

if ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; then
    _pass "internet OK (ping 1.1.1.1)"
else
    _fail "sin internet"
    _hint "ip route show default"
fi

if getent hosts one.one.one.one >/dev/null 2>&1; then
    _pass "DNS OK"
else
    _fail "DNS no resuelve"
    _hint "cat /etc/resolv.conf"
fi

# ---------------------------------------------------------------------------
# SSH
# ---------------------------------------------------------------------------
section "SSH"
if systemctl is-active ssh >/dev/null 2>&1 || systemctl is-active sshd >/dev/null 2>&1; then
    _pass "sshd activo"
else
    _fail "sshd no activo"
    _hint "systemctl start ssh"
fi
if ss -tln 2>/dev/null | grep -q ':22 '; then
    _pass "puerto 22 escuchando"
else
    _fail "puerto 22 no escucha"
    _hint "journalctl -u ssh -n 30"
fi

# ---------------------------------------------------------------------------
# iwd (debe estar parado, es fallback)
# ---------------------------------------------------------------------------
section "iwd (fallback manual)"
if command -v iwctl >/dev/null 2>&1; then
    if systemctl is-active iwd >/dev/null 2>&1; then
        _warn "iwd activo -- NM no deberia tener competencia"
        _hint "systemctl stop iwd && systemctl disable iwd"
    else
        _pass "iwd instalado, parado (fallback listo)"
    fi
else
    _warn "iwd no instalado -- no habra fallback si NM falla"
fi

# ---------------------------------------------------------------------------
# Tailscale
# ---------------------------------------------------------------------------
section "Tailscale"
if command -v tailscale >/dev/null 2>&1; then
    _pass "tailscale instalado"
    if systemctl is-active tailscaled >/dev/null 2>&1; then
        _pass "tailscaled activo"
    else
        _warn "tailscaled inactivo"
    fi
    if tailscale status >/dev/null 2>&1; then
        _pass "tailscale conectado"
    else
        _warn "tailscale down (activa con: wifi vpn up)"
    fi
else
    _warn "tailscale no instalado"
fi

# ---------------------------------------------------------------------------
# LAN (opcional, solo reporta)
# ---------------------------------------------------------------------------
section "LAN"
if [[ -f "${STATE_DIR}/lan.state" ]]; then
    # shellcheck source=/dev/null
    source "${STATE_DIR}/lan.state"
    _pass "perfil LAN configurado (mode=${LAN_MODE:-—})"
    if nm_dev_ethernet_list | awk -F: -v i="${LAN_IFACE}" '$1==i && $3=="connected"{exit 0} END{exit 1}'; then
        _pass "cable LAN activo en ${LAN_IFACE}"
    else
        _warn "cable LAN inactivo (activa con: wifi lan up)"
    fi
else
    _warn "LAN no configurado (opcional -- usa: wifi lan setup)"
fi

# ---------------------------------------------------------------------------
# Resumen
# ---------------------------------------------------------------------------
echo ""
echo -e "${C_BOLD}  ──────────────────────────────────────────${C_RESET}"
if [[ "${FAIL}" -eq 0 ]]; then
    echo -e "${C_GREEN}${C_BOLD}  OK: todos los checks pasaron (${PASS})${C_RESET}"
else
    echo -e "${C_RED}${C_BOLD}  FALLA: ${FAIL} check(s) -- ${PASS} OK${C_RESET}"
fi
echo -e "${C_BOLD}  ──────────────────────────────────────────${C_RESET}"
echo ""

[[ "${FAIL}" -eq 0 ]]
