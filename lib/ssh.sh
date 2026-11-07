#!/usr/bin/env bash
# lib/ssh.sh -- SSH hardening opt-in.
#
# Tres funciones, todas idempotentes:
#   ssh_harden    escribe /etc/ssh/sshd_config.d/99-wifi-setup.conf,
#                 valida con sshd -t, reinicia ssh. Si sshd -t falla,
#                 borra el drop-in y aborta sin tocar la sesion.
#   ssh_status    reporta estado sin tocar nada.
#   ssh_revert    borra el drop-in, valida, reinicia.
#
# El hardening es conservador: solo cambia lo que aporta seguridad sin
# romper compatibilidad. Los defaults de OpenSSH en Debian 13 son
# seguros; aqui se endurecen los puntos de mayor impacto.
#
# NO toca /etc/ssh/sshd_config base. Todo va al drop-in.

SSH_DROPIN="/etc/ssh/sshd_config.d/99-wifi-setup.conf"

_ssh_desired_content() {
    cat <<'EOF'
# wifi-setup: SSH hardening (opt-in).
# Generado por: sudo wifi ssh harden
# Deshacer con: sudo wifi ssh revert
#
# Solo overrides. La configuracion base /etc/ssh/sshd_config no se toca.

# Autenticacion
PermitRootLogin prohibit-password
PermitEmptyPasswords no
MaxAuthTries 4
MaxSessions 5

# Forwarding (SSH tunnels para Tailscale y deploys)
X11Forwarding no
AllowTcpForwarding yes
GatewayPorts no
PermitTunnel no

# Sesion
ClientAliveInterval 60
ClientAliveCountMax 3
LoginGraceTime 30

# Diagnostico
UseDNS no
LogLevel VERBOSE
EOF
}

_ssh_validate() {
    sshd -t
}

_ssh_restart() {
    systemctl restart ssh 2>/dev/null \
        || systemctl restart sshd 2>/dev/null \
        || die "no se pudo reiniciar ssh/sshd"
    sleep 1
    if ! systemctl is-active ssh >/dev/null 2>&1 \
       && ! systemctl is-active sshd >/dev/null 2>&1; then
        die "ssh no quedo activo -- revisa: journalctl -u ssh -n 30"
    fi
}

ssh_harden() {
    require_root
    section "SSH hardening"

    if ! command -v sshd >/dev/null 2>&1; then
        die "openssh-server no instalado -- corre: sudo apt install openssh-server"
    fi

    mkdir -p /etc/ssh/sshd_config.d

    local desired current
    desired="$(_ssh_desired_content)"
    if [[ -f "${SSH_DROPIN}" ]]; then
        current="$(cat "${SSH_DROPIN}")"
    else
        current=""
    fi

    if [[ "${current}" == "${desired}" ]]; then
        info "drop-in sin cambios: ${SSH_DROPIN}"
    else
        printf '%s\n' "${desired}" > "${SSH_DROPIN}"
        chmod 644 "${SSH_DROPIN}"
        ok "drop-in escrito: ${SSH_DROPIN}"
    fi

    if ! _ssh_validate; then
        err "sshd -t fallo, borrando drop-in y abortando"
        rm -f "${SSH_DROPIN}"
        die "config SSH invalida -- no se aplico nada"
    fi

    _ssh_restart
    ok "SSH hardening aplicado y activo"
}

ssh_status() {
    section "SSH status"

    if ! command -v sshd >/dev/null 2>&1; then
        warn "openssh-server no instalado"
        return 0
    fi

    local active
    if systemctl is-active ssh >/dev/null 2>&1; then
        active="ssh (active)"
    elif systemctl is-active sshd >/dev/null 2>&1; then
        active="sshd (active)"
    else
        active="inactivo"
    fi
    printf '  sshd:     %s\n' "${active}"

    if [[ -f "${SSH_DROPIN}" ]]; then
        if _ssh_validate >/dev/null 2>&1; then
            printf '  drop-in:  %s (valido)\n' "${SSH_DROPIN}"
        else
            printf '  drop-in:  %s (INVALIDO -- corre: sudo wifi ssh revert)\n' "${SSH_DROPIN}"
        fi
    else
        printf '  drop-in:  no aplicado (corre: sudo wifi ssh harden)\n'
    fi
}

ssh_revert() {
    require_root
    section "SSH revert"

    if [[ ! -f "${SSH_DROPIN}" ]]; then
        info "drop-in no existe -- nada que revertir"
        return 0
    fi

    rm -f "${SSH_DROPIN}"

    if ! _ssh_validate; then
        die "sshd -t fallo tras revertir -- revisa /etc/ssh/sshd_config"
    fi

    _ssh_restart
    ok "SSH hardening revertido"
}
