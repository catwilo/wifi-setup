#!/usr/bin/env bash
# lib/nm.sh -- wrapper fino sobre nmcli.
#
# RESPONSABILIDAD UNICA: encapsular las llamadas a nmcli. Ningun otro
# modulo llama nmcli directo. Si el formato de salida o los flags de
# nmcli cambian, se ajusta solo este archivo.
#
# Convencion de nombres:
#   nm_con_*     operaciones sobre conexiones (perfiles)
#   nm_dev_*     operaciones sobre devices (interfaces fisicas)
#   nm_*         consultas generales / utilidades
#
# Requiere: common.sh sourceado antes (log.sh cargado, die/warn/ok/info).

# ---------------------------------------------------------------------------
# nm_require -- falla claro si NM no esta.
# ---------------------------------------------------------------------------
nm_require() {
    command -v nmcli >/dev/null 2>&1 \
        || die "NetworkManager no instalado -- corre: sudo wifi install"
    if systemctl is-active NetworkManager >/dev/null 2>&1; then
        return 0
    fi
    # Diferenciar fallback (iwd al mando) de NM simplemente parado.
    # iwd es fallback manual fuera del alcance de wifi-setup: el usuario
    # decide si volver a NM o manejar iwd a mano con iwctl.
    if systemctl is-active iwd >/dev/null 2>&1; then
        die "NetworkManager no activo: modo fallback con iwd al mando. Vuelve a NM con: wifi fallback off"
    fi
    die "NetworkManager no activo -- corre: sudo systemctl start NetworkManager"
}

# ---------------------------------------------------------------------------
# Consultas
# ---------------------------------------------------------------------------

# nm_dev_list -- imprime "iface<TAB>type<TAB>state<TAB>connection"
nm_dev_list() {
    nmcli -t -f DEVICE,TYPE,STATE,CONNECTION dev status
}

# nm_dev_wifi_list -- solo WiFi.
nm_dev_wifi_list() {
    nmcli -t -f DEVICE,TYPE,STATE,CONNECTION dev status \
        | awk -F: '$2=="wifi"'
}

# nm_dev_ethernet_list -- solo ethernet.
nm_dev_ethernet_list() {
    nmcli -t -f DEVICE,TYPE,STATE,CONNECTION dev status \
        | awk -F: '$2=="ethernet"'
}

# nm_dev_show <iface> -- detalle de un device.
nm_dev_show() {
    local iface="$1"
    nmcli dev show "${iface}"
}

# nm_dev_is_managed <iface> -- 0 si NM lo gestiona.
nm_dev_is_managed() {
    local iface="$1" managed
    managed="$(nmcli -t -f GENERAL.STATE dev show "${iface}" 2>/dev/null \
        | awk -F: '{print $2}')"
    [[ "${managed}" != "unmanaged" ]]
}

# nm_con_list -- imprime "name<TAB>uuid<TAB>type<TAB>device"
nm_con_list() {
    nmcli -t -f NAME,UUID,TYPE,DEVICE con show
}

# nm_con_exists <name> -- 0 si el perfil existe.
nm_con_exists() {
    local name="$1"
    nmcli -t -f NAME con show | grep -qxF "${name}"
}

# nm_con_get <name> <field> -- imprime un campo de un perfil.
nm_con_get() {
    local name="$1" field="$2"
    nmcli -t -g "${field}" con show "${name}" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Operaciones sobre conexiones
# ---------------------------------------------------------------------------

# nm_con_delete <name> -- borra un perfil. Idempotente.
nm_con_delete() {
    local name="$1"
    if nm_con_exists "${name}"; then
        nmcli con delete "${name}" >/dev/null
        info "perfil borrado: ${name}"
    fi
}

# nm_con_up <name> -- activa un perfil. Sin redireccion: la salida real
# de nmcli (stdout + stderr) llega al caller para que el usuario vea la
# causa exacta del exito o del fallo.
nm_con_up() {
    local name="$1"
    nmcli con up "${name}"
}

# nm_con_down <name> -- desactiva un perfil. Sin redireccion: la salida
# de nmcli llega al caller, que decide si mostrarla o registrarla.
nm_con_down() {
    local name="$1"
    nmcli con down "${name}"
}

# nm_con_set_autoconnect <name> on|off
nm_con_set_autoconnect() {
    local name="$1" mode="$2"
    [[ "${mode}" == "on" || "${mode}" == "off" ]] \
        || die "nm_con_set_autoconnect: modo invalido '${mode}'"
    nmcli con mod "${name}" connection.autoconnect "${mode}" >/dev/null
}

# nm_con_set_priority <name> <n> -- mayor = preferido.
nm_con_set_priority() {
    local name="$1" n="$2"
    nmcli con mod "${name}" connection.autoconnect-priority "${n}" >/dev/null
}

# ---------------------------------------------------------------------------
# Crear perfiles
# ---------------------------------------------------------------------------

# nm_wifi_create <profile> <iface> <ssid> <psk>
# Crea (o reemplaza) un perfil WiFi WPA-PSK.
nm_wifi_create() {
    local profile="$1" iface="$2" ssid="$3" psk="$4"
    nm_con_delete "${profile}"
    nmcli con add \
        type wifi \
        con-name "${profile}" \
        ifname "${iface}" \
        ssid "${ssid}" \
        -- \
        wifi-sec.key-mgmt wpa-psk \
        wifi-sec.psk "${psk}" >/dev/null
    info "perfil WiFi creado: ${profile} (${iface} -> ${ssid})"
}

# nm_ethernet_create <profile> <iface> <method> [<ip_cidr> <gateway>]
#   method: manual | shared | auto
#   manual requiere ip_cidr (1.2.3.2/24) y opcionalmente gateway
nm_ethernet_create() {
    local profile="$1" iface="$2" method="$3" ip_cidr="${4:-}" gateway="${5:-}"
    nm_con_delete "${profile}"

    case "${method}" in
        manual)
            [[ -n "${ip_cidr}" ]] \
                || die "nm_ethernet_create: method=manual requiere ip_cidr"
            nmcli con add \
                type ethernet \
                con-name "${profile}" \
                ifname "${iface}" \
                ipv4.method manual \
                ipv4.addresses "${ip_cidr}" >/dev/null
            if [[ -n "${gateway}" ]]; then
                nmcli con mod "${profile}" ipv4.gateway "${gateway}" >/dev/null
            fi
            ;;
        shared)
            nmcli con add \
                type ethernet \
                con-name "${profile}" \
                ifname "${iface}" \
                ipv4.method shared >/dev/null
            ;;
        auto)
            nmcli con add \
                type ethernet \
                con-name "${profile}" \
                ifname "${iface}" \
                ipv4.method auto >/dev/null
            ;;
        *)
            die "nm_ethernet_create: method invalido '${method}' (manual|shared|auto)"
            ;;
    esac

    info "perfil ethernet creado: ${profile} (${iface}, method=${method})"
}

# ---------------------------------------------------------------------------
# Clonado de MAC
# ---------------------------------------------------------------------------

# nm_con_set_mac <name> <mac|permanent|stable|random>
nm_con_set_mac() {
    local name="$1" mac="$2"
    nmcli con mod "${name}" 802-3-ethernet.cloned-mac-address "${mac}" >/dev/null
}

# nm_con_set_mac_wifi <name> <mac|permanent|stable|random>
nm_con_set_mac_wifi() {
    local name="$1" mac="$2"
    nmcli con mod "${name}" 802-11-wireless.cloned-mac-address "${mac}" >/dev/null
}

# ---------------------------------------------------------------------------
# Utilidad: mostrar un resumen compacto para wifi status.
# ---------------------------------------------------------------------------
nm_summary() {
    echo "== Devices =="
    nm_dev_list
    echo ""
    echo "== Connections (autoconnect) =="
    local name auto
    while IFS= read -r name; do
        [[ -n "${name}" ]] || continue
        auto="$(nm_con_get "${name}" connection.autoconnect)"
        printf '  %-30s autoconnect=%s\n' "${name}" "${auto:-?}"
    done < <(nmcli -t -f NAME con show | grep -v '^$')
}

# ---------------------------------------------------------------------------
# USB WiFi naming
# ---------------------------------------------------------------------------
# Lee config/usb-names.conf (una linea por adapter: <mac> <name>) y escribe
# un .link de systemd por cada mapping. Aplica en el proximo boot.
#
# El .link fuerza el nombre de la iface por PermanentMACAddress (MAC de
# fabrica, estable entre boots y spoofeos). Si el adapter ya tiene el
# nombre correcto, no hace nada.
#
# Idempotente: si el .link existe con el mismo contenido, no lo reescribe.

NM_USB_LINK_DIR="${NM_USB_LINK_DIR:-/etc/systemd/network}"
NM_USB_LINK_PREFIX="10-wifi-setup-"

# _nm_usb_valid_mac <mac> -- 0 si es MAC valida en formato aa:bb:cc:dd:ee:ff
_nm_usb_valid_mac() {
    [[ "${1:-}" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]
}

# _nm_usb_valid_name <name> -- 0 si el nombre es seguro para .link.
# Solo letras, numeros, guion y guion bajo; sin / ni espacios.
_nm_usb_valid_name() {
    [[ "${1:-}" =~ ^[a-zA-Z0-9_-]+$ ]]
}

# nm_usb_permanent_mac <iface> -- imprime la MAC permanente.
# Fuente nativa: 'permaddr' de ip link. Fallback: /sys/class/net/<iface>/address.
nm_usb_permanent_mac() {
    local iface="$1"
    local perm
    perm="$(ip link show "${iface}" 2>/dev/null \
        | grep -oE 'permaddr ([0-9a-f:]+)' | awk '{print $2}' | head -1)"
    if [[ -z "${perm}" ]]; then
        perm="$(cat "/sys/class/net/${iface}/address" 2>/dev/null || true)"
    fi
    printf '%s\n' "${perm,,}"
}

# nm_usb_is_usb <iface> -- 0 si la iface esta en un bus USB.
nm_usb_is_usb() {
    local iface="$1"
    local path
    path="$(readlink -f "/sys/class/net/${iface}" 2>/dev/null || true)"
    [[ "${path}" == *"/usb"* ]]
}

# nm_usb_names_apply <config_file>
# Aplica los mapeos del archivo. Escribe los .link idempotentemente.
# Imprime un resumen por mapping.
nm_usb_names_apply() {
    local cfg="$1"
    [[ -f "${cfg}" ]] || { warn "usb-names.conf no existe: ${cfg}"; return 0; }

    mkdir -p "${NM_USB_LINK_DIR}"

    local line mac name link desired applied=0 skipped=0
    while IFS= read -r line; do
        # Strip comment, trim, y colapsar espacios internos a uno.
        line="${line%%#*}"
        line="$(printf '%s' "${line}" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')"
        [[ -n "${line}" ]] || continue

        # Split en exactamente dos campos. IFS explicito a espacio porque
        # el script llama con IFS=$'\n\t' global, que no dividiria.
        local _rest
        IFS=' ' read -r mac name _rest <<< "${line}"
        if [[ -z "${mac}" || -z "${name}" || -n "${_rest}" ]]; then
            warn "usb-names.conf: linea ignorada (formato esperado '<mac> <name>'): ${line}"
            continue
        fi

        mac="${mac,,}"
        if ! _nm_usb_valid_mac "${mac}"; then
            warn "usb-names.conf: MAC invalida, ignorada: ${mac}"
            continue
        fi
        if ! _nm_usb_valid_name "${name}"; then
            warn "usb-names.conf: nombre invalido, ignorado: ${name}"
            continue
        fi

        link="${NM_USB_LINK_DIR}/${NM_USB_LINK_PREFIX}${name}.link"
        desired="$(printf '%s\n' \
            "# wifi-setup -- USB WiFi rename (aplicado por systemd-udevd en boot)" \
            "# Generado automaticamente -- no editar; cambia config/usb-names.conf" \
            "[Match]" \
            "PermanentMACAddress=${mac}" \
            "" \
            "[Link]" \
            "Name=${name}")"

        if [[ -f "${link}" ]] && [[ "$(cat "${link}")" == "${desired}" ]]; then
            info "usb-name: ${mac} -> ${name} (sin cambios)"
            skipped=$((skipped + 1))
            continue
        fi

        printf '%s\n' "${desired}" > "${link}"
        chmod 644 "${link}"
        ok "usb-name: ${mac} -> ${name} (aplicara en proximo boot)"
        applied=$((applied + 1))
    done < "${cfg}"

    if [[ "${applied}" -gt 0 ]]; then
        systemctl daemon-reload 2>/dev/null || true
        udevadm control --reload 2>/dev/null || true
        info "usb-names: ${applied} link(s) escrito(s), ${skipped} sin cambios"
        info "los renombrados se aplican al proximo reinicio"
    else
        info "usb-names: todos los mappings ya estaban aplicados"
    fi
}

# nm_usb_names_status -- imprime mapping actual + si el .link esta.
nm_usb_names_status() {
    local cfg="$1"
    [[ -f "${cfg}" ]] || { echo "  (no hay config/usb-names.conf)"; return 0; }
    local line mac name link
    while IFS= read -r line; do
        line="${line%%#*}"
        line="$(printf '%s' "${line}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        [[ -n "${line}" ]] || continue
        local _rest
        IFS=' ' read -r mac name _rest <<< "${line}"
        [[ -n "${mac}" && -n "${name}" && -z "${_rest}" ]] || continue
        link="${NM_USB_LINK_DIR}/${NM_USB_LINK_PREFIX}${name}.link"
        if [[ -f "${link}" ]]; then
            echo "  ${mac} -> ${name} [${link} OK]"
        else
            echo "  ${mac} -> ${name} [sin .link]"
        fi
    done < "${cfg}"
}
