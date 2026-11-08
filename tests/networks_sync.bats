#!/usr/bin/env bats
# networks_sync.bats -- networks_sync con filas de psk vacio.
# Cubre el bug de IFS=$'\t' read colapsando tabs consecutivos: una fila
# con psk vacio corre los campos y networks_sync terminaba creando el
# perfil con ifname=<autoconnect> y ssid=<iface> (siempre falla).

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

    NMCLI_LOG="$BATS_TEST_TMPDIR/nmcli.log"
    : > "$NMCLI_LOG"
    export NMCLI_LOG

    # Mocks minimos: nmcli loguea, nm_con_* no-op, nm_wifi_create loguea.
    nmcli() {
        printf 'nmcli %s\n' "$*" >> "$NMCLI_LOG"
        return 0
    }
    nm_con_exists() { return 1; }
    nm_con_set_autoconnect() { return 0; }
    nm_con_set_priority()    { return 0; }
    nm_wifi_create() {
        printf 'create profile=%s iface=%s ssid=%s psk=%s\n' "$1" "$2" "$3" "$4" >> "$NMCLI_LOG"
    }
    export -f nmcli nm_con_exists nm_con_set_autoconnect nm_con_set_priority nm_wifi_create 2>/dev/null || true

    # shellcheck source=/dev/null
    source "$REPO/lib/networks_store.sh"
    # shellcheck source=/dev/null
    source "$REPO/lib/networks_apply.sh"
}

@test "networks_sync: fila con psk vacio crea perfil abierto con ifname correcta" {
    _networks_store_init
    {
        printf '# header\n'
        printf 'RedAbierta\t\twlan0\tyes\t0\t0\n'
    } > "${NETWORKS_STORE}"

    networks_sync || true

    # La rama "sin psk" usa `nmcli con add ... ifname <iface> ssid <ssid>`
    run grep -c 'con add.*ifname wlan0.*ssid RedAbierta' "$NMCLI_LOG"
    [ "$output" -ge 1 ]

    # No debe haber llamado nm_wifi_create (esa rama es para psk no vacio)
    run grep -c '^create ' "$NMCLI_LOG"
    [ "$output" = "0" ]

    # La iface NO debe ser "yes" (artefacto del bug de IFS)
    run grep -c 'ifname yes' "$NMCLI_LOG"
    [ "$output" = "0" ]
}

@test "networks_sync: fila con psk no vacio usa nm_wifi_create con psk correcto" {
    _networks_store_init
    {
        printf '# header\n'
        printf 'RedConPsk\tsupersecreto\twlan0\tyes\t0\t0\n'
    } > "${NETWORKS_STORE}"

    networks_sync || true

    run grep -c '^create profile=wifi-wlan0-RedConPsk iface=wlan0 ssid=RedConPsk psk=supersecreto$' "$NMCLI_LOG"
    [ "$output" -ge 1 ]
}
