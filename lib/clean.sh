#!/usr/bin/env bash
# lib/clean.sh -- limpia residuos del estado actual.
#
# Objetivo: borrar todo lo que dejaron instalaciones canceladas,
# migraciones a medias, y procesos huerfanos, SIN tocar la red activa
# ni los perfiles que el usuario usa.
#
# NO cambia el gestor activo (iwd vs NetworkManager). Para eso:
#   sudo wifi fallback off    (migrar a NM, con rollback)
#   sudo wifi fallback on     (migrar a iwd)
#
# NO borra perfiles NM activos. Solo los inactivos que no matchean
# ningun perfil listado por `nmcli con show --active`.
#
# NO toca /etc/network/interfaces salvo para quitar entradas de ifaces
# que ya no existen en el kernel. Eso es siempre seguro: un `iface X`
# donde X no existe hace fallar a ifupdown y el usuario nunca lo nota.
#
# Idempotente: se puede correr mil veces.
# Requiere root.

_clean_section() {
    printf '\n%s%s%s\n' "${C_BOLD:-}" "$*" "${C_RESET:-}" >&2
}

_clean_report() {
    printf '  %s\n' "$*" >&2
}

wifi_clean() {
    require_root

    local _removed=0 _skipped=0 _kept=0
    local _active_mgr="ninguno"

    if systemctl is-active NetworkManager >/dev/null 2>&1; then
        _active_mgr="NetworkManager"
    elif systemctl is-active iwd >/dev/null 2>&1; then
        _active_mgr="iwd"
    fi

    section "wifi clean (gestor activo: ${_active_mgr})"

    # ------------------------------------------------------------------
    # 1. Procesos huerfanos de supplicants y DHCP.
    #    wpa_supplicant global: si NM manda, no debe correr (NM spawnea
    #    su propio supplicant por D-Bus). Si iwd manda, tampoco. Solo
    #    debe correr si el usuario lo arranco manualmente (raro).
    #    En cualquier caso: matar y dejar que NM/iwd reaparezcan lo suyo.
    # ------------------------------------------------------------------
    _clean_section "1. Procesos huerfanos"

    local _wpa_pids _dpc_pids
    _wpa_pids="$(pgrep -x wpa_supplicant 2>/dev/null || true)"
    _dpc_pids="$(pgrep -x dhcpcd 2>/dev/null || true)"

    if [[ "${_active_mgr}" == "NetworkManager" ]]; then
        # NM spawnea su propio wpa_supplicant (hijo o via D-Bus). Matarlo
        # hace que NM lo respawnee y la conexion flapee 1-2s. No es
        # huerfano: es parte del stack de NM. No se toca.
        if [[ -n "${_wpa_pids}" ]]; then
            _clean_report "wpa_supplicant: corriendo bajo NM (no se toca, pids: $(echo ${_wpa_pids} | tr ' ' ','))"
        else
            _clean_report "wpa_supplicant: no corriendo"
        fi
        _kept=$((_kept + 1))
    else
        if [[ -n "${_wpa_pids}" ]]; then
            pkill -TERM -x wpa_supplicant 2>/dev/null || true
            sleep 1
            pkill -KILL -x wpa_supplicant 2>/dev/null || true
            _clean_report "wpa_supplicant: matado (pids: $(echo ${_wpa_pids} | tr ' ' ','))"
            _removed=$((_removed + 1))
        else
            _clean_report "wpa_supplicant: no corriendo"
            _kept=$((_kept + 1))
        fi
    fi

    if [[ -n "${_dpc_pids}" ]]; then
        pkill -TERM -x dhcpcd 2>/dev/null || true
        sleep 1
        pkill -KILL -x dhcpcd 2>/dev/null || true
        _clean_report "dhcpcd: matado (pids: $(echo ${_dpc_pids} | tr ' ' ','))"
        _removed=$((_removed + 1))
    else
        _clean_report "dhcpcd: no corriendo"
        _kept=$((_kept + 1))
    fi

    # ------------------------------------------------------------------
    # 2. Servicios systemd que no deben estar activos.
    #    - wpa_supplicant.service: solo si NM esta activo (NM spawnea
    #      el suyo). Si iwd esta activo, wpa_supplicant ni se usa.
    #    - wpa_supplicant@*.service: instancias per-iface que udev
    #      dispara. Nunca deben estar activas.
    # ------------------------------------------------------------------
    _clean_section "2. Servicios systemd"

    if [[ "${_active_mgr}" == "NetworkManager" ]]; then
        # NM puede usar el servicio systemd (en algunas configs de Debian)
        # o su propio supplicant por D-Bus. En ambos casos es de NM, no
        # huerfano. No se toca.
        _clean_report "wpa_supplicant.service: gestionado por NM (no se toca)"
        _kept=$((_kept + 1))
    else
        if systemctl is-enabled wpa_supplicant >/dev/null 2>&1; then
            systemctl disable wpa_supplicant 2>/dev/null || true
            _clean_report "wpa_supplicant.service: disable"
            _removed=$((_removed + 1))
        else
            _clean_report "wpa_supplicant.service: ya disabled"
            _kept=$((_kept + 1))
        fi
        if systemctl is-active wpa_supplicant >/dev/null 2>&1; then
            systemctl stop wpa_supplicant 2>/dev/null || true
            _clean_report "wpa_supplicant.service: stop"
        fi
    fi

    local _wpa_inst
    while IFS= read -r _wpa_inst; do
        [[ -n "${_wpa_inst}" ]] || continue
        if [[ "${_active_mgr}" == "NetworkManager" ]]; then
            _clean_report "${_wpa_inst}: corriendo bajo NM (no se toca)"
            _kept=$((_kept + 1))
            continue
        fi
        systemctl stop "${_wpa_inst}" 2>/dev/null || true
        systemctl disable "${_wpa_inst}" 2>/dev/null || true
        systemctl reset-failed "${_wpa_inst}" 2>/dev/null || true
        _clean_report "${_wpa_inst}: stop + disable"
        _removed=$((_removed + 1))
    done < <(systemctl list-units --all --plain --no-legend 'wpa_supplicant@*' 2>/dev/null | awk '{print $1}')

    # ------------------------------------------------------------------
    # 3. Leases DHCP huerfanos (dhcpcd no gestiona nada tras la limpieza).
    # ------------------------------------------------------------------
    _clean_section "3. Leases DHCP huerfanos"

    local _lease
    for _lease in /var/lib/dhcpcd/wlan*.lease /var/lib/dhcpcd/wlx*.lease; do
        [[ -e "${_lease}" ]] || continue
        rm -f "${_lease}"
        _clean_report "borrado: ${_lease}"
        _removed=$((_removed + 1))
    done

    # ------------------------------------------------------------------
    # 4. Perfiles NM huerfanos.
    #    Un perfil es huerfano si:
    #    - es WiFi
    #    - NO esta en `nmcli con show --active`
    #    - la iface a la que apunta ya no existe en /sys/class/net
    #    Los perfiles activos se respetan SIEMPRE.
    #    Los perfiles de ifaces vivas se respetan (pueden ser del usuario).
    # ------------------------------------------------------------------
    _clean_section "4. Perfiles NetworkManager"

    if command -v nmcli >/dev/null 2>&1 && [[ "${_active_mgr}" == "NetworkManager" ]]; then
        local _active_profiles _orphans=()
        _active_profiles="$(nmcli -t -f NAME con show --active 2>/dev/null || true)"

        local _prof _iface _type
        while IFS=: read -r _prof _type _iface; do
            [[ -n "${_prof}" ]] || continue
            [[ "${_type}" == "802-11-wireless" ]] || continue
            grep -qFx "${_prof}" <<< "${_active_profiles}" && continue
            if [[ -n "${_iface}" ]] && [[ ! -e "/sys/class/net/${_iface}" ]]; then
                _orphans+=("${_prof}|${_iface}")
            fi
        done < <(nmcli -t -f NAME,TYPE,DEVICE con show 2>/dev/null || true)

        if [[ "${#_orphans[@]}" -eq 0 ]]; then
            _clean_report "sin perfiles huerfanos"
            _kept=$((_kept + 1))
        else
            local _o
            for _o in "${_orphans[@]}"; do
                _prof="${_o%%|*}"
                _iface="${_o##*|}"
                nmcli con delete "${_prof}" >/dev/null 2>&1 || true
                _clean_report "borrado perfil huerfano: ${_prof} (iface inexistente: ${_iface})"
                _removed=$((_removed + 1))
            done
        fi
    else
        _clean_report "NM no activo -- perfiles no revisados (corre tras wifi fallback off)"
        _skipped=$((_skipped + 1))
    fi

    # ------------------------------------------------------------------
    # 5. /etc/network/interfaces: quitar entradas de ifaces inexistentes.
    #    Seguro siempre: ifupdown falla al intentar levantar una iface
    #    que no existe, pero el error no es visible y ensucia el boot.
    #    Hacer backup antes de tocar.
    # ------------------------------------------------------------------
    _clean_section "5. /etc/network/interfaces"

    if [[ -f /etc/network/interfaces ]]; then
        local _tmp _ifname _found_stale=0
        _tmp="$(mktemp /etc/network/interfaces.clean.XXXXXX)"
        local _skip_iface=""
        while IFS= read -r _line; do
            if [[ "${_line}" =~ ^iface[[:space:]]+([^[:space:]]+) ]]; then
                _ifname="${BASH_REMATCH[1]}"
                if [[ "${_ifname}" != "lo" ]] && [[ ! -e "/sys/class/net/${_ifname}" ]]; then
                    _skip_iface="${_ifname}"
                    _found_stale=1
                    _clean_report "quitando bloque: iface ${_ifname} (no existe en /sys/class/net)"
                    continue
                fi
                _skip_iface=""
            elif [[ -n "${_skip_iface}" ]]; then
                # Saltar lineas del bloque stale hasta la siguiente seccion o linea en blanco.
                if [[ "${_line}" =~ ^(iface|auto|allow-hotplug|source|#) ]] || [[ -z "${_line// /}" ]]; then
                    _skip_iface=""
                else
                    continue
                fi
            fi
            printf '%s\n' "${_line}"
        done < /etc/network/interfaces > "${_tmp}"

        if [[ "${_found_stale}" -eq 1 ]]; then
            cp -a /etc/network/interfaces "/etc/network/interfaces.bak.$(date +%Y%m%d-%H%M%S)"
            mv "${_tmp}" /etc/network/interfaces
            chmod 644 /etc/network/interfaces
            _clean_report "escrito /etc/network/interfaces (backup conservado)"
            _removed=$((_removed + 1))
        else
            rm -f "${_tmp}"
            _clean_report "sin entradas stale"
            _kept=$((_kept + 1))
        fi
    else
        _clean_report "/etc/network/interfaces no existe"
        _skipped=$((_skipped + 1))
    fi

    # ------------------------------------------------------------------
    # 6. Verificacion final: exactamente un gestor activo.
    # ------------------------------------------------------------------
    _clean_section "6. Verificacion"

    local _nm_active=0 _iwd_active=0
    systemctl is-active NetworkManager >/dev/null 2>&1 && _nm_active=1
    systemctl is-active iwd >/dev/null 2>&1 && _iwd_active=1

    if [[ $((_nm_active + _iwd_active)) -eq 0 ]]; then
        warn "ningun gestor WiFi activo -- corre: sudo wifi fallback off"
        _clean_report "gestores activos: 0"
    elif [[ $((_nm_active + _iwd_active)) -gt 1 ]]; then
        err "conflicto: NM e iwd activos a la vez -- corre: sudo wifi fallback off (o wifi fallback on)"
        _clean_report "gestores activos: NM=${_nm_active} iwd=${_iwd_active}"
    else
        ok "gestor unico: NM=${_nm_active} iwd=${_iwd_active}"
    fi

    echo "" >&2
    ok "clean: ${_removed} accion(es), ${_kept} sin cambios, ${_skipped} omitidos"
}
