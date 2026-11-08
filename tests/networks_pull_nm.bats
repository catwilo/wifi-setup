#!/usr/bin/env bats
# networks_pull_nm.bats -- networks_pull_nm funde perfiles NM al store.
# Regresion: el fix _networks_row preserva psk vacio en el store viejo,
# manteniendo las claves (ssid,iface) correctas en old_auto/old_prio.
# Sin el fix, el parser viejo corre los campos y las claves quedan en
# (ssid, autoconnect) en vez de (ssid, iface).

load helpers

setup() {
    setup_env
    die()  { printf '[ERR] %s\n' "$*" >&2; exit 1; }
    info() { :; }
    ok()   { :; }
    warn() { :; }
    err()  { :; }
    export -f die info ok warn err 2>/dev/null || true

    export STATE_DIR="$BATS_TEST_TMPDIR/state"
    mkdir -p "$STATE_DIR"

    NM_PROFILES=""
    NM_TYPES=""
    NM_SSIDS=""
    NM_PSKS=""
    NM_IFACES=""
    NM_AUTOS=""
    NM_PRIOS=""
    RADIO_IFACES=""

    # Formato fixtures: "profile1=val1;profile2=val2"
    _lookup() {
        local data="$1" name="$2" line k v
        local IFS=';'
        for line in $data; do
            k="${line%%=*}"; v="${line#*=}"
            if [ "$k" = "$name" ]; then printf '%s' "$v"; return 0; fi
        done
        return 1
    }

    nm_con_get() {
        local name="$1" field="$2" data
        case "$field" in
            connection.type)                 data="$NM_TYPES" ;;
            connection.interface-name)       data="$NM_IFACES" ;;
            connection.autoconnect)          data="$NM_AUTOS" ;;
            connection.autoconnect-priority) data="$NM_PRIOS" ;;
            *) return 1 ;;
        esac
        _lookup "$data" "$name"
    }

    nmcli() {
        if [ "$1" = "-t" ] && [ "$2" = "-f" ] && [ "$3" = "NAME" ] && [ "$4" = "con" ] && [ "$5" = "show" ]; then
            local IFS=' '
            for p in $NM_PROFILES; do printf '%s\n' "$p"; done
            return 0
        fi
        if [ "$1" = "-t" ] && [ "$2" = "-g" ] && [ "$3" = "802-11-wireless.ssid" ] && [ "$4" = "con" ] && [ "$5" = "show" ]; then
            _lookup "$NM_SSIDS" "$6"
            return
        fi
        if [ "$1" = "-s" ] && [ "$2" = "-t" ] && [ "$3" = "-g" ] && [ "$4" = "802-11-wireless-security.psk" ] && [ "$5" = "con" ] && [ "$6" = "show" ]; then
            _lookup "$NM_PSKS" "$7"
            return
        fi
        if [ "$1" = "-t" ] && [ "$2" = "-f" ] && [ "$3" = "DEVICE,CONNECTION" ] && [ "$4" = "dev" ] && [ "$5" = "status" ]; then
            return 0
        fi
        return 1
    }

    radio_ifaces() {
        local IFS=' '
        for i in $RADIO_IFACES; do printf '%s\n' "$i"; done
    }

    export -f _lookup nm_con_get nmcli radio_ifaces 2>/dev/null || true
    export NM_PROFILES NM_TYPES NM_SSIDS NM_PSKS NM_IFACES NM_AUTOS NM_PRIOS RADIO_IFACES

    # shellcheck source=/dev/null
    source "$REPO/lib/networks_store.sh"
    # shellcheck source=/dev/null
    source "$REPO/lib/networks_pull.sh"
}

@test "networks_pull_nm: 1 perfil NM produce filas para todas las ifaces" {
    NM_PROFILES="RedA"
    NM_TYPES="RedA=802-11-wireless"
    NM_SSIDS="RedA=MiSSID"
    NM_PSKS="RedA=pskA"
    NM_IFACES="RedA=wlan0"
    NM_AUTOS="RedA=yes"
    NM_PRIOS="RedA=10"
    RADIO_IFACES="wlan0 wlx1"

    run networks_pull_nm
    [ "$status" -eq 0 ]

    run grep -c '^MiSSID' "${NETWORKS_STORE}"
    [ "$output" = "2" ]

    run grep $'^MiSSID\tpskA\twlan0\tyes\t10\t' "${NETWORKS_STORE}"
    [ "$status" -eq 0 ]

    run grep $'^MiSSID\tpskA\twlx1\tyes\t0\t' "${NETWORKS_STORE}"
    [ "$status" -eq 0 ]
}

@test "networks_pull_nm: perfiles no-wifi se ignoran" {
    NM_PROFILES="Eth0"
    NM_TYPES="Eth0=802-3-ethernet"
    NM_IFACES="Eth0=enp0s0"
    RADIO_IFACES="wlan0"

    _networks_store_init
    run networks_pull_nm
    [ "$status" -eq 0 ]

    run grep -c '^Eth0' "${NETWORKS_STORE}"
    [ "$output" = "0" ]
}

@test "networks_pull_nm: preserva auto/prio con psk vacio en store viejo (regresion)" {
    # Store viejo: SSID_1 en wlx1, auto=no prio=5, psk vacio.
    # NM: SSID_1 en wlan0, psk vacio, auto=yes prio=0.
    # Esperado: wlx1 conserva no/5 (viene de old_auto/old_prio).
    _networks_store_init
    {
        printf '# header\n'
        printf 'SSID_1\t\twlx1\tno\t5\t0\n'
    } > "${NETWORKS_STORE}"

    NM_PROFILES="RedA"
    NM_TYPES="RedA=802-11-wireless"
    NM_SSIDS="RedA=SSID_1"
    NM_PSKS="RedA="
    NM_IFACES="RedA=wlan0"
    NM_AUTOS="RedA=yes"
    NM_PRIOS="RedA=0"
    RADIO_IFACES="wlan0 wlx1"

    run networks_pull_nm
    [ "$status" -eq 0 ]

    run grep $'^SSID_1\t\twlan0\tyes\t0\t' "${NETWORKS_STORE}"
    [ "$status" -eq 0 ]

    run grep $'^SSID_1\t\twlx1\tno\t5\t' "${NETWORKS_STORE}"
    [ "$status" -eq 0 ]
}
