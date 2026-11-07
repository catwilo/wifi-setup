#!/usr/bin/env bash
# install.sh -- wifi-setup installer.
#
# Instala la herramienta. NO toca la configuracion de red:
#   - no migra iwd <-> NetworkManager
#   - no crea perfiles WiFi
#   - no aplica hardening SSH
#   - no instala ni arranca Tailscale
#   - no toca /etc/network/interfaces
#
# Esas acciones son comandos explicitos despues del install:
#   sudo wifi clean            limpia residuos de instalaciones canceladas
#   sudo wifi fallback off     migrar a NetworkManager (con rollback)
#   sudo wifi add              crear perfil WiFi
#   sudo wifi ssh harden       hardening SSH
#   sudo wifi vpn install      instalar Tailscale
#
# Deja:
#   - apt: NetworkManager, iwd, iw, iproute2, curl, iputils-ping,
#     systemd-resolved, tmux (para relaunch interactivo de wifi add)
#   - symlink /usr/local/bin/wifi -> repo/bin/wifi
#   - /usr/local/share/wifi-setup/{state,config,logs}
#   - wifi-boot-fallback.service (fallback de antena al arranque)
#   - install.state: mode, version, fecha. Sin ifaces persistentes.
#
# Idempotente: re-ejecutar converge al mismo estado.
# Requiere: Debian, TTY, conexion a internet.

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    cat <<'HELP'
uso: sudo bash install.sh

Instala la herramienta wifi-setup. NO toca la configuracion de red.

Deja:
  - Dependencias apt (NetworkManager, iwd, iw, iproute2, curl, ping)
  - /usr/local/bin/wifi (symlink al repo)
  - /usr/local/share/wifi-setup/{state,config,logs}
  - wifi-boot-fallback.service (fallback de antena al arranque)
  - install.state (modo, version, fecha; sin ifaces persistentes)

Despues del install:
  sudo wifi help             lista de subcomandos
  sudo wifi clean            limpia residuos de instalaciones canceladas
  sudo wifi fallback off     migrar a NetworkManager (con rollback)
  sudo wifi add              crear perfil WiFi
  sudo wifi ssh harden       hardening SSH
  sudo wifi vpn install      instalar Tailscale

Requisitos: Debian 13+, TTY, conexion a internet.
HELP
    exit 0
fi

_require_debian() {
    [[ -n "${PREFIX:-}" ]] && [[ -d "${PREFIX}/bin" ]] && return 1
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

[[ "${EUID}" -eq 0 ]] || die "install.sh requiere root -- usa: sudo bash install.sh"
[[ -t 0 && -t 1 ]] || die "install.sh requiere TTY -- usa: ssh -t <host> o consola fisica"

source "${SCRIPT_DIR}/lib/deps.sh"

mkdir -p "${BASE_DIR}" "${STATE_DIR}" "${LOG_DIR}" "${CONFIG_DIR}"
chmod 700 "${BASE_DIR}" "${STATE_DIR}" "${LOG_DIR}" "${CONFIG_DIR}"

echo ""
section "Instalacion de wifi-setup"

# 1. Limpieza de esquemas legacy (no toca config actual).
sweep_legacy_install

# 2. Dependencias apt.
install_deps

# 3. Symlink PRIMERO: `wifi` disponible aunque algo falle despues.
chmod +x "${SCRIPT_DIR}/bin/wifi"
ln -sfn "${SCRIPT_DIR}/bin/wifi" "/usr/local/bin/wifi"
ok "symlink: /usr/local/bin/wifi -> ${SCRIPT_DIR}/bin/wifi"

# 4. wifi-boot-fallback.service (renombrado de wifi-setup-radio-boot).
#    Corre al arranque: si la primaria no tiene IP tras wait-online,
#    activa la secundaria. Idempotente (no reescribe si no cambio).
_wifi_boot_unit="/etc/systemd/system/wifi-boot-fallback.service"
_wifi_boot_desired=$(cat <<'UNIT'
[Unit]
Description=wifi-setup antenna boot fallback (secondary if primary has no IP)
After=NetworkManager.service NetworkManager-wait-online.service
Wants=NetworkManager.service NetworkManager-wait-online.service
ConditionPathExists=/usr/local/bin/wifi

[Service]
Type=oneshot
ExecStart=/usr/local/bin/wifi radio boot
RemainAfterExit=no
TimeoutStartSec=180

[Install]
WantedBy=multi-user.target
UNIT
)
if [[ -f "${_wifi_boot_unit}" ]] && [[ "$(cat "${_wifi_boot_unit}")" == "${_wifi_boot_desired}" ]]; then
    info "wifi-boot-fallback.service sin cambios"
else
    printf '%s\n' "${_wifi_boot_desired}" > "${_wifi_boot_unit}"
    chmod 644 "${_wifi_boot_unit}"
    systemctl daemon-reload 2>/dev/null || true
    ok "wifi-boot-fallback.service escrito"
fi
systemctl enable wifi-boot-fallback 2>/dev/null || true

# Legacy: nombre viejo del unit.
_legacy_boot="/etc/systemd/system/wifi-setup-radio-boot.service"
if [[ -e "${_legacy_boot}" ]]; then
    systemctl stop wifi-setup-radio-boot 2>/dev/null || true
    systemctl disable wifi-setup-radio-boot 2>/dev/null || true
    rm -f "${_legacy_boot}"
    systemctl reset-failed wifi-setup-radio-boot 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    info "unit legacy eliminado: wifi-setup-radio-boot"
fi

# 5. install.state minimo: sin ifaces persistentes.
_install_version="$(git -C "${SCRIPT_DIR}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
cat > "${STATE_DIR}/install.state" <<EOF
INSTALL_MODE="server"
INSTALL_VERSION="${_install_version}"
INSTALL_DATE="$(date -Is)"
EOF
chmod 600 "${STATE_DIR}/install.state"
ok "install.state escrito"

# 6. Verificacion final.
echo ""
section "Verificacion"
_fail=0
_check() {
    local label="$1" ok="$2"
    if [[ "$ok" == "1" ]]; then
        printf '  %s[PASS]%s %s\n' "${C_GREEN}" "${C_RESET}" "${label}" >&2
    else
        printf '  %s[FAIL]%s %s\n' "${C_RED}" "${C_RESET}" "${label}" >&2
        _fail=$((_fail + 1))
    fi
}
if [[ -x /usr/local/bin/wifi ]]; then _check "symlink /usr/local/bin/wifi" 1; else _check "symlink /usr/local/bin/wifi" 0; fi
if [[ -f "${STATE_DIR}/install.state" ]]; then _check "install.state" 1; else _check "install.state" 0; fi
if command -v nmcli >/dev/null 2>&1; then _check "nmcli instalado" 1; else _check "nmcli instalado" 0; fi
if command -v iwctl >/dev/null 2>&1; then _check "iwctl instalado" 1; else _check "iwctl instalado" 0; fi
if [[ -f "${_wifi_boot_unit}" ]]; then _check "wifi-boot-fallback.service" 1; else _check "wifi-boot-fallback.service" 0; fi
if /usr/local/bin/wifi -h >/dev/null 2>&1; then _check "wifi -h responde" 1; else _check "wifi -h responde" 0; fi

if [[ "${_fail}" -gt 0 ]]; then
    err "instalacion termino con ${_fail} fallo(s)"
    exit 1
fi

echo "" >&2
info "Instalacion completa. La herramienta esta lista; la red NO se toco."
info ""
info "  sudo wifi help           lista de subcomandos"
info "  sudo wifi clean          limpia residuos de instalaciones canceladas"
info "  sudo wifi fallback off   migrar a NetworkManager (con rollback)"
info "  sudo wifi add            crear perfil WiFi"
info "  sudo wifi ssh harden     hardening SSH"
info "  sudo wifi vpn install    instalar Tailscale"
echo "" >&2
