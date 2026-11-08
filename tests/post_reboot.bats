#!/usr/bin/env bats
# post_reboot.bats -- invariantes post-reboot. Tarea 226171.
# Bats no puede reiniciar la maquina; el test valida el estado actual
# (que es lo que un reboot debe respetar). Se skipea donde el repo no
# aplica (no Debian) o sin el hardware relevante.
#
# Invariantes:
#   - wireless iface con IP tras arranque
#   - default route via esa iface
#   - gateway alcanzable (0-5% loss)
#   - DNS resuelve
#   - sin wpa_supplicant huerfano cuando iwd es el gestor (bug original)
#   - driver wl para Broadcom BCM4313/BCM4727 (bug driver original)

load helpers

_require_debian() {
    if ! grep -q '^ID=debian' /etc/os-release 2>/dev/null; then
        skip "no Debian (repo es Debian-only)"
    fi
}

_wireless_iface() {
    ip -br link 2>/dev/null | awk '$1 ~ /^(wlan|wlp|wlx)/ {print $1; exit}'
}

_gateway() {
    ip route show default 2>/dev/null | awk '/default/ {print $3; exit}'
}

@test "post_reboot: wireless iface con IP tras arranque" {
    _require_debian
    local iface
    iface="$(_wireless_iface)"
    [ -n "$iface" ] || skip "sin wireless iface"
    # ip -br no imprime la etiqueta "inet"; ip -4 addr (sin -br) si.
    run ip -4 addr show "$iface"
    [ "$status" -eq 0 ]
    echo "$output" | grep -qE 'inet (192\.|10\.|172\.)'
}

@test "post_reboot: default route via wireless iface" {
    _require_debian
    local iface
    iface="$(_wireless_iface)"
    [ -n "$iface" ] || skip "sin wireless iface"
    run ip route show default
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "dev $iface"
}

@test "post_reboot: gateway alcanzable (0-5% loss)" {
    _require_debian
    local gw iface
    iface="$(_wireless_iface)"
    gw="$(_gateway)"
    [ -n "$iface" ] || skip "sin wireless iface"
    [ -n "$gw" ]    || skip "sin gateway"
    run ping -c10 -i0.2 -W2 -I "$iface" "$gw"
    [ "$status" -eq 0 ]
    local loss
    loss="$(echo "$output" | grep -oE '[0-9]+(\.[0-9]+)?% packet loss' | grep -oE '^[0-9]+' | head -1)"
    [ "${loss:-100}" -le 5 ] || { echo "loss=${loss}% > 5%" >&3; return 1; }
}

@test "post_reboot: DNS resuelve" {
    _require_debian
    command -v getent >/dev/null 2>&1 || skip "getent no disponible"
    run getent hosts debian.org
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "post_reboot: sin wpa_supplicant huerfano cuando iwd es el gestor" {
    _require_debian
    systemctl is-active iwd >/dev/null 2>&1 || skip "iwd no activo"
    systemctl is-active NetworkManager >/dev/null 2>&1 && skip "NM es el gestor (wpa_supplicant puede ser legitimo)"
    run pgrep -x wpa_supplicant
    [ "$status" -ne 0 ] || { echo "wpa_supplicant corriendo con iwd como gestor" >&3; return 1; }
}

@test "post_reboot: driver correcto para Broadcom BCM4313/BCM4727" {
    _require_debian
    command -v lspci >/dev/null 2>&1 || skip "lspci no disponible"
    local chip_line
    chip_line="$(lspci 2>/dev/null | grep -iE 'BCM4313|BCM4727|14e4:4313|14e4:4727' || true)"
    [ -n "$chip_line" ] || skip "sin chip Broadcom BCM4313/BCM4727"
    local driver
    driver="$(lspci -k 2>/dev/null \
              | grep -A3 -iE 'BCM4313|BCM4727|14e4:4313|14e4:4727' \
              | grep 'Kernel driver in use' \
              | awk -F': ' '{print $2; exit}')"
    [ "$driver" = "wl" ] || { echo "driver='${driver}', se espera 'wl'" >&3; return 1; }
}
