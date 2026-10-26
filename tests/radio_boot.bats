#!/usr/bin/env bats
# boot_select.bats -- invariantes de radio_boot (sin sleep, sin polling).
#
# La funcion real vive en lib/radio.sh. Estos tests previenen regresiones
# historicas: la version vieja hacia polling con sleep 3 en un loop de 60s
# y elegia el SSID con sort|head|cut (capturaba stderr, mataba el stream
# bajo set -e). El rediseño delega la espera a systemd
# (NetworkManager-wait-online) y usa una sola pasada de awk.

load helpers

setup() { setup_env; }

@test "radio_boot: sin sleep ni contadores de espera" {
    run grep -A80 '^radio_boot()' "$REPO/lib/radio.sh"
    [ "$status" -eq 0 ]
    [[ "$output" != *"sleep "* ]]
    [[ "$output" != *"waited="* ]]
}


@test "install.sh: la unit boot-select declara NetworkManager-wait-online" {
    run grep -A5 'wifi-setup-radio-boot.service' "$INSTALL"
    [ "$status" -eq 0 ]
    [[ "$output" == *"NetworkManager-wait-online"* ]]
}
