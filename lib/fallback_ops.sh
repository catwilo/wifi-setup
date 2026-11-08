# shellcheck shell=bash
# lib/fallback_ops.sh -- operaciones publicas: status, on, off.
# Requiere common.sh + log.sh + nm.sh + networks.sh + fallback_state.sh.

fallback_status() {
    section "Fallback (iwd vs NetworkManager)"
    printf '  NetworkManager : %s\n' "$(_fallback_svc_snapshot NetworkManager)"
    printf '  iwd            : %s\n' "$(_fallback_svc_snapshot iwd)"

    local mode="?"
    if systemctl is-active iwd >/dev/null 2>&1; then
        mode="iwd (fallback)"
    elif systemctl is-active NetworkManager >/dev/null 2>&1; then
        mode="NetworkManager (backbone)"
    else
        mode="ninguno (sin gestor WiFi activo)"
    fi
    ok "gestor activo: ${mode}"

    if [[ -f "${FALLBACK_STATE}" ]]; then
        info "state previo guardado en ${FALLBACK_STATE}:"
        if [[ -r "${FALLBACK_STATE}" ]]; then
            while IFS= read -r _line; do
                printf '    %s\n' "${_line}"
            done < "${FALLBACK_STATE}"
        else
            printf '    (ilegible sin root -- corre: sudo cat %s)\n' "${FALLBACK_STATE}"
        fi
    fi
}

# fallback_on -- apagar NM, dejar iwd al mando con DHCP integrado.
# _fallback_fix_routes -- garantiza subred + default en la antena WiFi
# activa tras fallback on. Idempotente.
#
# Motivo: iwd con algunos drivers (brcmsmac) asigna IP via su DHCP pero
# no instala la ruta de subred. Sin ella, el kernel rechaza la default
# con "Nexthop has invalid gateway" y el nodo queda sin internet aunque
# la IP este asignada.
fallback_on() {
    # Asegurar config de iwd SIEMPRE, incluso si ya estamos en fallback:
    # asi un 'wifi fallback on' repara el archivo si le falta algo
    # (por ejemplo, quitar un DefaultInterface=true invalido que un sed
    # manual pudo haber dejado).
    _fallback_ensure_iwd_netconf

    if systemctl is-active iwd >/dev/null 2>&1 \
       && ! systemctl is-active NetworkManager >/dev/null 2>&1; then
        ok "ya estas en fallback (iwd activo, NM parado)"
        info "reincidiendo iwd para aplicar cualquier cambio de config..."
        systemctl restart iwd 2>/dev/null || true
        if ! _fallback_wait_ip 45; then
            err "iwd no obtuvo IP en 45s (ya estaba en fallback)"
            info "no se toca NM -- estado actual preservado"
            return 1
        fi
        _fallback_fix_routes || true
        return 0
    fi

    mkdir -p "${STATE_DIR}"
    {
        printf 'NM_ACTIVE_BEFORE=%s\n'  "$(systemctl is-active  NetworkManager 2>/dev/null || true)"
        printf 'NM_ENABLED_BEFORE=%s\n' "$(systemctl is-enabled NetworkManager 2>/dev/null || true)"
        printf 'IWD_ACTIVE_BEFORE=%s\n' "$(systemctl is-active iwd 2>/dev/null || true)"
        printf 'IWD_ENABLED_BEFORE=%s\n' "$(systemctl is-enabled iwd 2>/dev/null || true)"
    } > "${FALLBACK_STATE}"
    chmod 600 "${FALLBACK_STATE}"

    section "Cambiando a iwd (fallback)"

    info "parando NetworkManager..."
    systemctl stop NetworkManager 2>/dev/null || true
    info "enmascarando NetworkManager (evita autostart en boot)..."
    systemctl mask NetworkManager 2>/dev/null || true

    info "habilitando iwd..."
    systemctl unmask iwd 2>/dev/null || true
    systemctl enable iwd 2>/dev/null || true
    info "arrancando iwd..."
    systemctl restart iwd 2>/dev/null || true

    if ! systemctl is-active iwd >/dev/null 2>&1; then
        err "iwd no arranco -- revisa: journalctl -u iwd -n 40"
        warn "para volver atras: wifi fallback off"
        return 1
    fi
    ok "iwd activo -- es el gestor WiFi ahora"

    if ! _fallback_wait_ip 45; then
        err "iwd no obtuvo IP en 45s -- revirtiendo a NetworkManager"
        warn "el nodo NO queda en fallback: NM restaurado con internet"
        fallback_off || err "rollback tambien fallo -- intervencion manual"
        return 1
    fi
    _fallback_fix_routes || true

    info "conecta con: iwctl station <iface> connect <ssid>"
    info "scan con:    iwctl station <iface> scan"
}

# fallback_off -- volver a NetworkManager (backbone).
fallback_off() {
    if systemctl is-active NetworkManager >/dev/null 2>&1 \
       && ! systemctl is-active iwd >/dev/null 2>&1; then
        ok "ya estas en NetworkManager (iwd parado)"
        return 0
    fi

    section "Volviendo a NetworkManager (backbone)"

    # Importar antes de parar iwd: las redes que el usuario conocio via
    # iwctl viven en /var/lib/iwd/*.psk. Se agregan a la DB ahora (solo
    # lee archivos + escribe TSV, no usa NM). Los perfiles NM se crean
    # despues de arrancar NM (networks_sync usa nmcli, que necesita NM
    # corriendo).
    if command -v iwctl >/dev/null 2>&1; then
        info "importando redes conocidas por iwd a la DB..."
        networks_pull_iwd
    fi

    info "parando iwd..."
    systemctl stop iwd 2>/dev/null || true
    info "deshabilitando iwd..."
    systemctl disable iwd 2>/dev/null || true

    info "desenmascarando NetworkManager..."
    systemctl unmask NetworkManager 2>/dev/null || true
    info "habilitando NetworkManager..."
    systemctl enable NetworkManager 2>/dev/null || true
    info "arrancando NetworkManager..."
    systemctl restart NetworkManager 2>/dev/null || true

    if ! systemctl is-active NetworkManager >/dev/null 2>&1; then
        err "NetworkManager no arranco -- revisa: journalctl -u NetworkManager -n 40"
        return 1
    fi
    ok "NetworkManager activo -- backbone restaurado"

    # Ahora que NM corre, materializar los perfiles desde la DB (incluye
    # los importados desde iwd). Idempotente: si el perfil ya esta y
    # coincide, no lo toca.
    if [[ -f "${STATE_DIR}/networks.tsv" ]]; then
        info "sincronizando perfiles NM desde la DB..."
        networks_sync || warn "networks_sync fallo -- NM arrancara sin los perfiles importados"
    fi

    echo "" >&2
    info "devices en NM tras sync:"
    nmcli dev status 2>&1 >&2 || true
    echo "" >&2
    info "conexiones activas ahora:"
    local _act
    _act="$(nmcli -t -f NAME,DEVICE,TYPE con show --active 2>&1 || true)"
    if [[ -n "${_act}" ]]; then
        printf '%s\n' "${_act}" >&2
    else
        printf '  (ninguna)\n' >&2
    fi

    # Reset de las antenas WiFi: al parar iwd las interfaces quedan en un
    # estado que NM no re-descubre (no dispara evento de re-deteccion).
    # SOLO 'up' + 'managed yes': 'ip link set down' rompe la USB (el bus
    # USB se resetea y wlx1 desaparece de /sys). Con UseDefaultInterface
    # / DefaultInterface=false en /etc/iwd/main.conf, ademas, iwd ya no
    # destruye la iface al pararse, asi que basta con devolverla a NM.
    local _w _if
    for _w in /sys/class/net/*/wireless; do
        [ -d "${_w}" ] || continue
        _if="${_w%/wireless}"; _if="${_if##*/}"
        info "devolviendo ${_if} a NM..."
        ip link set "${_if}" up 2>/dev/null || true
        nmcli dev set "${_if}" managed yes 2>/dev/null || true
    done

    # Scan + tabla de intentos. Muestra: que redes ve NM ahora, y cada
    # 2s por 20s, el estado de cada antena + a que red intenta conectar.
    # Con eso el usuario ve en vivo si NM esta intentando y en que falla.
    echo "" >&2
    info "escaneando redes visibles (nmcli dev wifi list)..."
    nmcli dev wifi list 2>&1 >&2 || warn "scan fallo (NM sin antenas?)"

    echo "" >&2
    info "siguiendo intentos de conexion (20s)..."
    printf '  %-10s %-14s %-30s %s\n' "IFACE" "STATE" "CONN" "IP" >&2
    local _t=0 _any_conn=0
    while [[ "${_t}" -lt 20 ]]; do
        _any_conn=0
        for _w in /sys/class/net/*/wireless; do
            [[ -d "${_w}" ]] || continue
            _if="${_w%/wireless}"; _if="${_if##*/}"
            local _st _cn _ip
            _st="$(nmcli -t -f DEVICE,STATE dev status 2>/dev/null | awk -F: -v i="${_if}" '$1==i {print $2; exit}')"
            _cn="$(nmcli -t -f DEVICE,CONNECTION dev status 2>/dev/null | awk -F: -v i="${_if}" '$1==i {print $2; exit}')"
            _ip="$(ip -4 -o addr show "${_if}" 2>/dev/null | awk '{print $4}' | head -1)"
            printf '  %-10s %-14s %-30s %s\n' "${_if}" "${_st:-?}" "${_cn:--}" "${_ip:--}" >&2
            [[ -n "${_cn}" ]] && _any_conn=1
            [[ -n "${_ip}" ]] && { ok "IP asignada: ${_if} ${_ip}"; _t=999; break; }
        done
        [[ "${_t}" -eq 999 ]] && break
        sleep 2
        _t=$((_t + 2))
    done

    if [[ "${_t}" -ne 999 ]]; then
        echo "" >&2
        warn "ninguna antena obtuvo IP en 20s"
        echo "" >&2
        info "ultimos 8 eventos de NetworkManager (causa del fallo):"
        journalctl -u NetworkManager -n 8 --no-pager 2>&1 >&2 || true
        echo "" >&2
        err "fallback off fallo: NM arranco pero ninguna antena obtuvo IP"
        info "fallback_state preservado en ${FALLBACK_STATE}"
        info "siguientes pasos:"
        info "  wifi status"
        return 1
    fi

    rm -f "${FALLBACK_STATE}"
}

