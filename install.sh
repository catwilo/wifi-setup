#!/usr/bin/env bash
# install.sh -- instalador wifi-setup (NetworkManager backbone).
#
# MODELO DE PRIVILEGIOS:
#   El script corre como usuario normal. Solo la fase que muta el sistema
#   (apt, systemctl, nmcli con add, /etc/, /usr/local/bin) se eleva con
#   sudo, una sola vez, con: exec sudo bash $0 --root-phase ...
#   Los nombres de ifaces viajan por argv; la PSK se pide DENTRO del sudo
#   (asi el password de sudo y la PSK nunca comparten linea de comando).
#
# FLUJO:
#   Fase usuario:
#     1. guarda Debian
#     2. si sudo + sin tmux -> bajar a SUDO_USER (relaunch en SU tmux)
#     3. relaunch en tmux (crea ventana o sesion, attach)
#     4. deteccion HW (antenas, ssh iface)
#     5. exec sudo bash $0 --root-phase <ifaces>
#   Fase root (dentro de sudo, mismo TTY, misma ventana tmux):
#     6. install_deps (apt)
#     7. prompt SSID/PSK, crear perfiles NM en cada antena
#     8. migrar stack: parar iwd/dhcpcd, arrancar NM
#     9. SSH hardening
#    10. tailscale install (sin conectar)
#    11. symlink /usr/local/bin/wifi
#    12. state + verificacion
#
# Requiere: Debian, TTY, conexion a internet.
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# ---------------------------------------------------------------------------
# --help
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    cat <<'HELP'
uso: sudo bash install.sh

Instala wifi-setup. Auto-detecta antenas (nativa + USB), pregunta SSID y
PSK solo si no existe config previa, y deja:
  - NetworkManager como gestor de red
  - iwd instalado y parado (fallback manual)
  - Las antenas con sus perfiles WiFi (PRIMARY=USB, SECONDARY=nativa)
  - Tailscale instalado y apagado
  - El cable LAN NO se configura: usa 'wifi lan setup' cuando lo necesites

El script corre como usuario y eleva con sudo solo la fase que muta el
sistema. El output completo queda en
~/.local/state/wifi-setup/install-<timestamp>.log

Requisitos: Debian 13+, TTY, conexion a internet, al menos una antena WiFi.
HELP
    exit 0
fi


# ---------------------------------------------------------------------------
# _root_phase <primary> <secondary> <ssh_iface>
# Corre como root (dentro de sudo). Instala, crea perfiles, migra el
# stack, hardening SSH, tailscale, symlink, state.
# ---------------------------------------------------------------------------
_root_phase() {
    [[ "${EUID}" -eq 0 ]] || die "_root_phase invocado sin root"

    local WIFI_PRIMARY="${1:-}"
    local WIFI_SECONDARY="${2:-}"
    local SSH_IFACE="${3:-}"
    [[ -n "${WIFI_PRIMARY}" ]] || die "root-phase sin iface primaria"

    source "${SCRIPT_DIR}/lib/deps.sh"
    source "${SCRIPT_DIR}/lib/nm.sh"
    source "${SCRIPT_DIR}/lib/radio.sh"
    source "${SCRIPT_DIR}/lib/vpn.sh"
    source "${SCRIPT_DIR}/lib/ssh.sh"
    source "${SCRIPT_DIR}/lib/fallback.sh"

    # ---------------------------------------------------------------------
    # BASE_DIR: crear YA con dueno del usuario real. Si el script falla
    # despues (timeout de IP, error de apt, etc.), el directorio queda
    # escribible por el usuario -- un fallo no debe dejar permisos rotos.
    # ---------------------------------------------------------------------
    _base_owner="${SUDO_USER:-root}"
    mkdir -p "${BASE_DIR}" "${STATE_DIR}" "${LOG_DIR}" "${CONFIG_DIR}"
    chown -R "${_base_owner}:${_base_owner}" "${BASE_DIR}"
    chmod 700 "${BASE_DIR}" "${STATE_DIR}" "${LOG_DIR}" "${CONFIG_DIR}"
    unset _base_owner

    local INSTALL_MODE="server"
    local BIN_DIR="/usr/local/bin"
    local WIFI_BIN="${BIN_DIR}/wifi"
    local WIFI_REPO_BIN="${SCRIPT_DIR}/bin/wifi"

    # LOG_FILE viene de la fase usuario por WIFI_SETUP_LOG (pasado a sudo
    # por linea de comando). Fallback por si se invoca --root-phase a mano.
    LOG_FILE="${WIFI_SETUP_LOG:-/var/log/wifi-setup-install-$(date +%Y%m%d-%H%M%S).log}"

    # ---------------------------------------------------------------------
    # Pre-check de idempotencia: si TODO esta ya aplicado, no re-ejecutar.
    # ---------------------------------------------------------------------
    local _idem_nm="" _idem_iwd="" _idem_dhcpcd="" _idem_symlink="" _idem_state="" _idem_boot=""
    local _idem_ok=1

    if systemctl is-active NetworkManager >/dev/null 2>&1; then
        _idem_nm="activo"
    else
        _idem_nm="inactivo"
        _idem_ok=0
    fi
    if [[ "$(systemctl is-enabled iwd 2>/dev/null || true)" == "disabled" ]]; then
        _idem_iwd="disabled"
    else
        _idem_iwd="no disabled"
        _idem_ok=0
    fi
    if [[ "$(systemctl is-enabled dhcpcd 2>/dev/null || true)" == "disabled" ]]; then
        _idem_dhcpcd="disabled"
    else
        _idem_dhcpcd="no disabled"
        _idem_ok=0
    fi
    if [[ -L "${WIFI_BIN}" ]] && [[ "$(readlink -f "${WIFI_BIN}")" == "${WIFI_REPO_BIN}" ]]; then
        _idem_symlink="OK"
    else
        _idem_symlink="pendiente"
        _idem_ok=0
    fi
    if [[ -f "${STATE_DIR}/install.state" ]]; then
        _idem_state="existe"
    else
        _idem_state="falta"
        _idem_ok=0
    fi

    local _idem_resolved=""
    if [[ "$(systemctl is-enabled systemd-resolved 2>/dev/null || true)" == "enabled" ]]; then
        _idem_resolved="enabled"
    else
        _idem_resolved="no enabled"
        _idem_ok=0
    fi

    # Unit de boot-select: si no existe o no declara wait-online, el
    # install no es idempotente -- se regenera al reejecutar.
    local _boot_unit="/etc/systemd/system/wifi-setup-radio-boot.service"
    if [[ -f "${_boot_unit}" ]] \
       && grep -q 'NetworkManager-wait-online.service' "${_boot_unit}"; then
        _idem_boot="OK"
    else
        _idem_boot="pendiente"
        _idem_ok=0
    fi

    if [[ "${_idem_ok}" -eq 1 ]]; then
        ok "wifi-setup ya instalado -- nada que hacer"
        info "  NetworkManager: ${_idem_nm}"
        info "  iwd:            ${_idem_iwd} (fallback manual)"
        info "  dhcpcd:         ${_idem_dhcpcd}"
        info "  symlink:        ${_idem_symlink}"
        info "  install.state:  ${_idem_state}"
        info "  systemd-resolved: ${_idem_resolved}"
        info "  boot-select:    ${_idem_boot}"
        info ""
        info "para forzar reinstalacion completa: borra ${STATE_DIR}/install.state y vuelve a correr"
        return 0
    fi



    # ---------------------------------------------------------------------
    # Limpieza previa (idempotente)
    # ---------------------------------------------------------------------
    if [[ -f "${STATE_DIR}/install.state" || -L "${WIFI_BIN}" ]]; then
        info "instalacion previa detectada -- limpiando..."
        sweep_legacy_install

        for svc in wifi-setup-forward wifi-setup-client wifi-setup-lan wifi-setup-radio-boot; do
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

    # ---------------------------------------------------------------------
    # 1. Dependencias (apt)
    # ---------------------------------------------------------------------
    echo ""
    section "Dependencias"
    install_deps

    # ---------------------------------------------------------------------
    # 2. Perfiles WiFi ANTES de tocar el stack.
    #    Con los perfiles creados, cuando migrate pare iwd, NM ya sabe con
    #    que reconectar. Sin esta inversion, NM arranca sin red conocida y
    #    el equipo queda sin WiFi hasta el siguiente boot.
    # ---------------------------------------------------------------------
    echo ""
    section "Configuracion WiFi (perfiles)"

    nm_require

    local existing
    existing="$(nmcli -t -f NAME,TYPE con show 2>/dev/null \
        | awk -F: '$2=="802-11-wireless"{print $1}')"
    if [[ -n "${existing}" ]]; then
        info "perfiles WiFi existentes -- se conservan:"
        while IFS= read -r p; do
            [[ -n "${p}" ]] && info "  · ${p}"
        done <<< "${existing}"
    else
        # Detectar SSID activo via iwd (que aun esta conectado).
        local current_ssid=""
        if command -v iwctl >/dev/null 2>&1; then
            current_ssid="$(iwctl station "${WIFI_PRIMARY}" show 2>/dev/null \
                | awk -F': ' '/Connected network/ {print $2}' | tr -d '[:space:]' || true)"
        fi

        local wifi_ssid="" wifi_psk=""
        if [[ -n "${current_ssid}" ]]; then
            info "SSID detectado desde iwd: ${current_ssid}"
            read -r -p "SSID [${current_ssid}]: " wifi_ssid
            wifi_ssid="${wifi_ssid:-${current_ssid}}"
        else
            read -r -p "SSID de la red WiFi: " wifi_ssid
            [[ -n "${wifi_ssid}" ]] || die "SSID vacio"
        fi

        read -r -s -p "PSK (min 8): " wifi_psk; echo
        [[ "${#wifi_psk}" -ge 8 ]] || die "PSK minimo 8 caracteres"

        local ifc profile
        for ifc in "${WIFI_PRIMARY}" ${WIFI_SECONDARY}; do
            [[ -n "${ifc}" ]] || continue
            profile="wifi-${ifc}-${wifi_ssid}"
            nm_wifi_create "${profile}" "${ifc}" "${wifi_ssid}" "${wifi_psk}"
            nm_con_set_autoconnect "${profile}" on
        done
        unset wifi_psk
    fi

    RADIO_PRIMARY="${WIFI_PRIMARY}"
    RADIO_SECONDARY="${WIFI_SECONDARY}"
    _radio_save_state
    radio_sync_priorities

    ok "perfiles WiFi listos -- NM tiene con que reconectar"

    # ---------------------------------------------------------------------
    # 3. Migracion al stack NM
    # ---------------------------------------------------------------------
    echo ""
    section "Migrando stack de red"

    info "parando iwd (queda instalado, disabled, fallback manual)..."
    systemctl stop    iwd 2>/dev/null || true
    systemctl disable iwd 2>/dev/null || true

    info "parando dhcpcd (NM trae su propio cliente)..."
    systemctl stop    dhcpcd 2>/dev/null || true
    systemctl disable dhcpcd 2>/dev/null || true

    info "parando systemd-networkd..."
    systemctl stop    systemd-networkd 2>/dev/null || true
    systemctl disable systemd-networkd 2>/dev/null || true

    info "arrancando NetworkManager..."
    systemctl enable NetworkManager >/dev/null 2>&1 || true
    systemctl restart NetworkManager
    sleep 5
    systemctl is-active NetworkManager >/dev/null 2>&1 \
        || die "NetworkManager no arranco -- revisa: journalctl -u NetworkManager -n 40"

    local ifc
    for ifc in "${WIFI_PRIMARY}" ${WIFI_SECONDARY}; do
        [[ -n "${ifc}" ]] || continue
        nmcli dev set "${ifc}" managed yes 2>/dev/null || true
    done

    info "esperando IP en ${WIFI_PRIMARY} (max 45s, progreso cada 3s)..."
    local waited=0 ip="" ifc_all
    local -a _ifaces=("${WIFI_PRIMARY}")
    [[ -n "${WIFI_SECONDARY}" ]] && _ifaces+=("${WIFI_SECONDARY}")

    while [[ "${waited}" -lt 45 ]]; do
        # Reportar cada iface configurada
        printf '  [%2ds] ' "${waited}" >&2
        for ifc_all in "${_ifaces[@]}"; do
            local _state _ipx
            _state="$(nmcli -t -f DEVICE,STATE dev status 2>/dev/null \
                | awk -F: -v i="${ifc_all}" '$1==i {print $2}' | head -1)"
            _ipx="$(ip -4 -o addr show "${ifc_all}" 2>/dev/null \
                | awk '{print $4}' | head -1)"
            printf '%s=%s%s ' "${ifc_all}" "${_state:-?}" "${_ipx:+(${_ipx})}" >&2
        done
        printf '\n' >&2

        ip="$(ip -4 -o addr show "${WIFI_PRIMARY}" 2>/dev/null \
            | awk '{print $4}' | head -1)"
        [[ -n "${ip}" ]] && break

        sleep 3
        waited=$((waited + 3))
    done
    [[ -n "${ip}" ]] \
        || die "la antena ${WIFI_PRIMARY} no obtuvo IP tras 45s -- revisa: nmcli dev status"

    ok "NetworkManager activo, ${WIFI_PRIMARY} con IP ${ip}"

    # ---------------------------------------------------------------------
    # 4. SSH hardening
    # ---------------------------------------------------------------------
    echo ""
    section "SSH"
    configure_ssh

    # ---------------------------------------------------------------------
    # 5. Tailscale (install + daemon, sin conectar)
    # ---------------------------------------------------------------------
    echo ""
    section "VPN (Tailscale)"
    vpn_install

    # ---------------------------------------------------------------------
    # 6. Symlink + state
    # ---------------------------------------------------------------------
    echo ""
    section "Instalando comando"
    chmod +x "${SCRIPT_DIR}/bin/wifi"
    mkdir -p "${BIN_DIR}"
    ln -sfn "${WIFI_REPO_BIN}" "${WIFI_BIN}"
    ok "symlink: ${WIFI_BIN} -> ${WIFI_REPO_BIN}"

    # Servicio oneshot: al boot, si PRIMARY no tiene IP tras
    # NetworkManager-wait-online (sin polling ni sleep), activa
    # SECONDARY. Una sola vez por arranque; no interfiere con runtime.
    cat > /etc/systemd/system/wifi-setup-radio-boot.service <<EOF_SVC
[Unit]
Description=wifi-setup boot-select (fallback de antena al arranque)
After=NetworkManager.service NetworkManager-wait-online.service
Wants=NetworkManager.service NetworkManager-wait-online.service
ConditionPathExists=${WIFI_BIN}

[Service]
Type=oneshot
ExecStart=${WIFI_BIN} radio boot
RemainAfterExit=no
# Sin polling ni sleep: systemd espera a NM via wait-online.
TimeoutStartSec=180

[Install]
WantedBy=multi-user.target
EOF_SVC
    chmod 644 /etc/systemd/system/wifi-setup-radio-boot.service
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable wifi-setup-radio-boot 2>/dev/null || true
    ok "servicio wifi-setup-radio-boot habilitado (fallback de arranque)"

    # ---------------------------------------------------------------------
    # USB WiFi naming: copiar config y aplicar .link por MAC.
    # El rename se aplica en el proximo boot (no toca el driver ahora).
    # ---------------------------------------------------------------------
    mkdir -p "${CONFIG_DIR}"
    if [[ -f "${SCRIPT_DIR}/config/usb-names.conf" ]]; then
        # Preservar ediciones locales: si ya existe uno en CONFIG_DIR y
        # difiere del repo, no lo pisamos -- avisamos.
        if [[ -f "${CONFIG_DIR}/usb-names.conf" ]] \
           && ! cmp -s "${SCRIPT_DIR}/config/usb-names.conf" "${CONFIG_DIR}/usb-names.conf"; then
            warn "usb-names.conf local difiere del repo -- se conserva (edita: wifi usb-names edit)"
        else
            cp -a "${SCRIPT_DIR}/config/usb-names.conf" "${CONFIG_DIR}/usb-names.conf"
            chmod 600 "${CONFIG_DIR}/usb-names.conf"
        fi
        if [[ -f "${CONFIG_DIR}/usb-names.conf" ]]; then
            nm_usb_names_apply "${CONFIG_DIR}/usb-names.conf"
        fi
    fi

    mkdir -p "${STATE_DIR}"
    cat > "${STATE_DIR}/install.state" <<EOF
INSTALL_MODE="${INSTALL_MODE}"
WIFI_PRIMARY="${WIFI_PRIMARY}"
WIFI_SECONDARY="${WIFI_SECONDARY}"
SSH_IFACE="${SSH_IFACE}"
EOF
    chmod 600 "${STATE_DIR}/install.state"


    # ---------------------------------------------------------------------
    # 7. Verificacion final explicita (PASS/FAIL por check)
    # ---------------------------------------------------------------------
    echo ""
    section "Verificacion final"

    local _chk_pass=0 _chk_fail=0
    _chk() {
        local label="$1" ok="$2"
        if [[ "${ok}" == "1" ]]; then
            printf '  %s[PASS]%s %s\n' "${C_GREEN}" "${C_RESET}" "${label}" >&2
            _chk_pass=$((_chk_pass + 1))
        else
            printf '  %s[FAIL]%s %s\n' "${C_RED}" "${C_RESET}" "${label}" >&2
            _chk_fail=$((_chk_fail + 1))
        fi
    }

    # NetworkManager activo
    if systemctl is-active NetworkManager >/dev/null 2>&1; then
        _chk "NetworkManager activo" 1
    else
        _chk "NetworkManager activo" 0
    fi

    # iwd disabled (fallback manual)
    if [[ "$(systemctl is-enabled iwd 2>/dev/null || true)" == "disabled" ]]; then
        _chk "iwd disabled (fallback)" 1
    else
        _chk "iwd disabled (fallback)" 0
    fi

    # dhcpcd disabled
    if [[ "$(systemctl is-enabled dhcpcd 2>/dev/null || true)" == "disabled" ]]; then
        _chk "dhcpcd disabled" 1
    else
        _chk "dhcpcd disabled" 0
    fi

    # Cada antena configurada con IP
    local _if _ip
    for _if in "${_ifaces[@]}"; do
        _ip="$(ip -4 -o addr show "${_if}" 2>/dev/null | awk '{print $4}' | head -1)"
        if [[ -n "${_ip}" ]]; then
            _chk "antena ${_if} con IP (${_ip})" 1
        else
            _chk "antena ${_if} con IP" 0
        fi
    done

    # Conectividad
    if ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; then
        _chk "conectividad a internet" 1
    else
        _chk "conectividad a internet" 0
    fi

    # Symlink
    if [[ -L "${WIFI_BIN}" ]] && [[ "$(readlink -f "${WIFI_BIN}")" == "${WIFI_REPO_BIN}" ]]; then
        _chk "symlink ${WIFI_BIN}" 1
    else
        _chk "symlink ${WIFI_BIN}" 0
    fi

    # install.state
    if [[ -f "${STATE_DIR}/install.state" ]]; then
        _chk "install.state" 1
    else
        _chk "install.state" 0
    fi

    # Tailscale
    if command -v tailscale >/dev/null 2>&1; then
        _chk "tailscale instalado" 1
    else
        _chk "tailscale instalado" 0
    fi

    # USB naming (si hay config)
    if [[ -f "${CONFIG_DIR}/usb-names.conf" ]]; then
        local _link_count
        _link_count="$(find "${NM_USB_LINK_DIR}" -maxdepth 1 -name "10-wifi-setup-*.link" 2>/dev/null | wc -l)"
        if [[ "${_link_count}" -gt 0 ]]; then
            _chk "usb-names: ${_link_count} link(s) escritos (proximo boot)" 1
        else
            _chk "usb-names: .link escritos" 0
        fi
    fi

    echo "" >&2
    if [[ "${_chk_fail}" -eq 0 ]]; then
        printf '  %s%s  OK: %d checks, todo en orden%s\n' \
            "${C_GREEN}" "${C_BOLD}" "${_chk_pass}" "${C_RESET}" >&2
    else
        printf '  %s%s  ATENCION: %d ok, %d fallo(s)%s\n' \
            "${C_RED}" "${C_BOLD}" "${_chk_pass}" "${_chk_fail}" "${C_RESET}" >&2
    fi

    echo "" >&2
    nm_dev_list

    echo "" >&2
    vpn_print_help

    echo "" >&2
    if [[ "${_chk_fail}" -eq 0 ]]; then
        echo -e "${C_GREEN}${C_BOLD}  Instalacion completa.${C_RESET}" >&2
    else
        echo -e "${C_RED}${C_BOLD}  Instalacion termino con ${_chk_fail} fallo(s).${C_RESET}" >&2
    fi
    echo -e "${C_GREEN}  Log    : ${LOG_FILE}${C_RESET}" >&2
    echo -e "${C_GREEN}  Comando: sudo wifi help${C_RESET}" >&2
    echo "" >&2

    [[ "${_chk_fail}" -eq 0 ]]
}

# ---------------------------------------------------------------------------
# Handler de la fase root: se dispara cuando el script se re-invoca con
# --root-phase via sudo. Carga los libs que necesitan root y corre las
# mutaciones del sistema. Los ifaces vienen por argv (no secretos).
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--root-phase" ]]; then
    shift
    _root_phase "$@"
    exit $?
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
#    original ANTES del relaunch. El server tmux es por usuario; como root
#    no vemos la sesion del usuario.
# ---------------------------------------------------------------------------
if [[ "${EUID}" -eq 0 && -n "${SUDO_USER:-}" && -z "${TMUX:-}" ]]; then
    _real_user="${SUDO_USER}"
    _real_home="$(getent passwd "${_real_user}" | cut -d: -f6)"
    [[ -n "${_real_home}" && -d "${_real_home}" ]] \
        || die "no pude resolver el home de ${_real_user}"
    info "sudo: bajando a ${_real_user} para relaunch en SU tmux..."
    exec sudo -u "${_real_user}" HOME="${_real_home}" bash "$0" "$@"
fi

# ---------------------------------------------------------------------------
# 3. Preparar el directorio de logs en el HOME del usuario.
#    Si existe con dueno root (instalacion previa que corrio todo como
#    root), borrarlo con sudo una vez. sudo cachea el timestamp 15 min;
#    el resto del script no vuelve a pedir password hasta --root-phase.
# ---------------------------------------------------------------------------
if [[ "${EUID}" -eq 0 ]]; then
    die "install.sh debe correr como usuario, no como root -- usa: bash install.sh"
fi

LOG_DIR_USER="${HOME}/.local/state/wifi-setup"
if [[ -e "${LOG_DIR_USER}" && ! -w "${LOG_DIR_USER}" ]]; then
    warn "${LOG_DIR_USER} no es escribible (instalacion previa como root) -- limpiando con sudo..."
    sudo rm -rf "${LOG_DIR_USER}" \
        || die "no pude limpiar ${LOG_DIR_USER} -- borra a mano: sudo rm -rf ${LOG_DIR_USER}"
fi
mkdir -p "${LOG_DIR_USER}"

# ---------------------------------------------------------------------------
# 4. Relaunch en tmux.
#
# Flags:
#   WIFI_SETUP_INWIN=1  ya estamos dentro de la ventana del relaunch.
#                       La ventana es el unico lugar donde el script corre.
#
# Comportamiento:
#   - dentro de la ventana del relaunch -> seguir (no relanzar)
#   - dentro de tmux (otra ventana)     -> crear ventana en la sesion actual
#   - hay sesiones tmux abiertas        -> crear ventana en la primera
#   - sin tmux                          -> crear sesion (attacha si TTY)
#   - sin tmux y sin TTY                -> abortar con mensaje claro
#
# La ventana corre "bash $0 2>&1 | tee -a $log" y sale al terminar, lo
# que la cierra. El output completo queda en el log.
# ---------------------------------------------------------------------------
_relaunch_in_tmux() {
    # Ya estamos dentro de la ventana: seguir.
    [[ "${WIFI_SETUP_INWIN:-}" == "1" ]] && return 0

    command -v tmux >/dev/null 2>&1 || {
        warn "tmux no instalado -- corriendo sin ventana (output solo en TTY)"
        return 0
    }

    local ts; ts="$(date +%Y%m%d-%H%M%S)"
    local log="${LOG_DIR_USER}/install-${ts}.log"

    local inner
    inner="WIFI_SETUP_INWIN=1 WIFI_SETUP_LOG=$(printf '%q' "${log}") bash $(printf '%q' "$0")"
    local a; for a in "$@"; do inner+=" $(printf '%q' "${a}")"; done
    # Cola: pausar para que el usuario lea el resultado del install.
    # El install ya imprime su propio resumen final (verificacion con
    # PASS/FAIL + "Instalacion completa/termino con N fallo(s)" + Log).
    # Aqui solo esperamos ENTER, para que la ventana no se cierre sola.
    local trailer
    trailer="; echo; echo 'ENTER para cerrar esta ventana...'; read -r _wifi_setup_wait"
    inner+=" 2>&1 | tee -a $(printf '%q' "${log}")${trailer}"

    # Sesion destino:
    #   dentro de tmux  -> la sesion actual
    #   fuera de tmux   -> la primera sesion abierta
    local target_session=""
    if [[ -n "${TMUX:-}" ]]; then
        target_session="$(tmux display-message -p '#S' 2>/dev/null || true)"
    fi
    if [[ -z "${target_session}" ]]; then
        target_session="$(tmux ls 2>/dev/null | sed -n '1s/:.*//p')"
    fi

    if [[ -n "${target_session}" ]]; then
        # Crear la ventana en la sesion existente.
        tmux new-window -t "${target_session}:" -n wifi-install "${inner}"
        tmux select-window -t "${target_session}:wifi-install"

        if [[ -n "${TMUX:-}" ]]; then
            # Ya estamos dentro de tmux (cliente local): la ventana
            # queda visible y salimos -- el usuario sigue en su tmux.
            exit 0
        fi

        # Fuera de tmux (tipicamente via nssh -t): attachar a la
        # sesion para mantener viva la conexion SSH y ver el install.
        # NO usamos -d: si hay otro cliente attachado a esa sesion,
        # tmux aborta con "sessions should be nested"; en ese caso
        # avisamos y salimos sin romper nada.
        info "attachando a sesion tmux \"${target_session}\"..."
        if ! tmux attach -t "${target_session}"; then
            warn "no se pudo attachar (probable: otra sesion activa en \"${target_session}\")"
            warn "la ventana \"wifi-install\" ya fue creada -- attachate a mano:"
            warn "  tmux attach -t ${target_session}"
            exit 0
        fi
    fi

    # Sin sesiones tmux. Si no hay TTY no podemos attachar.
    if [[ ! -t 0 && ! -t 1 ]]; then
        die "no hay sesion tmux y no hay TTY -- conectate con: nssh -t <alias>
y vuelve a correr: bash install.sh"
    fi

    exec tmux new-session -s wifi-setup -n install "${inner}"
}

_relaunch_in_tmux "$@"



















LOG_FILE="${WIFI_SETUP_LOG:-${LOG_DIR_USER}/install-$(date +%Y%m%d-%H%M%S).log}"

# ---------------------------------------------------------------------------
# Deteccion HW (usuario, sin root).
# ---------------------------------------------------------------------------
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
info "log: ${LOG_FILE}"

# ---------------------------------------------------------------------------
# Elevar SOLO la fase que muta. Los ifaces viajan por argv (no son secretos).
# La PSK se pide dentro de sudo, no aqui.
# ---------------------------------------------------------------------------
info "elevando a root para la fase de instalacion..."
exec sudo WIFI_SETUP_LOG="${LOG_FILE}" \
     bash "$0" --root-phase \
     "${WIFI_PRIMARY}" "${WIFI_SECONDARY}" "${SSH_IFACE:-}"
