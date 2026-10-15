#!/usr/bin/env bats
# usb_names.bats -- comportamiento observable del renombrado USB.

load helpers

setup() {
    setup_env
    export NM_USB_LINK_DIR="$BATS_TEST_TMPDIR/network"
    mkdir -p "$NM_USB_LINK_DIR"
    ok()      { printf '  [OK] %s\n'   "$*" >&2; }
    warn()    { printf '  [WARN] %s\n' "$*" >&2; }
    info()    { printf '  [i] %s\n'    "$*" >&2; }
    die()     { printf '  [ERR] %s\n'  "$*" >&2; return 1; }
    section() { :; }
    export -f ok warn info die section 2>/dev/null || true
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

@test "nm_usb_names_apply: escribe .link correcto e idempotente" {
    local cfg="$BATS_TEST_TMPDIR/usb-names.conf"
    printf '90:de:80:e7:fd:9f wlx1\n' > "$cfg"

    run nm_usb_names_apply "$cfg"
    [ "$status" -eq 0 ]

    local link="$NM_USB_LINK_DIR/10-wifi-setup-wlx1.link"
    [ -f "$link" ]
    grep -q '^\[Match\]$' "$link"
    grep -q '^PermanentMACAddress=90:de:80:e7:fd:9f$' "$link"
    grep -q '^\[Link\]$' "$link"
    grep -q '^Name=wlx1$' "$link"

    local mtime1; mtime1="$(stat -c %Y "$link")"
    sleep 1
    run nm_usb_names_apply "$cfg"
    [ "$status" -eq 0 ]
    [[ "$output" == *"sin cambios"* ]]
    [ "$mtime1" = "$(stat -c %Y "$link")" ]
}

@test "nm_usb_names_apply: multiples mappings, ignora invalidas sin abortar" {
    local cfg="$BATS_TEST_TMPDIR/usb-names.conf"
    {
        printf '# comentario\n'
        printf '90:de:80:e7:fd:9f wlx1\n'
        printf 'esto no es valido\n'
        printf 'linea con demasiados campos aqui\n'
        printf 'aa:bb:cc:dd:ee:ff wlx2\n'
    } > "$cfg"
    run nm_usb_names_apply "$cfg"
    [ "$status" -eq 0 ]
    [ -f "$NM_USB_LINK_DIR/10-wifi-setup-wlx1.link" ]
    [ -f "$NM_USB_LINK_DIR/10-wifi-setup-wlx2.link" ]
    [[ "$output" == *"ignorada"* ]]
}

@test "nm_usb_names_status: reporta mapping y estado del .link" {
    local cfg="$BATS_TEST_TMPDIR/usb-names.conf"
    printf '90:de:80:e7:fd:9f wlx1\n' > "$cfg"
    run nm_usb_names_status "$cfg"
    [ "$status" -eq 0 ]
    [[ "$output" == *"90:de:80:e7:fd:9f"* ]]
    [[ "$output" == *"sin .link"* ]]
    nm_usb_names_apply "$cfg" >/dev/null 2>&1
    run nm_usb_names_status "$cfg"
    [[ "$output" == *"OK"* ]]
}

@test "nm_usb_names_apply: funciona con IFS=\$'\\\\n\\\\t' (como install.sh)" {
    local cfg="$BATS_TEST_TMPDIR/usb-names.conf"
    printf '90:de:80:e7:fd:9f wlx1\n' > "$cfg"
    (
        IFS=$'\n\t'
        # shellcheck source=/dev/null
        source "$REPO/lib/nm.sh" 2>/dev/null || true
        nm_usb_names_apply "$cfg"
    )
    local link="$NM_USB_LINK_DIR/10-wifi-setup-wlx1.link"
    [ -f "$link" ] || { echo "sin .link con IFS de install.sh" >&3; return 1; }
    grep -q '^Name=wlx1$' "$link"
}

@test "config/usb-names.conf del repo: formato <mac> <nombre> valido" {
    local line mac name
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
    done < "$USB_CONF"
    grep -qE '^\s*90:de:80:e7:fd:9f\s+wlx1\s*$' "$USB_CONF"
}
