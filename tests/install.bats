#!/usr/bin/env bats
# install.bats -- invariantes del contrato de install.sh nuevo.
#
# El install nuevo SOLO instala la herramienta. No toca la red:
#   - no invoca systemctl sobre NM, iwd o wpa_supplicant
#   - no migra el gestor activo
#   - no pide SSID/PSK
# Todo eso vive en subcomandos (wifi fallback, wifi add) y se ejecuta
# cuando el usuario lo pide.

load helpers

setup() { setup_env; }

@test "install.sh: requiere root" {
    run grep -q 'install.sh requiere root' "$REPO/install.sh"
    [ "$status" -eq 0 ]
}

@test "install.sh: NO invoca systemctl sobre servicios de red" {
    # Solo se permite 'systemctl enable/start' del unit propio
    # wifi-boot-fallback y 'daemon-reload'. Nada de tocar NM, iwd,
    # wpa_supplicant, dhcpcd.
    run grep -nE 'systemctl[[:space:]]+(start|stop|restart|enable|disable)[[:space:]]+(NetworkManager|iwd|wpa_supplicant|dhcpcd)' "$REPO/install.sh"
    [ "$status" -ne 0 ]
}

@test "install.sh: crea symlink /usr/local/bin/wifi antes de escribir units" {
    # El symlink debe existir aunque el resto del install falle, para
    # que 'wifi' quede disponible para diagnosticar.
    local ln_line unit_line
    ln_line=$(grep -n 'ln -sfn.*/usr/local/bin/wifi' "$REPO/install.sh" | head -1 | cut -d: -f1)
    unit_line=$(grep -n 'wifi-boot-fallback.service' "$REPO/install.sh" | head -1 | cut -d: -f1)
    [ -n "$ln_line" ]
    [ -n "$unit_line" ]
    [ "$ln_line" -lt "$unit_line" ]
}
