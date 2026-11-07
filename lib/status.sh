# shellcheck shell=bash
# lib/status.sh -- status_run: reporte completo del stack WiFi.
# Solo lectura. Requiere common.sh + log.sh + radio.sh (via _load).

status_run() {
    _radio_load_state

    section "Gestor WiFi"
    local _mgr="ninguno"
    if systemctl is-active NetworkManager >/dev/null 2>&1; then
        _mgr="NetworkManager"
        ok "NetworkManager activo (backbone)"
    elif systemctl is-active iwd >/dev/null 2>&1; then
        _mgr="iwd"
        ok "iwd activo (fallback)"
    else
        warn "sin gestor WiFi activo (NM e iwd parados)"
    fi

    section "Interfaces"
    ip -br addr 2>/dev/null || warn "ip no disponible"

    section "Ruta default"
    local _routes
    _routes="$(ip route show default 2>/dev/null || true)"
    if [ -n "$_routes" ]; then
        printf '%s\n' "$_routes"
    else
        warn "sin ruta default (posible corte de red)"
    fi

    section "Antenas WiFi (red conectada por antena)"
    local _p _if _found=0
    printf '  %-10s %-10s %-10s %-24s %s\n' "IFACE" "ROL" "ESTADO" "RED" "IP" >&2
    for _p in /sys/class/net/*/wireless; do
        [ -d "$_p" ] || continue
        _found=1
        _if="${_p%/wireless}"; _if="${_if##*/}"
        local _state _net _ip _rol
        _rol=""
        [[ "${_if}" == "${RADIO_PRIMARY:-}"   ]] && _rol="primary"
        [[ "${_if}" == "${RADIO_SECONDARY:-}" ]] && _rol="secondary"
        _state="$(cat "/sys/class/net/${_if}/operstate" 2>/dev/null || echo "?")"
        _ip="$(ip -4 -o addr show "${_if}" 2>/dev/null | awk '{print $4}' | head -1)"
        _net=""
        if [ "${_mgr}" = "NetworkManager" ]; then
            local _prof
            _prof="$(nmcli -t -f DEVICE,CONNECTION dev status 2>/dev/null \
                | awk -F: -v i="${_if}" '$1==i {print $2; exit}')"
            if [ -n "${_prof}" ]; then
                local _ssid
                _ssid="$(nmcli -t -g 802-11-wireless.ssid con show "${_prof}" 2>/dev/null | head -1 || true)"
                _net="${_ssid:-${_prof}}"
            fi
        elif [ "${_mgr}" = "iwd" ]; then
            _net="$(iwctl station "${_if}" show 2>/dev/null \
                | awk -F'  +' '/Connected network/ {print $3; exit}')"
        fi
        printf '  %-10s %-10s %-10s %-24s %s\n' \
            "${_if}" "${_rol}" "${_state}" "${_net:--}" "${_ip:--}" >&2
    done
    [ "${_found}" -eq 1 ] || warn "no se detectaron antenas WiFi en el kernel"

    if [ "${_mgr}" = "NetworkManager" ]; then
        section "Perfiles NM"
        local _total=0 _auto=0 _noauto=0
        local _name _autoflag
        while IFS= read -r _name; do
            [ -n "${_name}" ] || continue
            _total=$((_total + 1))
            _autoflag="$(nmcli -t -g connection.autoconnect con show "${_name}" 2>/dev/null || true)"
            if [ "${_autoflag}" = "yes" ]; then
                _auto=$((_auto + 1))
            else
                _noauto=$((_noauto + 1))
            fi
        done < <(nmcli -t -f NAME,TYPE con show 2>/dev/null | awk -F: '$2=="802-11-wireless"{print $1}')
        printf '  total:              %d\n' "${_total}"
        printf '  autoconectadas:     %d\n' "${_auto}"
        printf '  NO autoconectadas:  %d\n' "${_noauto}"
    fi

    section "Internet"
    if ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; then
        ok "OK (ping 1.1.1.1)"
    else
        warn "sin conectividad a 1.1.1.1"
    fi
}
