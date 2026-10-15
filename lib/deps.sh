#!/usr/bin/env bash
# lib/deps.sh -- instalacion de dependencias apt.
#
# RESPONSABILIDAD UNICA: asegurar los paquetes que wifi-setup necesita.
#
# STACK:
#   - NetworkManager       backbone WiFi + ethernet + DHCP + NAT
#   - iwd                  fallback manual (instalado, NO activo)
#   - iproute2, curl, ping utilidades base
#
# NO instalamos wpa_supplicant ni dhcpcd ni systemd-networkd: NM trae
# su propio backend y gestor DHCP; systemd-networkd no se usa.
#
# Requiere: common.sh + log.sh cargados antes.

_apt_updated=0

# ---------------------------------------------------------------------------
# _apt_update_once -- apt-get update una sola vez por proceso.
# ---------------------------------------------------------------------------
_apt_update_once() {
    if [[ "${_apt_updated}" -eq 0 ]]; then
        info "apt-get update"
        apt-get update -qq \
            || die "apt-get update fallo -- verifica conexion y /etc/apt/sources.list"
        _apt_updated=1
    fi
}

# ---------------------------------------------------------------------------
# install_pkg <cmd> <pkg>
# Instala <pkg> si <cmd> no esta en PATH.
# ---------------------------------------------------------------------------
install_pkg() {
    local cmd="$1" pkg="$2"
    if command -v "${cmd}" >/dev/null 2>&1; then
        info "ok: ${cmd} (${pkg})"
        return 0
    fi
    info "instalando: ${pkg} (para '${cmd}')"
    _apt_update_once
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${pkg}" \
        || die "no se pudo instalar ${pkg}"
}

# ---------------------------------------------------------------------------
# install_deps -- todas las dependencias del stack NM.
# ---------------------------------------------------------------------------
install_deps() {
    info "instalando dependencias (NetworkManager + utilidades)..."

    install_pkg nmcli            network-manager
    install_pkg iwctl            iwd
    install_pkg iw               iw
    install_pkg ip               iproute2
    install_pkg curl             curl
    install_pkg ping             iputils-ping

    # Estado del stack segun el diseno:
    #   NM activo + enabled.
    #   iwd instalado pero parado + disabled -- fallback manual.
    systemctl enable NetworkManager  >/dev/null 2>&1 || true
    systemctl start  NetworkManager  >/dev/null 2>&1 || true
    systemctl disable iwd            >/dev/null 2>&1 || true
    systemctl stop    iwd            >/dev/null 2>&1 || true

    # Preparar iwd para fallback: DHCP integrado declarado en main.conf
    # para que cuando 'wifi fallback on' active iwd, no haga falta un paso
    # manual previo. Idempotente: solo agrega la directiva si falta.
    mkdir -p /etc/iwd
    if [[ ! -s /etc/iwd/main.conf ]] \
       || ! grep -qE '^[[:space:]]*EnableNetworkConfiguration[[:space:]]*=' /etc/iwd/main.conf; then
        printf '\n[General]\nEnableNetworkConfiguration=true\n' >> /etc/iwd/main.conf
        info "iwd: DHCP integrado habilitado en /etc/iwd/main.conf (fallback listo)"
    fi
    systemctl stop    iwd            >/dev/null 2>&1 || true

    ok "dependencias instaladas"
}
