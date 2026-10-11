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
    systemctl is-active NetworkManager >/dev/null 2>&1 \
        || die "NetworkManager no activo -- corre: sudo systemctl start NetworkManager"
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

# nm_con_up <name> -- activa un perfil.
nm_con_up() {
    local name="$1"
    nmcli con up "${name}" >/dev/null
}

# nm_con_down <name> -- desactiva un perfil.
nm_con_down() {
    local name="$1"
    nmcli con down "${name}" >/dev/null
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
