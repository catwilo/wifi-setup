#!/usr/bin/env bash
# lib/doctor.sh -- diagnostico + auto-fix del estado wifi-setup.
#
# RESPONSABILIDAD UNICA: verificar que el stack este consistente y, con
# --fix, corregir los problemas conocidos de forma segura (nunca destructivo).
#
# Uso:
#   wifi doctor           reporte read-only (no toca nada)
#   sudo wifi doctor --fix aplicar fixes seguros
#
# El reporte sigue un formato uniforme: cada linea tiene
#   [OK]/[WARN]/[FAIL]/[FIX]/[SKIP]  etiqueta  detalle
# y al final cuenta OK/WARN/FAIL.
#
# Requiere: common.sh + nm.sh + radio.sh sourceados antes.

DOCTOR_OK=0
DOCTOR_WARN=0
DOCTOR_FAIL=0
DOCTOR_FIX=0
DOCTOR_FIX_MODE=0

# ---------------------------------------------------------------------------
# Helpers de reporte
# ---------------------------------------------------------------------------
doctor_reset() {
    DOCTOR_OK=0
    DOCTOR_WARN=0
    DOCTOR_FAIL=0
    DOCTOR_FIX=0
}

_doctor_ok()   { printf '  %s[OK]%s   %s\n'   "${C_GREEN}"  "${C_RESET}" "$*" >&2; DOCTOR_OK=$((DOCTOR_OK+1)); }
_doctor_warn() { printf '  %s[WARN]%s %s\n'   "${C_YELLOW}" "${C_RESET}" "$*" >&2; DOCTOR_WARN=$((DOCTOR_WARN+1)); }
_doctor_fail() { printf '  %s[FAIL]%s %s\n'   "${C_RED}"    "${C_RESET}" "$*" >&2; DOCTOR_FAIL=$((DOCTOR_FAIL+1)); }
_doctor_fix()  { printf '  %s[FIX]%s  %s\n'   "${C_CYAN}"   "${C_RESET}" "$*" >&2; DOCTOR_FIX=$((DOCTOR_FIX+1)); }
_doctor_skip() { printf '  [SKIP] %s\n' "$*" >&2; }

_doctor_section() {
    printf '\n%s%s▸ %s%s\n' "${C_BOLD}" "${C_CYAN}" "$*" "${C_RESET}" >&2
}

# ---------------------------------------------------------------------------
# Chequeo 1: servicios del stack de red.
# ---------------------------------------------------------------------------
_doctor_check_services() {
    _doctor_section "Servicios"

    local svc want_active want_enabled state_active state_enabled line

    while IFS=: read -r svc want_active want_enabled; do
        state_active="$(systemctl is-active  "${svc}" 2>/dev/null || true)"
        state_enabled="$(systemctl is-enabled "${svc}" 2>/dev/null || true)"
        line="${svc} -- active=${state_active:-?} enabled=${state_enabled:-?}"

        if [[ "${state_active}" == "${want_active}" && "${state_enabled}" == "${want_enabled}" ]]; then
            _doctor_ok "${line}"
            continue
        fi

        if [[ "${DOCTOR_FIX_MODE}" -eq 1 ]]; then
            case "${want_active}:${want_enabled}" in
                active:enabled)
                    systemctl enable --now "${svc}" >/dev/null 2>&1 || true
                    ;;
                inactive:disabled)
                    systemctl disable --now "${svc}" >/dev/null 2>&1 || true
                    ;;
            esac
            _doctor_fix "${line} -> active=${want_active} enabled=${want_enabled}"
        else
            _doctor_warn "${line} (esperado: active=${want_active} enabled=${want_enabled})"
        fi
    done <<'SERVICES'
NetworkManager:active:enabled
iwd:inactive:disabled
dhcpcd:inactive:disabled
systemd-networkd:inactive:disabled
SERVICES
}


# ---------------------------------------------------------------------------
# Helpers de deteccion por iface.
# ---------------------------------------------------------------------------

# _doctor_driver_of <iface> -- imprime el driver de red de la iface.
# USB WiFi expone varias interfaces; la de red es la que tiene
# .../net/<iface> hija. Fallback: driver del device (PCI o simple).
_doctor_driver_of() {
    local iface="$1"
    local ifdir="/sys/class/net/${iface}/device"
    local sub driver

    if [[ -d "${ifdir}" ]]; then
        for sub in "${ifdir}"/*/driver; do
            [[ -L "${sub}" ]] || continue
            driver="$(basename "$(readlink -f "${sub}" 2>/dev/null)" 2>/dev/null)"
            case "${driver}" in
                usb|hub|btusb|"") continue ;;
            esac
            if [[ -d "${sub%/driver}/net/${iface}" ]]; then
                echo "${driver}"
                return 0
            fi
        done
    fi

    driver="$(basename "$(readlink -f "${ifdir}/driver" 2>/dev/null)" 2>/dev/null)"
    echo "${driver:-?}"
}

# _doctor_permanent_mac_of <iface> -- MAC de fabrica (permaddr) o la actual.
_doctor_permanent_mac_of() {
    local iface="$1"
    local perm
    perm="$(ip link show "${iface}" 2>/dev/null \
        | grep -oE 'permaddr [0-9a-f:]+' | awk '{print $2}' | head -1)"
    if [[ -z "${perm}" ]]; then
        perm="$(cat "/sys/class/net/${iface}/address" 2>/dev/null || echo "?")"
    fi
    echo "${perm}"
}

# ---------------------------------------------------------------------------
# Chequeo 2: antenas fisicas (kernel + NM).
# ---------------------------------------------------------------------------
_doctor_check_radios() {
    _doctor_section "Antenas"

    local iface path bus driver state conn mac

    if ! command -v nmcli >/dev/null 2>&1; then
        _doctor_fail "nmcli no disponible -- NetworkManager no instalado"
        return 0
    fi

    local ifaces
    ifaces="$(nmcli -t -f DEVICE,TYPE dev status 2>/dev/null | awk -F: '$2=="wifi"{print $1}')"

    if [[ -z "${ifaces}" ]]; then
        _doctor_fail "ninguna antena WiFi visible para NM"
        return 0
    fi

    while IFS= read -r iface; do
        [[ -n "${iface}" ]] || continue
        path="$(readlink -f "/sys/class/net/${iface}" 2>/dev/null || true)"
        if [[ "${path}" == *"/usb"* ]]; then
            bus="USB"
        elif [[ "${path}" == *"/pci"* ]]; then
            bus="PCI"
        else
            bus="?"
        fi

        driver="$(_doctor_driver_of "${iface}")"
        mac="$(_doctor_permanent_mac_of "${iface}")"

        state="$(nmcli -t -f DEVICE,STATE,CONNECTION dev status 2>/dev/null \
            | awk -F: -v i="${iface}" '$1==i {print $2"|"$3}')"
        state="${state%%|*}"
        conn="${state##*|}"
        [[ -z "${conn}" ]] && conn="--"

        if [[ "${state}" == "connected" ]]; then
            _doctor_ok "${iface} (${bus}, ${driver}) conectada -> ${conn}"
        elif [[ "${state}" == "disconnected" ]]; then
            _doctor_warn "${iface} (${bus}, ${driver}) desconectada (MAC ${mac})"
        else
            _doctor_warn "${iface} (${bus}, ${driver}) estado: ${state}"
        fi
    done <<< "${ifaces}"
}

# ---------------------------------------------------------------------------
# Chequeo 3: perfiles NM -- huerfanos y prioridades.
# ---------------------------------------------------------------------------
_doctor_check_profiles() {
    _doctor_section "Perfiles NM"

    local name iface type exists
    local orphans=0
    local total=0

    while IFS=: read -r name _uuid type iface; do
        [[ "${type}" == "802-11-wireless" ]] || continue
        total=$((total+1))
        if [[ -z "${iface}" ]]; then
            # Sin iface asignada; comprobar si el nombre del perfil apunta
            # a una iface que ya no existe (ej. wifi-wlxOLD-ssid).
            local profile_iface
            profile_iface="$(nmcli -t -g connection.interface-name con show "${name}" 2>/dev/null || true)"
            if [[ -n "${profile_iface}" ]] && ! ip link show "${profile_iface}" >/dev/null 2>&1; then
                _doctor_warn "${name}: interface-name '${profile_iface}' no existe"
                orphans=$((orphans+1))
                _doctor_try_fix_orphan "${name}" "${profile_iface}"
            else
                _doctor_skip "${name}: sin dispositivo activo (perfil valido)"
            fi
            continue
        fi
        _doctor_ok "${name} -> ${iface}"
    done < <(nmcli -t -f NAME,UUID,TYPE,DEVICE con show 2>/dev/null)

    if [[ "${total}" -eq 0 ]]; then
        _doctor_warn "sin perfiles WiFi configurados"
    fi
}

# _doctor_try_fix_orphan <profile> <missing_iface>
# Intenta mapear la iface missing a una existente por MAC, y renombra
# el perfil. Requiere que exista un .link con PermanentMACAddress.
_doctor_try_fix_orphan() {
    local profile="$1" missing_iface="$2"

    if [[ "${DOCTOR_FIX_MODE}" -ne 1 ]]; then
        return 0
    fi

    # Buscar el nombre nuevo que reemplazo a missing_iface. Fuentes:
    #   1. config/usb-names.conf (mapeo MAC -> name)
    #   2. .link en /etc/systemd/network/
    # Como missing_iface ya no existe, no podemos sacar su MAC directo.
    # Buscamos entre los .link un mapping donde el viejo no este, o
    # simplemente probamos wlx1 si el config lo declara.

    local cfg="${CONFIG_DIR}/usb-names.conf"
    [[ -f "${cfg}" ]] || return 0

    local line mac name
    while IFS= read -r line; do
        line="${line%%#*}"
        line="$(printf '%s' "${line}" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')"
        [[ -n "${line}" ]] || continue
        local _rest
        IFS=' ' read -r mac name _rest <<< "${line}"
        [[ -n "${mac}" && -n "${name}" && -z "${_rest}" ]] || continue
        # ¿La nueva iface existe?
        if ip link show "${name}" >/dev/null 2>&1; then
            # Verificar si el perfil apunta a una iface que ya no existe
            # y la MAC del .link coincide. Reescritura segura.
            local new_profile="${profile/${missing_iface}/${name}}"
            if [[ "${new_profile}" != "${profile}" ]]; then
                nmcli con mod "${profile}" connection.id            "${new_profile}"          >/dev/null 2>&1 || true
                nmcli con mod "${new_profile}" connection.interface-name "${name}"          >/dev/null 2>&1 || true
                _doctor_fix "${profile} -> ${new_profile} (interface-name=${name})"
            else
                nmcli con mod "${profile}" connection.interface-name "${name}"              >/dev/null 2>&1 || true
                _doctor_fix "${profile}: interface-name=${name}"
            fi
            return 0
        fi
    done < "${cfg}"
}

# ---------------------------------------------------------------------------
# Chequeo 4: .link de renombrado USB.
# ---------------------------------------------------------------------------
_doctor_check_usb_links() {
    _doctor_section "Renombrado USB"

    local cfg="${CONFIG_DIR}/usb-names.conf"
    [[ -f "${cfg}" ]] || cfg="${LIB_DIR}/../config/usb-names.conf"

    if [[ ! -f "${cfg}" ]]; then
        _doctor_skip "sin config/usb-names.conf"
        return 0
    fi

    local line mac name link current
    local pending=0
    # Cargar el config a memoria: nm_usb_names_apply lee el mismo
    # archivo y ShellCheck avisa por posible doble uso (falso positivo,
    # pero evitamos el warning cargando antes).
    local -a _doctor_cfg_lines=()
    mapfile -t _doctor_cfg_lines < "${cfg}"
    for line in "${_doctor_cfg_lines[@]}"; do
        line="${line%%#*}"
        line="$(printf '%s' "${line}" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')"
        [[ -n "${line}" ]] || continue
        local _rest
        IFS=' ' read -r mac name _rest <<< "${line}"
        [[ -n "${mac}" && -n "${name}" && -z "${_rest}" ]] || continue

        link="/etc/systemd/network/10-wifi-setup-${name}.link"
        if [[ ! -f "${link}" ]]; then
            _doctor_warn "falta ${link}"
            pending=1
            if [[ "${DOCTOR_FIX_MODE}" -eq 1 ]]; then
                nm_usb_names_apply "${cfg}" >/dev/null 2>&1 || true
                if [[ -f "${link}" ]]; then
                    _doctor_fix "${link} creado (aplicara en proximo boot)"
                fi
            fi
            continue
        fi

        # ¿La iface ya tiene el nombre nuevo?
        if ip link show "${name}" >/dev/null 2>&1; then
            _doctor_ok "${mac} -> ${name} (aplicado)"
        else
            _doctor_warn "${mac} -> ${name} (pendiente: requiere reboot)"
        fi
    done

    if [[ "${pending}" -eq 0 ]]; then
        return 0
    fi
}

# ---------------------------------------------------------------------------
# Chequeo 5: symlink del comando.
# ---------------------------------------------------------------------------
_doctor_check_symlink() {
    _doctor_section "Comando"

    local target="${BIN_DIR:-/usr/local/bin}/wifi"
    # PROJECT_ROOT lo define bin/wifi (cd .. desde el binario). Si se
    # invoca de otra forma, caemos a SCRIPTS_DIR o al repo bajo home.
    local repo_bin="${PROJECT_ROOT:-${SCRIPTS_DIR:-${HOME}/unix-toolkit-tools/wifi-setup}}/bin/wifi"

    if [[ ! -L "${target}" ]]; then
        _doctor_warn "${target} no es un symlink"
        if [[ "${DOCTOR_FIX_MODE}" -eq 1 ]] && [[ -x "${repo_bin}" ]]; then
            ln -sfn "${repo_bin}" "${target}"
            _doctor_fix "${target} -> ${repo_bin}"
        fi
        return 0
    fi

    local resolved
    resolved="$(readlink -f "${target}" 2>/dev/null || true)"
    if [[ "${resolved}" == "${repo_bin}" ]]; then
        _doctor_ok "${target} -> ${resolved}"
    else
        _doctor_warn "${target} -> ${resolved} (esperado: ${repo_bin})"
        if [[ "${DOCTOR_FIX_MODE}" -eq 1 ]] && [[ -x "${repo_bin}" ]]; then
            ln -sfn "${repo_bin}" "${target}"
            _doctor_fix "${target} -> ${repo_bin}"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Chequeo 6: Tailscale.
# ---------------------------------------------------------------------------
_doctor_check_tailscale() {
    _doctor_section "Tailscale"

    if ! command -v tailscale >/dev/null 2>&1; then
        _doctor_warn "tailscale no instalado"
        return 0
    fi

    _doctor_ok "tailscale $(tailscale version 2>/dev/null | head -1)"

    local state
    state="$(systemctl is-active tailscaled 2>/dev/null || true)"
    if [[ "${state}" == "active" ]]; then
        _doctor_ok "tailscaled activo"
    else
        _doctor_warn "tailscaled ${state}"
        if [[ "${DOCTOR_FIX_MODE}" -eq 1 ]]; then
            systemctl enable --now tailscaled >/dev/null 2>&1 || true
            _doctor_fix "tailscaled activado"
        fi
    fi

    if tailscale status >/dev/null 2>&1; then
        _doctor_ok "tailscale conectado"
    else
        _doctor_skip "tailscale down (activa: wifi vpn up)"
    fi
}

# ---------------------------------------------------------------------------
# Resumen final + exit code.
# ---------------------------------------------------------------------------
_doctor_summary() {
    printf '\n%s%s  ───────────────────────────────────────────────%s\n' \
        "${C_BOLD}" "${C_DIM}" "${C_RESET}" >&2
    printf '  %s%d OK%s   %s%d WARN%s   %s%d FAIL%s' \
        "${C_GREEN}"  "${DOCTOR_OK}"   "${C_RESET}" \
        "${C_YELLOW}" "${DOCTOR_WARN}" "${C_RESET}" \
        "${C_RED}"    "${DOCTOR_FAIL}" "${C_RESET}" >&2
    if [[ "${DOCTOR_FIX}" -gt 0 ]]; then
        printf '   %s%d FIX%s' "${C_CYAN}" "${DOCTOR_FIX}" "${C_RESET}" >&2
    fi
    printf '\n%s%s  ───────────────────────────────────────────────%s\n' \
        "${C_BOLD}" "${C_DIM}" "${C_RESET}" >&2
    printf '\n' >&2

    if [[ "${DOCTOR_FAIL}" -gt 0 ]]; then
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# doctor_run [--fix]
# ---------------------------------------------------------------------------
doctor_run() {
    DOCTOR_FIX_MODE=0
    if [[ "${1:-}" == "--fix" ]]; then
        DOCTOR_FIX_MODE=1
    fi

    doctor_reset

    printf '\n%s%s  wifi-setup doctor%s' "${C_BOLD}" "${C_CYAN}" "${C_RESET}" >&2
    if [[ "${DOCTOR_FIX_MODE}" -eq 1 ]]; then
        printf '  %s(--fix)%s' "${C_YELLOW}" "${C_RESET}" >&2
    fi
    printf '\n' >&2

    _doctor_check_services
    _doctor_check_radios
    _doctor_check_profiles
    _doctor_check_usb_links
    _doctor_check_symlink
    _doctor_check_tailscale

    _doctor_summary
}
