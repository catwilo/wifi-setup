#!/usr/bin/env bash
# lib/fallback.sh -- alterna entre NetworkManager (backbone) e iwd (fallback).
#
# RESPONSABILIDAD UNICA: apagar limpiamente NetworkManager y dejar iwd al
# mando con DHCP integrado, o revertir exactamente ese cambio.
#
# MODELO:
#   - fallback on:     para + enmascara NM, activa DHCP integrado de iwd
#                      (EnableNetworkConfiguration=true en /etc/iwd/main.conf),
#                      arranca + habilita iwd.
#   - fallback off:    para iwd, desenmascara + arranca NM.
#   - fallback status: reporta quien esta al mando ahora.
#
# Persistencia: STATE_DIR/fallback.state guarda el estado previo al "on"
# para que "off" restaure el estado original sin asumir nada.
#
# DHCP: iwd hace DHCP por si mismo cuando EnableNetworkConfiguration=true;
# no se necesita dhcpcd ni NM corriendo. Al volver a NM, NM toma su DHCP.
#
# Los perfiles NM NO se tocan: cuando NM vuelve, reconecta solo con ellos.
# iwd no ve esos perfiles; al arrancar por primera vez pide credenciales
# (iwctl) o espera configuracion. No se pierden credenciales.
#
# Requiere: common.sh + log.sh cargados antes.

FALLBACK_STATE="${STATE_DIR}/fallback.state"

# _fallback_svc_snapshot <svc> -- "active=X enabled=Y" compacto.
_fallback_svc_snapshot() {
    local svc="$1" active enabled
    active="$(systemctl is-active  "${svc}" 2>/dev/null || true)"
    enabled="$(systemctl is-enabled "${svc}" 2>/dev/null || true)"
    printf 'active=%s enabled=%s\n' "${active:-unknown}" "${enabled:-unknown}"
}

# _fallback_ensure_iwd_netconf -- garantiza que iwd haga DHCP por si mismo
# (sin dhcpcd ni NM corriendo). Escribe /etc/iwd/main.conf con la directiva
# EnableNetworkConfiguration=true. Idempotente: solo toca el archivo si
# falta la directiva. Preserva el resto de la config del usuario.
_fallback_ensure_iwd_netconf() {
    local conf="/etc/iwd/main.conf"
    mkdir -p /etc/iwd

    # Directivas necesarias para que iwd sea autonomo:
    #   [General] EnableNetworkConfiguration=true  -> DHCP integrado de
    #     iwd. NO usar dhcpcd en paralelo: pelean por la misma iface y
    #     el resultado es "espera y espera sin IP".
    #   [Network] NameResolvingService=none  -> iwd no toca resolv.conf.
    #     En este equipo Tailscale es quien lo maneja.
    #   [DriverQuirks] DefaultInterface=false  -> iwd NO destruye la
    #     iface al pararse (reemplaza al deprecated UseDefaultInterface).
    #     Sin esto, 'systemctl stop iwd' borra wlan0 del kernel y NM no
    #     la ve hasta recargar el driver.
    local need_netconf=0 need_resolv=0 need_iface=0
    if [[ ! -s "${conf}" ]] \
       || ! grep -qE '^[[:space:]]*EnableNetworkConfiguration[[:space:]]*=[[:space:]]*true' "${conf}"; then
        need_netconf=1
    fi
    if [[ ! -s "${conf}" ]] \
       || ! grep -qE '^[[:space:]]*NameResolvingService[[:space:]]*=' "${conf}"; then
        need_resolv=1
    fi
    if [[ ! -s "${conf}" ]] \
       || ! grep -qE '^[[:space:]]*DefaultInterface[[:space:]]*=' "${conf}"; then
        need_iface=1
    fi

    if [[ "${need_netconf}" -eq 0 && "${need_resolv}" -eq 0 && "${need_iface}" -eq 0 ]]; then
        info "iwd: main.conf ya tiene las directivas necesarias"
        return 0
    fi

    local _sep=""
    [[ -s "${conf}" ]] && _sep=$'\n'
    {
        printf '%s' "${_sep}"
        if [[ "${need_netconf}" -eq 1 ]]; then
            printf '[General]\n'
            printf 'EnableNetworkConfiguration=true\n'
        fi
        if [[ "${need_resolv}" -eq 1 ]]; then
            printf '\n[Network]\n'
            printf 'NameResolvingService=none\n'
        fi
        if [[ "${need_iface}" -eq 1 ]]; then
            printf '\n[DriverQuirks]\n'
            printf 'DefaultInterface=false\n'
        fi
    } >> "${conf}"

    [[ "${need_netconf}" -eq 1 ]] && ok "iwd: DHCP integrado habilitado en ${conf}"
    [[ "${need_resolv}" -eq 1 ]] && ok "iwd: NameResolvingService=none (Tailscale maneja DNS)"
    [[ "${need_iface}"  -eq 1 ]] && ok "iwd: DriverQuirks.DefaultInterface=false (no destruye la antena)"
    return 0
}

# _fallback_wait_ip <timeout-s> -- espera a que alguna antena WiFi tenga IP.
# Verboso: en cada ciclo imprime el estado de cada antena (ip link state,
# nmcli dev status, a que red intenta conectar y si esta activa). Best-effort:
# no aborta si vence el timeout.
_fallback_wait_ip() {
    local timeout="${1:-30}" waited=0 ip w
    info "esperando IP en alguna antena WiFi (max ${timeout}s)..."
    printf '  %-10s %-12s %-16s %s\n' "IFACE" "STATE" "CONN" "IP" >&2
    while [[ "${waited}" -lt "${timeout}" ]]; do
        for w in /sys/class/net/*/wireless; do
            [[ -d "${w}" ]] || continue
            w="${w%/wireless}"; w="${w##*/}"
            local state conn
            state="$(nmcli -t -f DEVICE,STATE dev status 2>/dev/null \
                | awk -F: -v i="${w}" '$1==i {print $2; exit}')"
            conn="$(nmcli -t -f DEVICE,CONNECTION dev status 2>/dev/null \
                | awk -F: -v i="${w}" '$1==i {print $2; exit}')"
            ip="$(ip -4 -o addr show "${w}" 2>/dev/null | awk '{print $4}' | head -1)"
            printf '  %-10s %-12s %-16s %s\n' \
                "${w}" "${state:-?}" "${conn:-—}" "${ip:-—}" >&2
            if [[ -n "${ip}" ]]; then
                ok "IP asignada: ${w} ${ip}"
                return 0
            fi
        done
        sleep 3
        waited=$((waited + 3))
    done
    warn "ninguna antena obtuvo IP en ${timeout}s"

    # Diagnostico final: que perfiles existen, cuales estan activos, y
    # que dice NM sobre intentos fallidos.
    echo "" >&2
    info "perfiles NM conocidos:"
    nmcli -t -f NAME,TYPE con show 2>&1 | grep '802-11-wireless' >&2 || true
    echo "" >&2
    info "intentos fallidos (ultimos 5):"
    nmcli -f GENERAL.STATE,GENERAL.CONNECTION dev show 2>&1 | grep -E 'GENERAL\.' >&2 || true
    return 1
}

# fallback_status -- quien esta al mando.
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
fallback_on() {
    if systemctl is-active iwd >/dev/null 2>&1 \
       && ! systemctl is-active NetworkManager >/dev/null 2>&1; then
        ok "ya estas en fallback (iwd activo, NM parado)"
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
    _fallback_ensure_iwd_netconf

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

    _fallback_wait_ip 30 || true

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
        networks_import_from_iwd
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
            printf '  %-10s %-14s %-30s %s\n' "${_if}" "${_st:-?}" "${_cn:-—}" "${_ip:-—}" >&2
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
    fi

    rm -f "${FALLBACK_STATE}"
}
