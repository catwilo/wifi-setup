#!/usr/bin/env bash
# lib/tailscale.sh — instalación de Tailscale (inactivo por defecto)

# ---------------------------------------------------------------------------
# Instalar Tailscale desde el repositorio oficial
# ---------------------------------------------------------------------------
install_tailscale() {
    if command -v tailscale >/dev/null 2>&1; then
        log "INFO" "tailscale ya instalado: $(tailscale version 2>/dev/null | head -1)"
        return 0
    fi

    log "INFO" "instalando Tailscale desde repositorio oficial..."

    # Método oficial: script de instalación firmado
    local ts_script="/tmp/wifisetup.tailscale-install.sh"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL https://tailscale.com/install.sh -o "${ts_script}" \
            || die "no se pudo descargar instalador de Tailscale — verifica conexión a internet"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "${ts_script}" https://tailscale.com/install.sh \
            || die "no se pudo descargar instalador de Tailscale (wget) — verifica conexión a internet"
    else
        # Fallback: apt directo (Debian/Ubuntu)
        ensure_apt
        curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg \
            | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
        echo "deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] \
https://pkgs.tailscale.com/stable/debian bookworm main" \
            > /etc/apt/sources.list.d/tailscale.list
        apt-get update -qq
        apt-get install -y --no-install-recommends tailscale \
            || die "no se pudo instalar tailscale — revisa repositorios apt y conexión"
        return 0
    fi

    bash "${ts_script}" \
        || die "falló el instalador de Tailscale — revisa el log: ${ts_script}"

    rm -f "${ts_script}"
    log "INFO" "Tailscale instalado: $(tailscale version 2>/dev/null | head -1)"
}

# ---------------------------------------------------------------------------
# Dejar Tailscale instalado pero NO conectado (inactivo)
# El daemon corre pero no establece túnel hasta 'tailscale up'
# ---------------------------------------------------------------------------
configure_tailscale_inactive() {
    # Habilitar el daemon para que arranque en boot, pero NO hacer up
    systemctl enable tailscaled 2>/dev/null \
        || log "WARN" "no se pudo habilitar tailscaled en systemd"
    systemctl start tailscaled 2>/dev/null \
        || log "WARN" "no se pudo iniciar tailscaled — puede que ya esté corriendo"

    log "INFO" "tailscaled habilitado (daemon activo, túnel inactivo — requiere 'tailscale up')"
}

# ---------------------------------------------------------------------------
# Mostrar comandos disponibles al final del install
# ---------------------------------------------------------------------------
print_tailscale_commands() {
    local mode="${1:-server}"  # server | client
    echo ""
    echo -e "${C_CYAN}${C_BOLD}━━━ Tailscale (inactivo — listo para activar) ━━━${C_RESET}"
    echo ""
    echo "  Activar y conectar a la red Tailscale:"
    echo "    sudo tailscale up"
    echo ""
    echo "  Ver estado y peers:"
    echo "    sudo tailscale status"
    echo ""
    echo "  Ping a otro nodo Tailscale:"
    echo "    sudo tailscale ping <hostname-o-ip-tailscale>"
    echo ""
    if [[ "${mode}" == "server" ]]; then
        echo "  Anunciar la subred plan (1.2.3.0/24) a la red Tailscale:"
        echo "    sudo tailscale up --advertise-routes=1.2.3.0/24"
        echo ""
        echo "  Actuar como exit node (enrutar tráfico externo de peers):"
        echo "    sudo tailscale up --advertise-exit-node"
        echo ""
        echo "  Anunciar subred + exit node juntos:"
        echo "    sudo tailscale up --advertise-routes=1.2.3.0/24 --advertise-exit-node"
        echo ""
    fi
    echo "  Desconectar (mantiene daemon activo):"
    echo "    sudo tailscale down"
    echo ""
    echo "  Ver IP asignada por Tailscale:"
    echo "    sudo tailscale ip"
    echo ""
    echo -e "${C_CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
    echo ""
}
