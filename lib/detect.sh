#!/usr/bin/env bash
# lib/detect.sh — auto-detección de contexto: sesión SSH, subred upstream,
# y gateway de la sesión SSH. Todo no-destructivo (solo lee).

# ---------------------------------------------------------------------------
# Detectar la interfaz por la que entra la sesión SSH actual.
# Usa $SSH_CONNECTION (client_ip client_port server_ip server_port).
# Imprime la interfaz en stdout, o vacío si no se puede determinar.
# ---------------------------------------------------------------------------
detect_ssh_iface() {
    local server_ip iface
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        # 3er campo = IP local (server) que recibió la conexión
        server_ip="$(awk '{print $3}' <<<"${SSH_CONNECTION}")"
    fi
    if [[ -z "${server_ip:-}" ]] && [[ -n "${SSH_CLIENT:-}" ]]; then
        # Fallback: derivar por la ruta hacia el cliente
        local client_ip
        client_ip="$(awk '{print $1}' <<<"${SSH_CLIENT}")"
        iface="$(ip route get "${client_ip}" 2>/dev/null \
            | grep -oP '(?<=dev )\S+' | head -1 || true)"
        [[ -n "${iface}" ]] && { echo "${iface}"; return 0; }
    fi
    [[ -n "${server_ip:-}" ]] || return 1
    # Buscar qué interfaz tiene esa IP local
    iface="$(ip -o addr show 2>/dev/null \
        | awk -v ip="${server_ip}" '$4 ~ "^"ip"/" {print $2; exit}')"
    [[ -n "${iface}" ]] || return 1
    echo "${iface}"
}

# ---------------------------------------------------------------------------
# Detectar IP local de la sesión SSH (server side). Vacío si no aplica.
# ---------------------------------------------------------------------------
detect_ssh_local_ip() {
    [[ -n "${SSH_CONNECTION:-}" ]] || return 1
    awk '{print $3}' <<<"${SSH_CONNECTION}"
}


# ---------------------------------------------------------------------------
# ¿La interfaz dada es la misma por la que entra el SSH actual?
# is_ssh_iface <iface>  → 0 si sí
# ---------------------------------------------------------------------------
is_ssh_iface() {
    local iface="$1" ssh_iface
    ssh_iface="$(detect_ssh_iface 2>/dev/null || true)"
    [[ -n "${ssh_iface}" ]] && [[ "${ssh_iface}" == "${iface}" ]]
}
