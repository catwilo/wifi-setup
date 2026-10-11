#!/usr/bin/env bash
# lib/common.sh -- base compartida obligatoria.
#
# RESPONSABILIDAD UNICA: bootstrap comun. Debe sourcearse ANTES que
# cualquier otro lib. Define:
#   - set -Eeuo pipefail + umask 077
#   - directorios BASE/LOG/STATE/CONFIG
#   - colores ANSI
#   - source de log.sh + safe.sh
#   - helpers: die, require_root, require_dirs, validate_interface
#   - sweep_legacy_install (instalaciones previas del esquema viejo)
#
# Requiere: correr con bash (no sh).

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

BASE_DIR="/usr/local/share/wifi-setup"
LOG_DIR="${BASE_DIR}/logs"
STATE_DIR="${BASE_DIR}/state"
CONFIG_DIR="${BASE_DIR}/config"

# ---------------------------------------------------------------------------
# Colores ANSI (solo si stdout es terminal)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'
    C_CYAN='\033[0;36m'; C_BOLD='\033[1m'; C_RESET='\033[0m'
else
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''; C_BOLD=''; C_RESET=''
fi

# ---------------------------------------------------------------------------
# Cargar modulos base
# ---------------------------------------------------------------------------
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/log.sh"
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/safe.sh"

# ---------------------------------------------------------------------------
# die -- mensaje de error + exit 1.
# ---------------------------------------------------------------------------
die() {
    err "$*"
    exit 1
}

# ---------------------------------------------------------------------------
# require_dirs -- crea y asegura los directorios base.
# ---------------------------------------------------------------------------
require_dirs() {
    mkdir -p "${STATE_DIR}" "${LOG_DIR}" "${CONFIG_DIR}"
    chmod 700 "${CONFIG_DIR}" "${LOG_DIR}" "${STATE_DIR}"
}

# ---------------------------------------------------------------------------
# require_root -- aborta si no somos root.
# ---------------------------------------------------------------------------
require_root() {
    [[ "${EUID}" -eq 0 ]] || die "requiere root -- usa: sudo wifi $*"
}

# ---------------------------------------------------------------------------
# validate_interface <iface> -- aborta si la iface no existe.
# ---------------------------------------------------------------------------
validate_interface() {
    local iface="$1"
    [[ -n "${iface}" ]] || die "validate_interface: iface vacia"
    ip link show "${iface}" >/dev/null 2>&1 \
        || die "interfaz '${iface}' no encontrada -- verifica: ip link show"
}

# ---------------------------------------------------------------------------
# backup_file <file> -- copia <file> a <file>.bak.<timestamp>.
# ---------------------------------------------------------------------------
backup_file() {
    local f="$1"
    [[ -f "${f}" ]] || return 0
    cp -a "${f}" "${f}.bak.$(date +%s)"
}

# ---------------------------------------------------------------------------
# sweep_legacy_install -- limpia restos del instalador viejo (/opt/wifi-setup,
# units wifi-setup@, binarios sueltos). Idempotente.
# ---------------------------------------------------------------------------
sweep_legacy_install() {
    local found=0
    local unit

    while IFS= read -r unit; do
        [[ -z "${unit}" ]] && continue
        systemctl stop    "${unit}" 2>/dev/null || true
        systemctl disable "${unit}" 2>/dev/null || true
        found=1
        info "unit legacy: ${unit}"
    done < <(systemctl list-units --all --plain --no-legend 'wifi-setup@*' 2>/dev/null | awk '{print $1}')

    if compgen -G "/etc/systemd/system/wifi-setup@*.service" >/dev/null 2>&1; then
        rm -f /etc/systemd/system/wifi-setup@*.service
        found=1
    fi

    local b
    for b in wifi-panic wfs wifi-status wifi-list wifi-passwd wifi-showpass; do
        if [[ -L "/usr/local/bin/${b}" || -f "/usr/local/bin/${b}" ]]; then
            rm -f "/usr/local/bin/${b}"
            found=1
        fi
    done

    if [[ -d /opt/wifi-setup ]]; then
        rm -rf /opt/wifi-setup
        found=1
        info "eliminado /opt/wifi-setup (esquema viejo)"
    fi

    if [[ "${found}" -eq 1 ]]; then
        systemctl daemon-reload 2>/dev/null || true
        info "barrido legacy completado"
    fi
}
