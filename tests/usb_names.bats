#!/usr/bin/env bats
# usb_names.bats -- comportamiento observable del renombrado USB.

load helpers

setup() {
    setup_env
    export NM_USB_LINK_DIR="$BATS_TEST_TMPDIR/network"
    mkdir -p "$NM_USB_LINK_DIR"
    # shellcheck source=/dev/null
    source "$REPO/lib/nm.sh"
}

@test "_nm_usb_valid_mac: acepta validas, rechaza invalidas" {
    _nm_usb_valid_mac "90:de:80:e7:fd:9f"
    _nm_usb_valid_mac "AA:BB:CC:DD:EE:FF"
    ! _nm_usb_valid_mac ""
    ! _nm_usb_valid_mac "not-a-mac"
    ! _nm_usb_valid_mac "90:de:80:e7:fd"
    ! _nm_usb_valid_mac "90:de:80:e7:fd:9f:00"
    ! _nm_usb_valid_mac "90-de-80-e7-fd-9f"
    ! _nm_usb_valid_mac "zz:de:80:e7:fd:9f"
}

@test "_nm_usb_valid_name: acepta validos, rechaza invalidos" {
    _nm_usb_valid_name "wlx1"
    _nm_usb_valid_name "wlan-2"
    _nm_usb_valid_name "usb_wifi_1"
    ! _nm_usb_valid_name ""
    ! _nm_usb_valid_name "wlx 1"
    ! _nm_usb_valid_name "wlx/1"
    ! _nm_usb_valid_name "../etc"
}

@test "config/usb-names.conf del repo: formato <mac> <nombre> valido" {
    local line mac name count=0
    while IFS= read -r line; do
        line="${line%%#*}"
        line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        [ -n "$line" ] || continue
        # shellcheck disable=SC2086
        set -- $line
        [ "$#" -eq 2 ] || { echo "linea mal formada: $line" >&3; return 1; }
        mac="$1"; name="$2"
        [[ "$mac"  =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]] || { echo "MAC invalida: $mac" >&3; return 1; }
        [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo "nombre invalido: $name" >&3; return 1; }
        count=$((count + 1))
    done < "$USB_CONF"
    [ "$count" -gt 0 ] || { echo "config vacia: se espera al menos una linea <mac> <nombre>" >&3; return 1; }
}
