#!/usr/bin/env bats
# usb_names.bats -- comportamiento real de las funciones de renombrado USB.
# Invocan las funciones con input controlado y verifican el resultado, no
# el texto del codigo fuente.

load helpers

setup() {
    setup_env
    export NM_USB_LINK_DIR="$BATS_TEST_TMPDIR/network"
    mkdir -p "$NM_USB_LINK_DIR"

    ok()   { printf '  [OK] %s\n' "$*" >&2; }
    warn() { printf '  [WARN] %s\n' "$*" >&2; }
    info() { printf '  [i] %s\n' "$*" >&2; }
    die()  { printf '  [ERR] %s\n' "$*" >&2; return 1; }
    section() { :; }
    export -f ok warn info die section 2>/dev/null || true

    # shellcheck source=/dev/null
    source "$REPO/lib/nm.sh"
}

@test "_nm_usb_valid_mac: acepta MACs validas" {
    _nm_usb_valid_mac "90:de:80:e7:fd:9f"
    _nm_usb_valid_mac "AA:BB:CC:DD:EE:FF"
    _nm_usb_valid_mac "00:00:00:00:00:00"
}

@test "_nm_usb_valid_mac: rechaza MACs invalidas" {
    ! _nm_usb_valid_mac ""
    ! _nm_usb_valid_mac "not-a-mac"
    ! _nm_usb_valid_mac "90:de:80:e7:fd"
    ! _nm_usb_valid_mac "90:de:80:e7:fd:9f:00"
    ! _nm_usb_valid_mac "90-de-80-e7-fd-9f"
    ! _nm_usb_valid_mac "zz:de:80:e7:fd:9f"
}

@test "_nm_usb_valid_name: acepta nombres validos" {
    _nm_usb_valid_name "wlx1"
    _nm_usb_valid_name "wlx0"
    _nm_usb_valid_name "wlan-2"
    _nm_usb_valid_name "usb_wifi_1"
}

@test "_nm_usb_valid_name: rechaza nombres invalidos" {
    ! _nm_usb_valid_name ""
    ! _nm_usb_valid_name "wlx 1"
    ! _nm_usb_valid_name "wlx/1"
    ! _nm_usb_valid_name "../etc"
}

@test "nm_usb_names_apply: escribe .link con PermanentMACAddress y Name" {
    local cfg="$BATS_TEST_TMPDIR/usb-names.conf"
    printf '90:de:80:e7:fd:9f wlx1\n' > "$cfg"

    run nm_usb_names_apply "$cfg"
    [ "$status" -eq 0 ]

    local link="$NM_USB_LINK_DIR/10-wifi-setup-wlx1.link"
    [ -f "$link" ]
    grep -q "^PermanentMACAddress=90:de:80:e7:fd:9f$" "$link"
    grep -q "^Name=wlx1$" "$link"
    grep -q "^\[Match\]$" "$link"
    grep -q "^\[Link\]$" "$link"
}

@test "nm_usb_names_apply: idempotente (segunda corrida no reescribe)" {
    local cfg="$BATS_TEST_TMPDIR/usb-names.conf"
    printf '90:de:80:e7:fd:9f wlx1\n' > "$cfg"

    nm_usb_names_apply "$cfg" >/dev/null 2>&1
    local link="$NM_USB_LINK_DIR/10-wifi-setup-wlx1.link"
    local mtime1; mtime1="$(stat -c %Y "$link")"

    sleep 1
    run nm_usb_names_apply "$cfg"
    [ "$status" -eq 0 ]
    [[ "$output" == *"sin cambios"* ]]

    local mtime2; mtime2="$(stat -c %Y "$link")"
    [ "$mtime1" = "$mtime2" ]
}

@test "nm_usb_names_apply: multiples mappings generan multiples .link" {
    local cfg="$BATS_TEST_TMPDIR/usb-names.conf"
    cat > "$cfg" <<EOF
90:de:80:e7:fd:9f wlx1
aa:bb:cc:dd:ee:ff wlx2
EOF
    run nm_usb_names_apply "$cfg"
    [ "$status" -eq 0 ]
    [ -f "$NM_USB_LINK_DIR/10-wifi-setup-wlx1.link" ]
    [ -f "$NM_USB_LINK_DIR/10-wifi-setup-wlx2.link" ]
}

@test "nm_usb_names_apply: ignora lineas invalidas sin abortar" {
    local cfg="$BATS_TEST_TMPDIR/usb-names.conf"
    cat > "$cfg" <<EOF
# comentario
90:de:80:e7:fd:9f wlx1
esto no es valido
linea con demasiados campos aqui
aa:bb:cc:dd:ee:ff wlx2
EOF
    run nm_usb_names_apply "$cfg"
    [ "$status" -eq 0 ]
    [ -f "$NM_USB_LINK_DIR/10-wifi-setup-wlx1.link" ]
    [ -f "$NM_USB_LINK_DIR/10-wifi-setup-wlx2.link" ]
    [[ "$output" == *"ignorada"* ]]
}

@test "nm_usb_names_status: reporta mappings con estado del .link" {
    local cfg="$BATS_TEST_TMPDIR/usb-names.conf"
    printf '90:de:80:e7:fd:9f wlx1\n' > "$cfg"

    run nm_usb_names_status "$cfg"
    [ "$status" -eq 0 ]
    [[ "$output" == *"90:de:80:e7:fd:9f"* ]]
    [[ "$output" == *"wlx1"* ]]
    [[ "$output" == *"sin .link"* ]]

    nm_usb_names_apply "$cfg" >/dev/null 2>&1
    run nm_usb_names_status "$cfg"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "config/usb-names.conf del repo: formato valido (<mac> <nombre>)" {
    local line mac name
    while IFS= read -r line; do
        line="${line%%#*}"
        line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        [ -n "$line" ] || continue
        # shellcheck disable=SC2086
        set -- $line
        [ "$#" -eq 2 ] || { echo "linea mal formada: $line" >&3; return 1; }
        mac="$1"; name="$2"
        [[ "$mac" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]] || { echo "MAC invalida: $mac" >&3; return 1; }
        [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo "nombre invalido: $name" >&3; return 1; }
    done < "$USB_CONF"
}

@test "config/usb-names.conf del repo: define 90:de:80:e7:fd:9f -> wlx1" {
    run grep -E '^\s*90:de:80:e7:fd:9f\s+wlx1\s*$' "$USB_CONF"
    [ "$status" -eq 0 ]
}
