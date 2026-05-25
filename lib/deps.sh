#!/usr/bin/env bash
# lib/deps.sh — instalación de dependencias por modo

_apt_ready=0
ensure_apt() {
    if [[ "${_apt_ready}" -eq 0 ]]; then
        log "INFO" "actualizando índice apt..."
        apt-get update -qq \
            || die "apt-get update falló — verifica conexión a internet y /etc/apt/sources.list"
        _apt_ready=1
    fi
}

install_pkg() {
    local cmd="$1" pkg="$2"
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        log "INFO" "instalando dependencia: ${pkg} (para '${cmd}')..."
        ensure_apt
        apt-get install -y --no-install-recommends "${pkg}" \
            || die "no se pudo instalar ${pkg} — verifica apt: apt-cache show ${pkg}"
    else
        log "INFO" "ok: ${cmd} (${pkg})"
    fi
}

install_deps_server() {
    log "INFO" "instalando dependencias modo SERVIDOR..."

    # Core
    install_pkg "wpa_passphrase"  "wpasupplicant"
    install_pkg "ip"              "iproute2"
    install_pkg "iptables"        "iptables"
    install_pkg "curl"            "curl"
    install_pkg "ping"            "iputils-ping"

    # iptables-persistent (para NAT persistente)
    if ! dpkg -l iptables-persistent >/dev/null 2>&1; then
        log "INFO" "instalando iptables-persistent..."
        ensure_apt
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
            iptables-persistent netfilter-persistent \
            || die "no se pudo instalar iptables-persistent"
    fi

    # systemd-networkd para gestión de interfaces
    install_pkg "networkctl" "systemd"

    log "INFO" "dependencias servidor: OK"
}

install_deps_client() {
    log "INFO" "instalando dependencias modo CLIENTE..."

    install_pkg "wpa_passphrase"  "wpasupplicant"
    install_pkg "ip"              "iproute2"
    install_pkg "curl"            "curl"
    install_pkg "ping"            "iputils-ping"

    log "INFO" "dependencias cliente: OK"
}
