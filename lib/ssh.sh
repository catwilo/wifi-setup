#!/usr/bin/env bash
# lib/ssh.sh — configuración SSH segura, puerto 22, persistente

# ---------------------------------------------------------------------------
# Instalar y asegurar SSH — mejores prácticas
# ---------------------------------------------------------------------------
configure_ssh() {
    log "INFO" "configurando SSH (puerto 22, hardening, persistente)..."

    # Instalar si no existe
    if ! command -v sshd >/dev/null 2>&1; then
        ensure_apt
        apt-get install -y --no-install-recommends openssh-server \
            || die "no se pudo instalar openssh-server — verifica apt y conexión a internet"
    fi

    local sshd_conf="/etc/ssh/sshd_config"
    backup_file "${sshd_conf}"

    # Escribir config de hardening sobre el archivo existente
    # Usando sshd_config.d para no pisar la config base (más limpio y compatible)
    mkdir -p /etc/ssh/sshd_config.d

    cat > /etc/ssh/sshd_config.d/99-wifi-setup.conf <<'EOF'
# wifi-setup: SSH hardening — generado automáticamente
# No editar manualmente; usar scripts/install.sh para reconfigurar

Port 22
AddressFamily inet

# Autenticación
PermitRootLogin prohibit-password
PasswordAuthentication yes
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
PermitEmptyPasswords no
MaxAuthTries 4
MaxSessions 5

# Seguridad de protocolo
Protocol 2
X11Forwarding no
AllowTcpForwarding yes
GatewayPorts no
PermitTunnel no

# Criptografía moderna (compatibilidad amplia pero sin algoritmos débiles)
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group14-sha256,diffie-hellman-group16-sha512
Ciphers aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr
MACs hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com,umac-128-etm@openssh.com

# Keepalive — evita desconexiones fantasma
ClientAliveInterval 60
ClientAliveCountMax 3
TCPKeepAlive yes

# Timeout de login
LoginGraceTime 30

# Logging
LogLevel VERBOSE
SyslogFacility AUTH

# DNS lookup (off = conexiones más rápidas)
UseDNS no

# Compresión (off en redes LAN — ahorra CPU)
Compression no
EOF

    # Asegurar que sshd_config principal incluya el directorio (OpenSSH >= 8.2)
    if ! grep -q "^Include /etc/ssh/sshd_config.d/\*.conf" "${sshd_conf}" 2>/dev/null; then
        echo "" >> "${sshd_conf}"
        echo "Include /etc/ssh/sshd_config.d/*.conf" >> "${sshd_conf}"
    fi

    # Validar config antes de reiniciar — evita dejarnos sin SSH
    if ! sshd -t >/dev/null 2>&1; then
        log "ERROR" "config SSH inválida — revirtiendo a backup..."
        # Mostrar el error exacto
        sshd -t 2>&1 | while read -r line; do log "ERROR" "sshd -t: ${line}"; done
        # Revertir el archivo problemático
        rm -f /etc/ssh/sshd_config.d/99-wifi-setup.conf
        die "sshd -t falló — se revirtió la config. Revisa el log anterior."
    fi

    # Habilitar y reiniciar
    systemctl unmask ssh.service 2>/dev/null || true
    systemctl unmask sshd.service 2>/dev/null || true
    systemctl enable ssh 2>/dev/null || systemctl enable sshd 2>/dev/null \
        || die "no se pudo habilitar ssh.service ni sshd.service en systemd"
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null \
        || die "no se pudo reiniciar SSH — verifica: systemctl status ssh"

    # Verificar que quedó activo
    sleep 1
    if systemctl is-active ssh >/dev/null 2>&1 || systemctl is-active sshd >/dev/null 2>&1; then
        log "INFO" "SSH activo en puerto 22, habilitado para arrancar en boot"
    else
        die "SSH no quedó activo después del restart — verifica: journalctl -u ssh -n 30"
    fi
}
