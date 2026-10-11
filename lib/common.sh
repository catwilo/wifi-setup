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
# Colores ANSI como bytes reales (ANSI-C quoting) para que printf '%s'
# los emita sin necesidad de -e. Los modulos que usan echo -e siguen
# funcionando: el ESC embebido se imprime tal cual.
if [[ -t 1 ]]; then
    C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[1;33m'
    C_CYAN=$'\033[0;36m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
    C_DIM=$'\033[2m'
else
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''; C_BOLD=''; C_RESET=''
    C_DIM=''
fi

# ---------------------------------------------------------------------------
# Cargar modulos base
# ---------------------------------------------------------------------------
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/log.sh"

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
# sweep_legacy_install -- limpia restos de esquemas previos de wifi-setup.
# Idempotente. Cubre:
#   - units wifi-setup@*.service (template viejo)
#   - binarios sueltos en /usr/local/bin (wfs, wifi-panic, ...)
#   - /opt/wifi-setup (modelo copy, reemplazado por symlink)
#   - /etc/udev/rules.d/*-wlan*.network y *-wlan*.rules (renombrado obsoleto)
#   - /etc/wpa_supplicant/wpa_supplicant-<iface>.conf huerfanos (iface
#     que ya no existe; NM no los usa)
#   - /etc/dhcpcd.conf: bloque "interface wlan*" creado por versiones viejas
#     (dhcpcd ya no gestiona estas ifaces)
# ---------------------------------------------------------------------------
sweep_legacy_install() {
    local found=0
    local unit

    # 1. Units template viejas
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

    # 2. Binarios sueltos en /usr/local/bin
    local b
    for b in wifi-panic wfs wifi-status wifi-list wifi-passwd wifi-showpass; do
        if [[ -L "/usr/local/bin/${b}" || -f "/usr/local/bin/${b}" ]]; then
            rm -f "/usr/local/bin/${b}"
            found=1
        fi
    done

    # 3. /opt/wifi-setup (modelo copy viejo)
    if [[ -d /opt/wifi-setup ]]; then
        rm -rf /opt/wifi-setup
        found=1
        info "eliminado /opt/wifi-setup (esquema viejo)"
    fi

    # 4. Udev rules con nombre de iface obsoleto (wlan/wlan0/wlan1).
    #    Estas reglas venian de esquemas previos que renombraban MACs por
    #    iface. NM no las necesita: aplica cloned-mac-address desde el
    #    perfil. Renombrar por MAC/iface rompe si la MAC cambia.
    local udev_rule
    for udev_rule in /etc/udev/rules.d/*-wlan*.network /etc/udev/rules.d/*-wlan*.rules; do
        [[ -e "${udev_rule}" ]] || continue
        rm -f "${udev_rule}"
        found=1
        info "udev rule legacy eliminada: ${udev_rule}"
    done

    # 5. wpa_supplicant-<iface>.conf huerfanos (iface ya no existe).
    #    NM tiene sus propios .nmconnection; estos archivos no se usan.
    local wpa_conf wpa_iface
    for wpa_conf in /etc/wpa_supplicant/wpa_supplicant-*.conf; do
        [[ -e "${wpa_conf}" ]] || continue
        wpa_iface="$(basename "${wpa_conf}" .conf | sed 's/^wpa_supplicant-//')"
        if ! ip link show "${wpa_iface}" >/dev/null 2>&1; then
            rm -f "${wpa_conf}"
            found=1
            info "wpa_supplicant config huerfana eliminada: ${wpa_conf} (iface '${wpa_iface}' no existe)"
        fi
    done

    # 6. dhcpcd.conf: eliminar bloques "interface wlan*" del esquema viejo.
    #    dhcpcd ya no gestiona las WiFi (NM lo hace). Dejar el bloque
    #    generaba conflicto si dhcpcd se reactivaba por error.
    if [[ -f /etc/dhcpcd.conf ]] && grep -qE '^interface wlan' /etc/dhcpcd.conf 2>/dev/null; then
        local tmp
        tmp="$(mktemp /etc/dhcpcd.conf.wifisetup.XXXXXX)"
        awk '
            /^interface wlan/ { skip=1; next }
            skip && /^interface / { skip=0 }
            skip && /^[^[:space:]]/ { skip=0 }
            skip { next }
            { print }
        ' /etc/dhcpcd.conf > "${tmp}"
        cp -a /etc/dhcpcd.conf /etc/dhcpcd.conf.wifisetup.bak 2>/dev/null || true
        mv "${tmp}" /etc/dhcpcd.conf
        found=1
        info "bloques 'interface wlan*' eliminados de /etc/dhcpcd.conf"
    fi

    if [[ "${found}" -eq 1 ]]; then
        systemctl daemon-reload 2>/dev/null || true
        info "barrido legacy completado"
    fi
}
