#!/usr/bin/env bats
# profiles.bats -- operaciones sobre perfiles WiFi.
# Mockea nm.sh, systemctl y networks_apply para verificar la logica
# de profiles.sh sin tocar red real.

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
    export IWD_DIR="$BATS_TEST_TMPDIR/iwd"
    mkdir -p "$STATE_DIR" "$IWD_DIR"

    NM_ACTIVE=0
    export NM_ACTIVE
    systemctl() {
        if [ "$1" = "is-active" ] && [ "$2" = "NetworkManager" ]; then
            [ "${NM_ACTIVE:-0}" = "1" ] && return 0 || return 1
        fi
        return 1
    }
    export -f systemctl 2>/dev/null || true

    export PROFILES="$BATS_TEST_TMPDIR/profiles.txt"
    export PROFILES_DIR="$BATS_TEST_TMPDIR/profiles_dir"
    : > "$PROFILES"
    mkdir -p "$PROFILES_DIR"

    nmcli() {
        if [ "$1" = "-t" ] && [ "$2" = "-g" ] && [ "$3" = "802-11-wireless.ssid" ] && [ "$4" = "con" ] && [ "$5" = "show" ]; then
            cat "${PROFILES_DIR}/${6}.802-11-wireless.ssid" 2>/dev/null
            return 0
        fi
        if [ "$1" = "-t" ] && [ "$2" = "-f" ] && [ "$3" = "NAME,TYPE" ] && [ "$4" = "con" ] && [ "$5" = "show" ]; then
            local p
            while IFS= read -r p; do
                [ -n "$p" ] && printf '%s:802-11-wireless\n' "$p"
            done < "$PROFILES"
            return 0
        fi
        return 1
    }
    export -f nmcli 2>/dev/null || true

    nm_con_exists() {
        [ -n "$1" ] && grep -qxF "$1" "$PROFILES"
    }
    nm_con_get() {
        local p="$1" f="$2"
        if [ -f "${PROFILES_DIR}/${p}.${f}" ]; then
            cat "${PROFILES_DIR}/${p}.${f}"
        fi
    }
    nm_con_set_priority() {
        mkdir -p "$PROFILES_DIR"
        printf '%s\n' "$2" > "${PROFILES_DIR}/${1}.priority"
        return 0
    }
    nm_con_set_autoconnect() {
        mkdir -p "$PROFILES_DIR"
        printf '%s\n' "$2" > "${PROFILES_DIR}/${1}.autoconnect"
        return 0
    }
    nm_con_delete() {
        local p="$1"
        grep -vxF "$p" "$PROFILES" > "${PROFILES}.new" || true
        mv "${PROFILES}.new" "$PROFILES"
        rm -f "${PROFILES_DIR}/${p}".*
        return 0
    }
    nm_con_up() { return 0; }
    networks_apply() { :; }
    radio_ifaces() { printf 'wlan0\n'; }
    _radio_load_state() { RADIO_PRIMARY="wlan0"; }
    export -f nm_con_exists nm_con_get nm_con_set_priority nm_con_set_autoconnect \
             nm_con_delete nm_con_up networks_apply radio_ifaces _radio_load_state 2>/dev/null || true

    # shellcheck source=/dev/null
    source "$REPO/lib/networks_store.sh"
    # shellcheck source=/dev/null
    source "$REPO/lib/profiles.sh"
}

@test "profile_resolve: nombre de perfil existente se devuelve tal cual" {
    printf 'wifi-wlan0-RedA\n' > "$PROFILES"
    run profile_resolve "wifi-wlan0-RedA"
    [ "$status" -eq 0 ]
    [ "$output" = "wifi-wlan0-RedA" ]
}

@test "profile_resolve: SSID matchea contra el campo 802-11-wireless.ssid" {
    printf 'wifi-wlan0-RedA\n' > "$PROFILES"
    printf 'RedA\n' > "${PROFILES_DIR}/wifi-wlan0-RedA.802-11-wireless.ssid"

    run profile_resolve "RedA"
    [ "$status" -eq 0 ]
    [ "$output" = "wifi-wlan0-RedA" ]
}

@test "profile_priority_set: actualiza NM y DB (iface='*')" {
    printf 'wifi-wlan0-RedA\n' > "$PROFILES"
    printf 'RedA\n' > "${PROFILES_DIR}/wifi-wlan0-RedA.802-11-wireless.ssid"

    _networks_store_upsert "RedA" "psk" "wlan0" "yes" "0"
    _networks_store_upsert "RedA" "psk" "wlx1" "no" "0"

    run profile_priority_set "wifi-wlan0-RedA" "99"
    [ "$status" -eq 0 ]

    run cat "${PROFILES_DIR}/wifi-wlan0-RedA.priority"
    [ "$output" = "99" ]

    run grep -c $'\t99\t' "${NETWORKS_STORE}"
    [ "$output" = "2" ]
}

@test "profile_priority_set: rechaza prioridad no numerica" {
    printf 'wifi-wlan0-RedA\n' > "$PROFILES"
    run profile_priority_set "wifi-wlan0-RedA" "abc"
    [ "$status" -ne 0 ]
    [ ! -f "${PROFILES_DIR}/wifi-wlan0-RedA.priority" ]
}

@test "profile_autoconnect_set: normaliza on->yes, off->no en NM y DB" {
    printf 'wifi-wlan0-RedA\n' > "$PROFILES"
    printf 'RedA\n' > "${PROFILES_DIR}/wifi-wlan0-RedA.802-11-wireless.ssid"
    printf 'wlan0\n' > "${PROFILES_DIR}/wifi-wlan0-RedA.connection.interface-name"

    _networks_store_upsert "RedA" "psk" "wlan0" "yes" "0"

    run profile_autoconnect_set "wifi-wlan0-RedA" "off"
    [ "$status" -eq 0 ]

    run cat "${PROFILES_DIR}/wifi-wlan0-RedA.autoconnect"
    [ "$output" = "no" ]

    run grep '^RedA.*wlan0.*no' "${NETWORKS_STORE}"
    [ "$status" -eq 0 ]
}

@test "profile_autoconnect_set: rechaza modo invalido" {
    printf 'wifi-wlan0-RedA\n' > "$PROFILES"
    run profile_autoconnect_set "wifi-wlan0-RedA" "maybe"
    [ "$status" -ne 0 ]
    [ ! -f "${PROFILES_DIR}/wifi-wlan0-RedA.autoconnect" ]
}

@test "profile_delete: borra perfil NM y filas del SSID en DB" {
    printf 'wifi-wlan0-RedA\n' > "$PROFILES"
    printf 'RedA\n' > "${PROFILES_DIR}/wifi-wlan0-RedA.802-11-wireless.ssid"

    _networks_store_upsert "RedA" "psk" "wlan0" "yes" "0"
    _networks_store_upsert "RedA" "psk" "wlx1" "no" "0"

    run profile_delete "wifi-wlan0-RedA"
    [ "$status" -eq 0 ]

    run nm_con_exists "wifi-wlan0-RedA"
    [ "$status" -ne 0 ]

    run grep -c '^RedA' "${NETWORKS_STORE}"
    [ "$output" = "0" ]
}

@test "profile_resolve: perfil con comillas literales se encuentra por SSID limpio" {
    # Perfil creado con el bug pre-878ded0: nombre incluye comillas.
    printf 'wifi-wlan0-"Familia_Mora"\n' > "$PROFILES"
    printf '"Familia_Mora"\n' > "${PROFILES_DIR}/wifi-wlan0-\"Familia_Mora\".802-11-wireless.ssid"

    run profile_resolve "Familia_Mora"
    [ "$status" -eq 0 ]
    [ "$output" = 'wifi-wlan0-"Familia_Mora"' ]
}

@test "profile_resolve: SSID legitimo con comillas matchea si arg tambien las trae" {
    # Caso raro: AP con comillas reales, arg con comillas. Comportamiento previo
    # al fix (crudo contra crudo) sigue funcionando.
    printf 'wifi-wlan0-"Real"\n' > "$PROFILES"
    printf '"Real"\n' > "${PROFILES_DIR}/wifi-wlan0-\"Real\".802-11-wireless.ssid"

    run profile_resolve '"Real"'
    [ "$status" -eq 0 ]
    [ "$output" = 'wifi-wlan0-"Real"' ]
}

@test "profile_resolve: SSID diferente no matchea aunque strip coincida parcialmente" {
    printf 'wifi-wlan0-Otra\n' > "$PROFILES"
    printf 'Otra\n' > "${PROFILES_DIR}/wifi-wlan0-Otra.802-11-wireless.ssid"

    run profile_resolve "Familia_Mora"
    [ "$status" -ne 0 ]
}

@test "profile_rename: rechaza si el nuevo nombre ya existe" {
    printf 'wifi-wlan0-RedA\nwifi-wlan0-RedB\n' > "$PROFILES"
    run profile_rename "wifi-wlan0-RedA" "wifi-wlan0-RedB"
    [ "$status" -ne 0 ]
}
