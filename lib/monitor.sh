#!/usr/bin/env bash
# lib/monitor.sh -- modo monitor sobre una antena WiFi, sin tocar las otras.
#
# RESPONSABILIDAD UNICA: cambiar el tipo de una iface WiFi entre managed
# y monitor. No gestiona perfiles, no conecta, no renombra.
#
# MODELO:
#   - wifi monitor on  <iface>  deja la iface en monitor (NM deja de
#     gestionarla, la iface NO se conecta a ninguna red).
#   - wifi monitor off <iface>  la devuelve a managed; NM la retoma y
#     reconecta con su perfil (autoconnect=on).
#   - wifi monitor status       lista que ifaces estan en monitor y
#     cuales en managed.
#
# Seguridad: antes de poner una iface en monitor, se avisa si es la
# unica antena con conexion -- un error de uso ahi corta el acceso
# remoto. La operacion no se bloquea (el usuario puede tener consola
# fisica), pero el aviso es explicito.
#
# Requiere: common.sh + nm.sh + radio.sh cargados antes.

# ---------------------------------------------------------------------------
# _monitor_iface_type <iface> -- imprime managed|monitor|unknown.
# ---------------------------------------------------------------------------
_monitor_iface_type() {
    local iface="$1"
    local type
    type="$(iw dev "${iface}" info 2>/dev/null \
        | awk '/type/ {print $2; exit}')"
    case "${type}" in
        managed)  echo "managed" ;;
        monitor)  echo "monitor" ;;
        *)        echo "unknown" ;;
    esac
}

# ---------------------------------------------------------------------------
# _monitor_iface_is_connected <iface> -- 0 si NM la tiene conectada.
# ---------------------------------------------------------------------------
_monitor_iface_is_connected() {
    local iface="$1"
    nmcli -t -f DEVICE,STATE dev status 2>/dev/null \
        | awk -F: -v i="${iface}" '$1==i && $2=="connected" {found=1} END{exit !found}'
}

# ---------------------------------------------------------------------------
# _monitor_other_iface_with_ip <iface> -- imprime el nombre de OTRA iface
# WiFi que tenga IP, o vacio si no hay.
# ---------------------------------------------------------------------------
_monitor_other_iface_with_ip() {
    local exclude="$1"
    local other
    while IFS= read -r other; do
        [[ -n "${other}" ]] || continue
        [[ "${other}" == "${exclude}" ]] && continue
        if ip -4 -o addr show "${other}" 2>/dev/null | awk '{print $4}' | grep -q .; then
            echo "${other}"
            return 0
        fi
    done < <(radio_ifaces)
    return 1
}

# ---------------------------------------------------------------------------
# monitor_on <iface> -- pone la iface en modo monitor.
# ---------------------------------------------------------------------------
monitor_on() {
    local iface="${1:-}"
    [[ -n "${iface}" ]] || die "uso: wifi monitor on <iface>"
    radio_is_iface "${iface}" || die "'${iface}' no es una interfaz WiFi"

    command -v iw >/dev/null 2>&1 \
        || die "iw no instalado -- corre: sudo apt install iw"

    # Chequeo de seguridad: si esta es la unica antena con conexion,
    # avisar. No bloquea (el usuario puede tener acceso fisico).
    local current_type
    current_type="$(_monitor_iface_type "${iface}")"
    if [[ "${current_type}" == "monitor" ]]; then
        info "${iface} ya esta en modo monitor -- nada que hacer"
        return 0
    fi

    if _monitor_iface_is_connected "${iface}"; then
        local other
        other="$(_monitor_other_iface_with_ip "${iface}" || true)"
        if [[ -z "${other}" ]]; then
            warn "esta es la UNICA antena con conexion -- el acceso remoto se puede cortar"
            warn "si no tenes consola fisica, abortá ahora (Ctrl-C)"
        else
            info "otra antena con conexion: ${other} (acceso remoto a salvo)"
        fi
    fi

    # NM deja de gestionar la iface.
    info "liberando ${iface} de NetworkManager..."
    nmcli dev set "${iface}" managed no >/dev/null 2>&1 || true
    sleep 1

    info "poniendo ${iface} en modo monitor..."
    ip link set "${iface}" down 2>/dev/null || true
    if ! iw dev "${iface}" set type monitor 2>/dev/null; then
        # Reintentar con el modo fallback si el primero no acepta.
        iw dev "${iface}" set monitor control 2>/dev/null \
            || {
                # Recuperar a managed y abortar limpio.
                ip link set "${iface}" up 2>/dev/null || true
                nmcli dev set "${iface}" managed yes >/dev/null 2>&1 || true
                die "no se pudo poner ${iface} en modo monitor -- revisa: iw dev ${iface} info"
            }
    fi
    ip link set "${iface}" up 2>/dev/null || true
    sleep 1

    local new_type
    new_type="$(_monitor_iface_type "${iface}")"
    if [[ "${new_type}" != "monitor" ]]; then
        # Rollback a managed.
        ip link set "${iface}" down 2>/dev/null || true
        iw dev "${iface}" set type managed 2>/dev/null || true
        ip link set "${iface}" up 2>/dev/null || true
        nmcli dev set "${iface}" managed yes >/dev/null 2>&1 || true
        die "${iface} no quedo en monitor (tipo actual: ${new_type})"
    fi

    ok "${iface} en modo monitor"
}

# ---------------------------------------------------------------------------
# monitor_off <iface> -- devuelve la iface a managed.
# ---------------------------------------------------------------------------
monitor_off() {
    local iface="${1:-}"
    [[ -n "${iface}" ]] || die "uso: wifi monitor off <iface>"
    radio_is_iface "${iface}" || die "'${iface}' no es una interfaz WiFi"

    command -v iw >/dev/null 2>&1 \
        || die "iw no instalado -- corre: sudo apt install iw"

    local current_type
    current_type="$(_monitor_iface_type "${iface}")"
    if [[ "${current_type}" == "managed" ]]; then
        info "${iface} ya esta en managed -- nada que hacer"
        return 0
    fi

    info "devolviendo ${iface} a managed..."
    ip link set "${iface}" down 2>/dev/null || true
    iw dev "${iface}" set type managed 2>/dev/null \
        || die "no se pudo cambiar ${iface} a managed"
    ip link set "${iface}" up 2>/dev/null || true
    sleep 1

    info "devolviendo ${iface} a NetworkManager..."
    nmcli dev set "${iface}" managed yes >/dev/null 2>&1 || true
    sleep 2

    # NM deberia reconectar con su perfil (autoconnect=on).
    local con
    con="$(_radio_iface_con "${iface}" 2>/dev/null || true)"
    if [[ -n "${con}" ]]; then
        info "perfil '${con}' reconocido por NM; si no conecta en 15s, revisa: wifi doctor"
    fi

    ok "${iface} en managed"
}

# ---------------------------------------------------------------------------
# monitor_status -- tabla: iface, tipo, NM state.
# ---------------------------------------------------------------------------
monitor_status() {
    nm_require
    command -v iw >/dev/null 2>&1 || die "iw no instalado"

    printf '%-10s %-10s %s\n' "IFACE" "TYPE" "NM"
    printf '%s\n' "------------------------------------"

    local iface type nm_state
    while IFS= read -r iface; do
        [[ -n "${iface}" ]] || continue
        type="$(_monitor_iface_type "${iface}")"
        if nmcli -t -f DEVICE,TYPE dev status 2>/dev/null \
              | awk -F: -v i="${iface}" '$1==i && $2=="wifi"{found=1} END{exit !found}'; then
            nm_state="$(nmcli -t -f DEVICE,STATE dev status 2>/dev/null \
                | awk -F: -v i="${iface}" '$1==i {print $2}')"
        else
            nm_state="no gestionada"
        fi
        printf '%-10s %-10s %s\n' "${iface}" "${type}" "${nm_state}"
    done < <(radio_ifaces)
}
