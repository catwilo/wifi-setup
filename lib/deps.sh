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
# _deps_ensure_resolved -- DNS via systemd-resolved, convencion Debian.
# Instala el paquete si falta, habilita la unidad, y symlinkea
# /etc/resolv.conf -> /run/systemd/resolve/stub-resolv.conf. Idempotente:
# si /etc/resolv.conf ya apunta al mismo target, no se toca; si es un
# archivo regular (NM o iwd lo escribieron), se respalda antes de reemplazarlo.
# ---------------------------------------------------------------------------
_deps_ensure_resolved() {
    install_pkg resolvectl systemd-resolved
    systemctl enable systemd-resolved >/dev/null 2>&1 || true
    systemctl start  systemd-resolved >/dev/null 2>&1 || true

    local target="/run/systemd/resolve/stub-resolv.conf"
    local current=""
    if [[ -L /etc/resolv.conf ]]; then
        current="$(readlink -f /etc/resolv.conf 2>/dev/null || true)"
    fi
    if [[ "${current}" == "${target}" ]]; then
        info "resolv.conf: ya apunta a ${target}"
    else
        if [[ -e /etc/resolv.conf && ! -L /etc/resolv.conf ]]; then
            bak="/etc/resolv.conf.bak.$(date +%s)"
            cp -a /etc/resolv.conf "${bak}"
            info "resolv.conf: respaldo en ${bak}"
        fi
        ln -sfn "${target}" /etc/resolv.conf
        ok "resolv.conf -> ${target}"
    fi

    if [[ "$(systemctl is-enabled systemd-resolved 2>/dev/null || true)" == "enabled" ]]; then
        info "systemd-resolved: enabled"
    else
        warn "systemd-resolved: no quedo enabled (revisa: systemctl status systemd-resolved)"
    fi
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
    _deps_ensure_resolved

    # Solo paquetes. install NO toca el stack de red:
    #   - no enciende ni apaga servicios (systemctl)
    #   - no escribe /etc/iwd/main.conf (eso lo hace wifi fallback on)
    #   - no migra iwd <-> NetworkManager (eso lo hace wifi fallback on/off)
    #
    # El usuario decide el gestor con:
    #   sudo wifi fallback off   migrar a NetworkManager (con rollback)
    #   sudo wifi fallback on    migrar a iwd
    ok "dependencias instaladas (sin tocar el gestor de red)"
    info "para migrar a NetworkManager: sudo wifi fallback off"
    info "para migrar a iwd:             sudo wifi fallback on"
}
