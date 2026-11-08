# shellcheck shell=bash
# lib/radio_ops.sh -- up/down/boot + inventario fisico (ifaces_list).
# Requiere common.sh + nm.sh + networks.sh + radio_state.sh.

radio_up() {
    local iface="${1:-}" persist=0
    shift || true
    for a in "$@"; do [[ "${a}" == "--persist" ]] && persist=1; done
    [[ -n "${iface}" ]] || die "uso: wifi radio up <iface> [--persist]"
    radio_is_iface "${iface}" || die "'${iface}' no es una interfaz WiFi"

    # Enciende la antena a nivel kernel SIEMPRE. Si ademas hay un perfil
    # NM asociado, lo activa. Si no lo hay, la antena queda encendida y
    # lista para scan/monitor/nuevo perfil. No morir por falta de perfil.
    ip link set "${iface}" up 2>/dev/null || true
    if nm_require 2>/dev/null; then
        nmcli dev set "${iface}" managed yes 2>/dev/null || true
    fi

    local con
    con="$(_radio_iface_con "${iface}" 2>/dev/null || true)"
    if [[ -n "${con}" ]]; then
        if nm_device_connect "${iface}"; then
            ok "${iface} encendida, conectada via NM (perfil '${con}')"
        else
            warn "${iface} encendida, pero no conecto (revisa: wifi status)"
        fi
        if [[ "${persist}" -eq 1 ]]; then
            nm_con_set_autoconnect "${con}" on 2>/dev/null || true
            local _ssid
            _ssid="$(nmcli -t -g 802-11-wireless.ssid con show "${con}" 2>/dev/null | head -1 || true)"
            [[ -n "${_ssid}" ]] && _radio_db_set_autoconnect "${_ssid}" "${iface}" "yes"
            ok "autoconnect ON persistente: ${con} (NM + DB)"
        fi
    else
        ok "${iface} encendida (sin perfil NM -- usa wifi add para conectarla)"
        if [[ "${persist}" -eq 1 ]]; then
            ok "${iface} persistente: managed=yes"
        fi
    fi
}

# ---------------------------------------------------------------------------
# radio_down <iface> [--persist]
# ---------------------------------------------------------------------------
radio_down() {
    local iface="${1:-}" persist=0
    shift || true
    for a in "$@"; do [[ "${a}" == "--persist" ]] && persist=1; done
    [[ -n "${iface}" ]] || die "uso: wifi radio down <iface> [--persist]"
    radio_is_iface "${iface}" || die "'${iface}' no es una interfaz WiFi"

    # 1) Bajar la conexion ACTIVA de esa iface, si hay una. No intentar
    #    bajar un perfil arbitrario: si la iface no tiene conexion activa,
    #    solo hay que deshabilitar autoconnect (paso 2).
    local active
    active="$(nmcli -t -f DEVICE,CONNECTION dev status 2>/dev/null \
        | awk -F: -v i="${iface}" '$1==i && $2!="" {print $2; exit}')"
    if [[ -n "${active}" ]]; then
        nm_con_down "${active}"
        info "conexion activa bajada: ${active}"
    else
        info "${iface} sin conexion activa"
    fi

    # Con --persist, la iface deja de ser PRIMARY si lo era. El flag ya no
    # toca autoconnect por perfil: eso es territorio del rol
    # (radio_apply_autoconnect) y del override manual del usuario
    # (wifi autoconnect set). Aqui solo se ajusta el rol persistido.
    if [[ "${persist}" -eq 1 ]]; then
        _radio_load_state
        if [[ "${iface}" == "${RADIO_PRIMARY}" ]]; then
            RADIO_PRIMARY=""
            _radio_save_state
            radio_apply_autoconnect
            info "${iface} ya no es PRIMARY (sin PRIMARY persistida)"
        else
            info "${iface} no era PRIMARY -- nada que persistir"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Inventario fisico de antenas WiFi.
# ---------------------------------------------------------------------------

# _radio_kernel_ifaces -- lista ifaces WiFi presentes en el kernel, no en NM.
# Una iface WiFi tiene /sys/class/net/<iface>/wireless/ o phy80211.
radio_ifaces_list() {
    nm_require

    printf '%-10s %-5s %-16s %-20s %-8s %s\n' \
        "IFACE" "BUS" "DRIVER" "MAC PERMANENTE" "KERNEL" "NM"
    printf '%s\n' "--------------------------------------------------------------------------------"

    local iface bus driver mac kstate nstate found_any=0
    while IFS= read -r iface; do
        [[ -n "${iface}" ]] || continue
        found_any=1
        bus="$(_radio_bus_of "${iface}")"
        driver="$(_radio_driver_of "${iface}")"
        mac="$(_radio_permanent_mac_of "${iface}")"
        kstate="$(_radio_kernel_state_of "${iface}")"
        nstate="$(_radio_nm_state_of "${iface}")"
        printf '%-10s %-5s %-16s %-20s %-8s %s\n' \
            "${iface}" "${bus}" "${driver}" "${mac}" "${kstate}" "${nstate}"
    done < <(_radio_kernel_ifaces)

    if [[ "${found_any}" -eq 0 ]]; then
        warn "no se detecto ninguna antena WiFi en el kernel"
        warn "verifica: ls /sys/class/net/*/wireless, lsusb, lspci"
        return 1
    fi
}


# radio_boot -- fallback de antena al arranque: si PRIMARY no
# tiene IP tras NetworkManager-wait-online (sin polling ni sleep),
# pide a NM que conecte SECONDARY (NM elige entre las visibles).
# Corre UNA VEZ
# al boot via wifi-setup-boot-select.service. No es watchdog: no
# interfiere con estado de runtime. Si el usuario activa ambas antenas
# despues del boot, nada las toca.
# ---------------------------------------------------------------------------
radio_boot() {
    _radio_load_state
    local primary="${RADIO_PRIMARY:-}"
    local secondary="${RADIO_SECONDARY:-}"

    if [[ -z "${primary}" || -z "${secondary}" ]]; then
        info "radio boot: sin PRIMARY/SECONDARY definidas -- nada que hacer"
        return 0
    fi

    # La unit lleva After=NetworkManager-wait-online.service: para cuando
    # arranca, NM ya termino su startup completo. Comprobacion instantanea,
    # sin polling ni sleep. Si NM no esta activo (iwd al mando), este
    # servicio no tiene trabajo: exit 0 limpio.
    if ! systemctl is-active NetworkManager; then
        info "radio boot: NM no activo (iwd al mando) -- nada que hacer"
        return 0
    fi

    local ip
    ip="$(ip -4 -o addr show "${primary}" | awk '{print $4}' | head -1)"
    if [[ -n "${ip}" ]]; then
        info "radio boot: ${primary} con IP ${ip} -- nada que hacer"
        return 0
    fi

    ip="$(ip -4 -o addr show "${secondary}" | awk '{print $4}' | head -1)"
    if [[ -n "${ip}" ]]; then
        info "radio boot: ${secondary} ya tiene IP ${ip} -- nada que hacer"
        return 0
    fi

    warn "radio boot: ${primary} sin IP tras wait-online -- activando ${secondary}"

    if ! ip link show "${secondary}"; then
        err "radio boot: ${secondary} no existe en el kernel -- sin fallback"
        return 1
    fi

    # Elegir el SSID de SECONDARY con mayor prioridad en la DB (una sola
    # pasada de awk: sin sort/head/cut).
    info "radio boot: conectando ${secondary} (NM elige entre las visibles)"
    ip link set "${secondary}" up
    nmcli dev set "${secondary}" managed yes
    if nm_device_connect "${secondary}"; then
        ok "radio boot: ${secondary} conectada"
        return 0
    fi
    err "radio boot: no se pudo conectar ${secondary}"
    return 1
}

