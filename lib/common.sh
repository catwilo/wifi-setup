#!/usr/bin/env bash
# lib/common.sh — base compartida para todos los scripts
# Requisito: sourced desde scripts que ya tienen set -Eeuo pipefail
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

BASE_DIR="/opt/wifi-setup"
LOG_DIR="${BASE_DIR}/logs"
STATE_DIR="${BASE_DIR}/state"
CONFIG_DIR="${BASE_DIR}/config"

# ---------------------------------------------------------------------------
# Colores (solo si stdout es terminal)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'
    C_CYAN='\033[0;36m'; C_BOLD='\033[1m'; C_RESET='\033[0m'
else
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''; C_BOLD=''; C_RESET=''
fi

# ---------------------------------------------------------------------------
# Logging modular (lib/log.sh): section/step/ok/warn/err/info + spinner TTY.
# ---------------------------------------------------------------------------
source "$(dirname "${BASH_SOURCE[0]}")/log.sh"

# Shim de compatibilidad: mapea las llamadas log "NIVEL" al nuevo formato.
log() {
    local level="$1"; shift
    case "${level}" in
        INFO)  info "$*" ;;
        WARN)  warn "$*" ;;
        ERROR) err  "$*" ;;
        *)     info "$*" ;;
    esac
}

die() {
    log "ERROR" "$*"
    exit 1
}

# ---------------------------------------------------------------------------
# Dirs
# ---------------------------------------------------------------------------
require_dirs() {
    mkdir -p "${BASE_DIR}"/{bin,lib,config,state,logs}
    chmod 700 "${BASE_DIR}"/config "${BASE_DIR}"/logs "${BASE_DIR}"/state
}

# ---------------------------------------------------------------------------
# Root guard
# ---------------------------------------------------------------------------
require_root() {
    [[ "${EUID}" -eq 0 ]] || die "debe ejecutarse como root (usa sudo)"
}

# ---------------------------------------------------------------------------
# Validar interfaz
# ---------------------------------------------------------------------------
validate_interface() {
    local iface="$1"
    ip link show "${iface}" >/dev/null 2>&1 \
        || die "interfaz '${iface}' no encontrada — verifica con: ip link show"
}

# ---------------------------------------------------------------------------
# Backup / rollback
# ---------------------------------------------------------------------------
backup_file() {
    [[ -f "$1" ]] && cp -a "$1" "$1.bak.$(date +%s)"
}

rollback_network() {
    if [[ -f "$1" ]]; then
        cp -f "$1" "$2"
        log "INFO" "rollback aplicado: $2"
    fi
}

# ---------------------------------------------------------------------------
# Barrer restos de instaladores VIEJOS de wifi-setup (esquemas anteriores).
# Idempotente. Elimina:
#   - units template/instancia wifi-setup@*.service (recovery viejo)
#   - binarios sueltos: bin/wifi-panic, /usr/local/bin/wifi-panic, wfs, etc.
#   - carpeta heredada /opt/wifi-setup/services
# No toca las units actuales (wifi-setup-forward / wifi-setup-client).
# ---------------------------------------------------------------------------
sweep_legacy_install() {
    local found=0

    # Units wifi-setup@*.service (template + instancias)
    local unit
    while IFS= read -r unit; do
        [[ -z "${unit}" ]] && continue
        systemctl stop    "${unit}" 2>/dev/null || true
        systemctl disable "${unit}" 2>/dev/null || true
        found=1
        log "INFO" "unit legacy detenida/deshabilitada: ${unit}"
    done < <(systemctl list-units --all --plain --no-legend 'wifi-setup@*' 2>/dev/null | awk '{print $1}')

    # Archivos de unit template legacy
    if compgen -G "/etc/systemd/system/wifi-setup@*.service" >/dev/null 2>&1; then
        rm -f /etc/systemd/system/wifi-setup@*.service
        found=1
        log "INFO" "archivos de unit legacy eliminados: wifi-setup@*.service"
    fi

    # Binarios sueltos de esquemas viejos
    local b
    for b in wifi-panic wfs wifi-status wifi-list wifi-passwd wifi-showpass; do
        [[ -e "/opt/wifi-setup/bin/${b}" ]] && { rm -f "/opt/wifi-setup/bin/${b}"; found=1; }
        if [[ -L "/usr/local/bin/${b}" || -f "/usr/local/bin/${b}" ]]; then
            rm -f "/usr/local/bin/${b}"; found=1
        fi
    done

    # Carpeta heredada services/
    if [[ -d /opt/wifi-setup/services ]]; then
        rm -rf /opt/wifi-setup/services
        found=1
        log "INFO" "carpeta legacy eliminada: /opt/wifi-setup/services"
    fi

    if [[ "${found}" -eq 1 ]]; then
        systemctl daemon-reload 2>/dev/null || true
        log "INFO" "barrido de instalador legacy completado"
    fi
}

# ---------------------------------------------------------------------------
# Trap limpieza de temporales
# ---------------------------------------------------------------------------
trap 'rm -f /tmp/wifisetup.* 2>/dev/null || true' EXIT INT TERM
