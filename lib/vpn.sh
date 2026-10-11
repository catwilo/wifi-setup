#!/usr/bin/env bash
# lib/vpn.sh -- Tailscale (instalacion + control manual).
#
# RESPONSABILIDAD UNICA: instalar Tailscale, dejar el daemon corriendo
# sin conectar, y exponer subcomandos para conectar/desconectar/ver
# estado y anunciar rutas.
#
# MODELO:
#   - install.sh instala el paquete + systemctl enable tailscaled.
#   - NO ejecuta 'tailscale up' automaticamente.
#   - El usuario conecta cuando quiere con: wifi vpn up
#   - 'wifi vpn up' puede anunciar la subred LAN si existe perfil LAN
#     (para que otros nodos alcancen la red directa).
#
# Requiere: common.sh + log.sh cargados antes.

VPN_TS_SCRIPT_URL="https://tailscale.com/install.sh"
VPN_TS_SCRIPT_PATH="/tmp/wifisetup.tailscale-install.sh"

# ---------------------------------------------------------------------------
# vpn_install -- instala Tailscale si falta. Idempotente.
# ---------------------------------------------------------------------------
vpn_install() {
    if command -v tailscale >/dev/null 2>&1; then
        info "tailscale ya instalado: $(tailscale version 2>/dev/null | head -1)"
        systemctl enable tailscaled 2>/dev/null || true
        systemctl start  tailscaled 2>/dev/null || true
        return 0
    fi

    info "instalando Tailscale desde repositorio oficial..."
    local curl_cmd
    if command -v curl >/dev/null 2>&1; then
        curl_cmd="curl -fsSL"
    elif command -v wget >/dev/null 2>&1; then
        curl_cmd="wget -qO-"
    else
        die "curl/wget no disponibles -- instala uno y reintenta"
    fi

    # shellcheck disable=SC2086
    ${curl_cmd} "${VPN_TS_SCRIPT_URL}" > "${VPN_TS_SCRIPT_PATH}" \
        || die "no se pudo descargar el instalador de Tailscale"

    bash "${VPN_TS_SCRIPT_PATH}" \
        || die "instalador de Tailscale fallo -- revisa el log: ${VPN_TS_SCRIPT_PATH}"

    rm -f "${VPN_TS_SCRIPT_PATH}"
    systemctl enable tailscaled 2>/dev/null || true
    systemctl start  tailscaled 2>/dev/null || true
    ok "tailscale instalado y daemon activo (sin conectar)"
}

# ---------------------------------------------------------------------------
# vpn_up [--routes CIDR] [--advertise-exit-node]
# Conecta Tailscale. Opcionalmente anuncia rutas.
# ---------------------------------------------------------------------------
vpn_up() {
    command -v tailscale >/dev/null 2>&1 \
        || die "tailscale no instalado -- corre: wifi install"

    systemctl is-active tailscaled >/dev/null 2>&1 \
        || systemctl start tailscaled 2>/dev/null \
        || die "no se pudo arrancar tailscaled"

    local routes="" exit_node=0
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --routes)             routes="${2:-}"; shift 2 ;;
            --advertise-exit-node) exit_node=1; shift ;;
            *) die "flag desconocido: $1" ;;
        esac
    done

    # Autodetect: si hay state LAN con IP, anunciar esa subred.
    if [[ -z "${routes}" && -f "${STATE_DIR}/lan.state" ]]; then
        # shellcheck source=/dev/null
        source "${STATE_DIR}/lan.state"
        if [[ -n "${LAN_IP:-}" ]]; then
            local net; net="$(printf '%s' "${LAN_IP}" | sed 's|/[0-9]*$||; s|\.[0-9]*$|.0|')/24"
            routes="${net}"
            info "autodetect: anunciando subred LAN ${routes}"
        fi
    fi

    local args=(up)
    [[ -n "${routes}" ]] && args+=("--advertise-routes=${routes}")
    [[ "${exit_node}" -eq 1 ]] && args+=("--advertise-exit-node")

    info "tailscale ${args[*]}"
    tailscale "${args[@]}" || die "tailscale up fallo"
    ok "tailscale conectado"
    tailscale status 2>/dev/null | head -5 || true
}

# ---------------------------------------------------------------------------
# vpn_down -- desconecta Tailscale (daemon sigue activo).
# ---------------------------------------------------------------------------
vpn_down() {
    command -v tailscale >/dev/null 2>&1 \
        || die "tailscale no instalado"
    tailscale down || die "tailscale down fallo"
    ok "tailscale desconectado (daemon sigue activo)"
}

# ---------------------------------------------------------------------------
# vpn_status -- imprime estado completo.
# ---------------------------------------------------------------------------
vpn_status() {
    command -v tailscale >/dev/null 2>&1 \
        || { echo "tailscale: no instalado"; return 0; }

    echo "== Daemon =="
    if systemctl is-active tailscaled >/dev/null 2>&1; then
        echo "  tailscaled: activo"
    else
        echo "  tailscaled: inactivo"
    fi

    echo ""
    echo "== Version =="
    tailscale version 2>/dev/null | head -1 || echo "  (no disponible)"

    echo ""
    echo "== Estado =="
    if tailscale status >/dev/null 2>&1; then
        tailscale status 2>/dev/null | head -10
    else
        echo "  tailscale down (conecta con: wifi vpn up)"
    fi

    echo ""
    echo "== IP =="
    tailscale ip 2>/dev/null || echo "  (sin asignar)"
}

# ---------------------------------------------------------------------------
# vpn_print_help -- comandos utiles al final del install.
# ---------------------------------------------------------------------------
vpn_print_help() {
    echo ""
    echo "  VPN (Tailscale) -- instalado y apagado"
    echo "  ─────────────────────────────────────────────────"
    echo "    sudo wifi vpn up             conectar"
    echo "    sudo wifi vpn up --routes 1.2.3.0/24"
    echo "                                 anunciar subred LAN"
    echo "    sudo wifi vpn down           desconectar"
    echo "    wifi vpn status              estado y peers"
    echo ""
}
