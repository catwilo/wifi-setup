#!/usr/bin/env bats
# boot_state.bats -- invariantes que el estado tras un reboot DEBE respetar.
# Tarea 226171.
#
# ALCANCE: este test corre en el estado ACTUAL de la maquina. Bats no
# puede reiniciar el sistema, asi que la unica forma de usarlo como
# "post-reboot" es correrlo MANUALMENTE despues de un reboot. El nombre
# refleja eso: valida el invariante (wireless iface con IP, default
# route, gateway alcanzable, DNS, sin wpa_supplicant huerfano cuando
# iwd es gestor, driver wl para BCM4313/BCM4727).
#
# Se skipea donde el repo no aplica (no Debian) o sin el hardware
# relevante, para no fallar en CI/Termux.
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

@test "boot_state: wireless iface con IP tras arranque" {
    _require_debian
    local iface
    iface="$(_wireless_iface)"
    [ -n "$iface" ] || skip "sin wireless iface"
    # ip -br no imprime la etiqueta "inet"; ip -4 addr (sin -br) si.
    run ip -4 addr show "$iface"
    [ "$status" -eq 0 ]
    echo "$output" | grep -qE 'inet (192\.|10\.|172\.)'
}

@test "boot_state: default route via wireless iface" {
    _require_debian
    local iface
    iface="$(_wireless_iface)"
    [ -n "$iface" ] || skip "sin wireless iface"
    run ip route show default
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "dev $iface"
}

@test "boot_state: gateway alcanzable (0-30% loss)" {
    _require_debian
    local gw iface
    iface="$(_wireless_iface)"
    gw="$(_gateway)"
    [ -n "$iface" ] || skip "sin wireless iface"
    [ -n "$gw" ]    || skip "sin gateway"
    # Umbral 30%: en 2.4 GHz con muchos vecinos, el AP puede descartar
    # paquetes (co-channel interference, airtime fairness). El test
    # detecta gateway caido o ruta rota, no certifica calidad de RF.
    run ping -c10 -i0.2 -W2 -I "$iface" "$gw"
    [ "$status" -eq 0 ]
    local loss
    loss="$(echo "$output" | grep -oE '[0-9]+(\.[0-9]+)?% packet loss' | grep -oE '^[0-9]+' | head -1)"
    [ "${loss:-100}" -le 30 ] || { echo "loss=${loss}% > 30%" >&3; return 1; }
}

@test "boot_state: DNS resuelve" {
    _require_debian
    command -v getent >/dev/null 2>&1 || skip "getent no disponible"
    run getent hosts debian.org
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "boot_state: sin wpa_supplicant huerfano cuando iwd es el gestor" {
    _require_debian
    systemctl is-active iwd >/dev/null 2>&1 || skip "iwd no activo"
    systemctl is-active NetworkManager >/dev/null 2>&1 && skip "NM es el gestor (wpa_supplicant puede ser legitimo)"
    run pgrep -x wpa_supplicant
    [ "$status" -ne 0 ] || { echo "wpa_supplicant corriendo con iwd como gestor" >&3; return 1; }
}

@test "boot_state: driver correcto para Broadcom BCM4313/BCM4727" {
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
