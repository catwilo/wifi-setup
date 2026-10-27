#!/usr/bin/env bats
# regression.bats -- invariantes de los fixes del bug reportado.
#
# Cubre el comportamiento observable de cada fix sin depender de NM vivo:
#   - nm_device_connect usa "nmcli device connect" (nunca "nmcli con up")
#   - nm_con_up lleva --wait 90 (tope, no bloqueo indefinido)
#   - _cmd_connect, radio_up y radio_boot usan nm_device_connect
#   - fallback_off devuelve non-zero sin IP y preserva fallback_state
#   - DNS: systemd-resolved habilitado + symlink stub-resolv.conf + iwd
#     delega con NameResolvingService=systemd

load helpers

setup() { setup_env; }

@test "nm_device_connect: usa nmcli device connect, no con up" {
    run grep -A5 '^nm_device_connect()' "$REPO/lib/nm.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *'nmcli device connect'* ]]
    [[ "$output" != *'nmcli con up'* ]]
}

@test "nm_con_up: lleva --wait 90 (tope, no bloqueo indefinido)" {
    run grep -A5 '^nm_con_up()' "$REPO/lib/nm.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *'--wait 90'* ]]
}

@test "_cmd_connect: usa nm_device_connect, no nm_con_up" {
    run grep -A40 '^_cmd_connect()' "$REPO/bin/wifi"
    [ "$status" -eq 0 ]
    [[ "$output" == *'nm_device_connect'* ]]
    [[ "$output" != *'nm_con_up'* ]]
}

@test "radio_up: usa nm_device_connect, no nm_con_up" {
    run grep -A40 '^radio_up()' "$REPO/lib/radio.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *'nm_device_connect'* ]]
    [[ "$output" != *'nm_con_up'* ]]
}

@test "radio_boot: usa nm_device_connect, no nm_con_up" {
    run grep -A80 '^radio_boot()' "$REPO/lib/radio.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *'nm_device_connect'* ]]
    [[ "$output" != *'nm_con_up'* ]]
}

@test "fallback_off: non-zero sin IP y preserva fallback_state" {
    run grep -A120 '^fallback_off()' "$REPO/lib/fallback.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *'ninguna antena obtuvo IP'* ]]
    [[ "$output" == *'fallback_state preservado'* ]]
    [[ "$output" == *'return 1'* ]]
}

@test "DNS: _deps_ensure_resolved habilita systemd-resolved y symlinkea stub-resolv.conf" {
    run grep -A25 '^_deps_ensure_resolved()' "$REPO/lib/deps.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *'systemd-resolved'* ]]
    [[ "$output" == *'stub-resolv.conf'* ]]
    [[ "$output" == *'ln -sfn'* ]]
}

@test "DNS: fallback.sh delega a systemd (NameResolvingService=systemd, no none)" {
    run grep 'NameResolvingService' "$REPO/lib/fallback.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *'systemd'* ]]
    [[ "$output" != *'NameResolvingService=none'* ]]
}
