#!/usr/bin/env bash
# scripts/install.sh — instalador principal wifi-setup
# Modo: SERVER (dos interfaces, NAT, forwarding) | CLIENT (IP estática, recibe internet)
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/deps.sh"
source "${SCRIPT_DIR}/lib/detect.sh"
source "${SCRIPT_DIR}/lib/net.sh"
source "${SCRIPT_DIR}/lib/forward.sh"
source "${SCRIPT_DIR}/lib/survival.sh"
source "${SCRIPT_DIR}/lib/ssh.sh"
source "${SCRIPT_DIR}/lib/tailscale.sh"

if [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
    echo "uso: sudo wifi install [server|client] [--help]"
    echo ""
    echo "Instalador de wifi-setup. Auto-detecta el contexto (máximo automático):"
    echo "  · modo SERVIDOR por defecto (usa 'client' como argumento para cliente)"
    echo "  · interfaz WiFi USB upstream (autodetectada)"
    echo "  · interfaz plan/ethernet hacia el otro equipo (autodetectada)"
    echo "  · la IP la asigna el AP vía dhcpcd (subred/gateway reales)"
    echo "  · IPs plan fijas: servidor 1.2.3.2, cliente 1.2.3.1, forward server→client"
    echo "  · sesión SSH detectada (\$SSH_CONNECTION) para no perder acceso"
    echo ""
    echo "Única pregunta: SSID y contraseña WiFi, y solo si NO hay config previa."
    echo ""
    echo "Supervivencia SSH:"
    echo "  · tras pedir credenciales, la fase de red corre en una ventana byobu"
    echo "  · si se cae el SSH, el proceso sigue vivo en esa ventana"
    echo "  · cierra la ventana manualmente al terminar para revisar el output"
    echo "  · instala byobu/tmux automáticamente si falta"
    echo ""
    echo "Red de seguridad:"
    echo "  · verifica internet tras configurar; avisa si falla"
    echo ""
    echo "En reinstalación: limpieza idempotente (servicios, symlinks, iptables del"
    echo "proyecto, networkd, sysctl) y sobrescritura de /opt/wifi-setup."
    echo ""
    echo "Ver también:"
    echo "  sudo wifi uninstall    desinstalar todo"
    echo "  sudo wifi check <server|client>   solo verificar"
    exit 0
fi

require_root

INSTALL_DIR="/opt/wifi-setup"

# Auto-update: si corremos desde INSTALL_DIR, buscar repo fuente y sincronizar
_REPO_SOURCE=""
_candidate="${HOME}/scripts/wifi-setup"
if [[ "$(realpath "${SCRIPT_DIR}")" == "$(realpath "${INSTALL_DIR}")" ]]; then
    if [[ -d "${_candidate}" ]] && [[ -f "${_candidate}/install.sh" ]] &&        [[ "$(realpath "${_candidate}")" != "$(realpath "${INSTALL_DIR}")" ]]; then
        _REPO_SOURCE="${_candidate}"
        log "INFO" "auto-update: sincronizando desde repo ${_REPO_SOURCE}..."
        cp -a "${_REPO_SOURCE}/bin/." "${INSTALL_DIR}/bin/"
        cp -a "${_REPO_SOURCE}/lib/." "${INSTALL_DIR}/lib/"
        cp -a "${_REPO_SOURCE}/"*.sh "${INSTALL_DIR}/"
        chmod +x "${INSTALL_DIR}"/bin/* "${INSTALL_DIR}"/*.sh
        log "INFO" "auto-update: archivos sincronizados — continuando con versión actualizada"
        exec "${INSTALL_DIR}/install.sh" "$@"
    else
        log "INFO" "repo fuente no encontrado en ${_candidate} — usando versión instalada"
    fi
fi

# ===========================================================================
# SUPERVIVENCIA SSH: saltar a la ventana byobu ANTES de cualquier salida.
# Todo el install (detección, prompts, mutación) ocurre dentro de la ventana.
# Si ya estamos dentro (flag), retorna y continúa.
# ===========================================================================
INSTALL_MODE="${1:-server}"
case "${INSTALL_MODE}" in server|client) ;; *) INSTALL_MODE="server" ;; esac
relaunch_byobu "${SCRIPT_DIR}/install.sh" "${INSTALL_MODE}"

# ===========================================================================
# UPGRADE: limpieza automática de instalación previa
# — detiene servicios, elimina symlinks viejos (cualquier versión),
#   limpia iptables y networkd; preserva configs WiFi
# Solo se ejecuta dentro de la ventana byobu (flag),
# nunca en el pase interactivo previo al detach, para no duplicar trabajo.
# ===========================================================================
# Determinar si esta es la fase donde toca limpiar/mutar la red:
# Solo dentro de la ventana byobu (flag=1) se ejecuta la fase de mutación.
RUN_MUTATION=1  # dentro de byobu siempre se ejecuta la mutación

if [[ "${RUN_MUTATION}" -eq 1 ]] && [[ -d "${INSTALL_DIR}" ]]; then
    log "INFO" "instalación previa detectada en ${INSTALL_DIR} — limpiando antes de reinstalar..."

    # Barrer restos de instaladores VIEJOS (wifi-setup@.service, wifi-panic, services/)
    sweep_legacy_install

    # Detener y deshabilitar servicios propios
    for svc in wifi-setup-forward wifi-setup-client; do
        systemctl stop    "${svc}" 2>/dev/null || true
        systemctl disable "${svc}" 2>/dev/null || true
        rm -f "/etc/systemd/system/${svc}.service"
    done
    systemctl daemon-reload 2>/dev/null || true

    # Eliminar symlinks de cualquier versión anterior
    # (versiones viejas exponían binarios individuales)
    for old_bin in wifi wfs wifi-status wifi-list wifi-passwd wifi-panic wifi-showpass; do
        old_link="/usr/local/bin/${old_bin}"
        # Solo eliminar si apunta a nuestro INSTALL_DIR (no tocar binarios ajenos)
        if [[ -L "${old_link}" ]] && [[ "$(readlink -f "${old_link}" 2>/dev/null)" == "${INSTALL_DIR}"* ]]; then
            rm -f "${old_link}"
            log "INFO" "symlink eliminado: ${old_link}"
        fi
    done

    # Limpiar reglas iptables del proyecto de forma quirúrgica.
    # No usamos -F FORWARD: eso borraría reglas ajenas. Las reglas concretas
    # del proyecto se vuelven a borrar/insertar idempotentemente en apply_nat
    # con sus interfaces exactas durante esta misma instalación.
    while iptables -t nat -D POSTROUTING -j MASQUERADE 2>/dev/null; do :; done

    # Eliminar configs networkd del proyecto (sin restart — se aplica al final)
    rm -f /etc/systemd/network/10-wifi-setup-*.network
    # Modelo dhcpcd: limpiar .link de MAC y hooks viejos (sobrescritura limpia)
    rm -f /etc/systemd/network/10-wifi-setup-*.link
    rm -f /lib/dhcpcd/dhcpcd-hooks/90-prefer-dot70 /usr/lib/dhcpcd/dhcpcd-hooks/90-prefer-dot70 2>/dev/null || true

    # Eliminar config SSH del proyecto (sin restart — se aplica al final)
    rm -f /etc/ssh/sshd_config.d/99-wifi-setup.conf

    # Limpiar sysctl del proyecto (sin aplicar — se reescribe durante install)
    rm -f /etc/sysctl.d/99-wifi-setup-forward.conf

    log "INFO" "limpieza completada — procediendo con instalación limpia"
fi

# Mantenemos set -e activo. Solo los `read` se toleran con `|| true`.

# ===========================================================================
# BANNER
# ===========================================================================
echo ""
echo -e "${C_BOLD}${C_CYAN}╔══════════════════════════════════════════╗${C_RESET}"
echo -e "${C_BOLD}${C_CYAN}║          wifi-setup  installer           ║${C_RESET}"
echo -e "${C_BOLD}${C_CYAN}╚══════════════════════════════════════════╝${C_RESET}"
echo ""

# ===========================================================================
# AUTO-DETECCIÓN DE CONTEXTO (no destructivo — solo lee)
# Se hace ANTES de purgar la red para capturar subred/gw vivos.
# ===========================================================================
log "INFO" "auto-detectando contexto..."

# --- Sesión SSH actual (para no cortar la ruta de acceso a ciegas) ---
SSH_IFACE="$(detect_ssh_iface 2>/dev/null || true)"
SSH_LOCAL_IP="$(detect_ssh_local_ip 2>/dev/null || true)"
if [[ -n "${SSH_IFACE}" ]]; then
    log "INFO" "sesión SSH entra por: ${SSH_IFACE} (ip local ${SSH_LOCAL_IP:-?})"
else
    log "INFO" "no se detectó sesión SSH (consola local o vía tailscale) — continuo"
fi

# --- Modo: SERVIDOR por defecto (upstream USB + plan 1.2.3.2 + forward a 1.2.3.1) ---
# Override opcional vía argumento: install.sh server | client
INSTALL_MODE="${1:-server}"
case "${INSTALL_MODE}" in
    server|client) ;;
    *) INSTALL_MODE="server" ;;
esac
log "INFO" "modo: ${INSTALL_MODE^^} (override: 'wifi install client' para cliente)"

# --- Interfaz WiFi upstream (USB preferida, si no la primera WiFi) ---
if UPSTREAM_IFACE="$(detect_usb_wifi 2>/dev/null)"; then
    log "INFO" "WiFi USB detectada: ${UPSTREAM_IFACE}"
else
    mapfile -t WIFI_LIST < <(detect_wifi_interfaces)
    [[ "${#WIFI_LIST[@]}" -gt 0 ]] \
        || die "no se encontró interfaz WiFi — conecta el adaptador USB y reintenta"
    UPSTREAM_IFACE="${WIFI_LIST[0]}"
    log "INFO" "WiFi upstream (autoseleccionada): ${UPSTREAM_IFACE}"
fi
WIFI_IFACE="${UPSTREAM_IFACE}"

# Modelo dhcpcd puro: la IP la asigna el AP. No se detecta ni fuerza ninguna IP.

# --- Interfaz plan / estática (auto) ---
PLAN_IFACE=""
STATIC_IFACE=""
if [[ "${INSTALL_MODE}" == "server" ]]; then
    PLAN_IFACE="$(detect_plan_interface 2>/dev/null || true)"
    [[ -n "${PLAN_IFACE}" ]] \
        || die "no se detectó interfaz plan (ethernet hacia cliente) — verifica: ip link show"
    validate_interface "${PLAN_IFACE}"
    log "INFO" "interfaz plan: ${PLAN_IFACE}"
else
    STATIC_IFACE="$(detect_plan_interface 2>/dev/null || true)"
    [[ -n "${STATIC_IFACE}" ]] \
        || die "no se detectó interfaz hacia servidor — verifica: ip link show"
    validate_interface "${STATIC_IFACE}"
    log "INFO" "interfaz estática: ${STATIC_IFACE}"
fi

# --- IPs de la red plan (fijas por diseño) ---
if [[ "${INSTALL_MODE}" == "server" ]]; then
    PLAN_IP="1.2.3.2";  PLAN_CIDR="1.2.3.2/24"
    CLIENT_IP="1.2.3.1"; GATEWAY=""
else
    CLIENT_IP="1.2.3.1"; STATIC_CIDR="1.2.3.1/24"
    GATEWAY="1.2.3.2";   PLAN_IP="1.2.3.2"; PLAN_CIDR=""
fi

# ===========================================================================
# GUARDA DE SEGURIDAD SSH
# Si el SSH entra por una interfaz que se reconfigurará, el desacople vía
# byobu mantiene vivo el proceso. Solo lo registramos.
# ===========================================================================
if [[ -n "${SSH_IFACE}" ]]; then
    if [[ "${SSH_IFACE}" == "${UPSTREAM_IFACE}" ]]; then
        log "WARN" "SSH entra por el upstream ${UPSTREAM_IFACE} — se reconfigurará vía dhcpcd."
        log "WARN" "byobu mantiene vivo el proceso; reconecta a la IP del AP si cae."
        log "WARN" "RECOMENDADO: reinstala entrando por la red plan (1.2.3.x) o Tailscale, no por la USB."
    elif [[ "${INSTALL_MODE}" == "server" && "${SSH_IFACE}" == "${PLAN_IFACE}" ]]; then
        log "INFO" "SSH entra por el plan ${PLAN_IFACE} (estable) — no se interrumpe al reconfigurar la USB."
    fi
fi

# ===========================================================================
# CAPTURA DE CREDENCIALES Y MAC (solo en memoria, pase interactivo).
# NO se escribe nada en la USB aquí. Todas las escrituras (wpa_supplicant,
# MAC, IP fija, purga) ocurren YA DESACOPLADAS, para que un corte de SSH por
# la propia USB no mate el proceso antes de protegerlo.
# Lo capturado se pasa a la ventana byobu vía variables de entorno.
# ===========================================================================
WPA_CONF="/etc/wpa_supplicant/wpa_supplicant-${UPSTREAM_IFACE}.conf"
WIFI_SSID="${WIFI_SSID:-}"
WIFI_PSK_LINE="${WIFI_PSK_LINE:-}"
CHOSEN_MAC="${CHOSEN_MAC:-}"

if true; then  # captura siempre (ya corremos dentro de byobu)
    echo ""
    # --- Credenciales WiFi: solo si no hay config previa ---
    if [[ -f "${WPA_CONF}" ]]; then
        log "INFO" "config WiFi existente en ${UPSTREAM_IFACE} — se conserva (sin preguntar)"
    else
        log "INFO" "no hay config WiFi previa — se requieren credenciales"
        read -r -p "SSID de la red WiFi [cursed]: " WIFI_SSID || true
        WIFI_SSID="${WIFI_SSID:-cursed}"
        while true; do
            read -r -s -p "Contraseña WPA (mín 8 caracteres): " WIFI_PASS || true
            echo
            [[ "${#WIFI_PASS}" -ge 8 ]] && break
            echo "  error: mínimo 8 caracteres"
        done
        WIFI_PSK_LINE="$(wpa_passphrase "${WIFI_SSID}" "${WIFI_PASS}" 2>/dev/null \
            | grep -E '^\s+psk=' | grep -v '#' | tr -d '\t ' || true)"
        unset WIFI_PASS
        [[ -n "${WIFI_PSK_LINE}" ]] || die "wpa_passphrase no generó PSK — verifica la contraseña"
    fi

    # --- MAC: sugerir Windows-like (ENTER) o escribir una propia ---
    MAC_FILE="${STATE_DIR}/mac-${UPSTREAM_IFACE}.mac"
    if [[ -f "${MAC_FILE}" ]]; then
        CHOSEN_MAC="$(cat "${MAC_FILE}")"
        log "INFO" "MAC ya definida para ${UPSTREAM_IFACE}: ${CHOSEN_MAC} — se conserva"
    else
        SUGGESTED_MAC="$(suggest_windows_mac)"
        echo ""
        echo "  ── MAC de la interfaz upstream (${UPSTREAM_IFACE}) ─────────────────"
        echo "  Sugerida (aspecto Windows, fija y persistente): ${SUGGESTED_MAC}"
        echo "  ENTER = aceptar la sugerida   |   o escribe la tuya (AA:BB:CC:DD:EE:FF)"
        echo ""
        read -r -p "MAC [${SUGGESTED_MAC}]: " MAC_INPUT || true
        MAC_INPUT="${MAC_INPUT:-${SUGGESTED_MAC}}"
        while ! CHOSEN_MAC="$(validate_mac "${MAC_INPUT}")"; do
            echo "  error: formato inválido — usa AA:BB:CC:DD:EE:FF"
            read -r -p "MAC [${SUGGESTED_MAC}]: " MAC_INPUT || true
            MAC_INPUT="${MAC_INPUT:-${SUGGESTED_MAC}}"
        done
        log "INFO" "MAC elegida para ${UPSTREAM_IFACE}: ${CHOSEN_MAC}"
    fi
fi

# ===========================================================================
# SUPERVIVENCIA SSH: desacoplar AHORA, antes de tocar la USB.
# Pasamos credenciales y MAC al unit por entorno. Si ya estamos desacoplados
# (flag), esta función retorna y seguimos hacia las escrituras de red.
# ===========================================================================
# --- Credenciales capturadas arriba; escribir config si aplica ---
# Escribir config WiFi si vino credencial nueva y aún no existe el archivo
if [[ -n "${WIFI_PSK_LINE}" ]] && [[ ! -f "${WPA_CONF}" ]]; then
    WIFI_BSSID="$(iwconfig "${UPSTREAM_IFACE}" 2>/dev/null | awk "/Access Point/{print $6}" | grep -v Not)"
    configure_wpa "${UPSTREAM_IFACE}" "${WIFI_SSID}" "${WIFI_PSK_LINE}" "${WIFI_BSSID:-}"
fi
# Persistir la MAC elegida (fuente de verdad para la IP fija)
if [[ -n "${CHOSEN_MAC}" ]]; then
    MAC_FILE="${STATE_DIR}/mac-${UPSTREAM_IFACE}.mac"
    mkdir -p "${STATE_DIR}"
    echo "${CHOSEN_MAC}" > "${MAC_FILE}"
    chmod 600 "${MAC_FILE}"
fi


# ===========================================================================
# INSTALAR DEPENDENCIAS
# ===========================================================================
echo ""
if [[ "${INSTALL_MODE}" == "server" ]]; then
    install_deps_server
else
    install_deps_client
fi

# ===========================================================================
# LIMPIAR STACK PREVIO
# ===========================================================================
echo ""
log "INFO" "limpiando stack de red previo..."
purge_network_stack

# ===========================================================================
# DNS ESTABLE: resolv.conf.head garantiza 1.1.1.1 aunque dhcpcd regenere
# ===========================================================================
if [[ ! -f /etc/resolv.conf.head ]] || ! grep -q "1.1.1.1" /etc/resolv.conf.head 2>/dev/null; then
    printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" > /etc/resolv.conf.head
    log "INFO" "resolv.conf.head configurado con DNS estable (1.1.1.1 / 8.8.8.8)"
fi

# ===========================================================================
# INSTALAR ARCHIVOS
# ===========================================================================
log "INFO" "instalando archivos en ${INSTALL_DIR}..."
require_dirs
if [[ "$(realpath "${SCRIPT_DIR}")" != "$(realpath "${INSTALL_DIR}")" ]]; then
    cp -a "${SCRIPT_DIR}/bin/." "${INSTALL_DIR}/bin/"
    cp -a "${SCRIPT_DIR}/lib/." "${INSTALL_DIR}/lib/"
    cp -a "${SCRIPT_DIR}/"*.sh "${INSTALL_DIR}/"
    log "INFO" "archivos copiados desde ${SCRIPT_DIR}"
else
    log "INFO" "corriendo desde ${INSTALL_DIR} — copia omitida (ya en sitio)"
fi
chmod +x "${INSTALL_DIR}"/bin/*
chmod +x "${INSTALL_DIR}"/*.sh

ln -sf "${INSTALL_DIR}/bin/wifi" "/usr/local/bin/wifi"

# ===========================================================================
# CONFIGURAR SSH (antes de tocar la red — seguridad primero)
# ===========================================================================
echo ""
configure_ssh

# ===========================================================================
# LEVANTAR WiFi + DHCP (upstream)
# ===========================================================================
echo ""
log "INFO" "levantando interfaz WiFi ${UPSTREAM_IFACE}..."
enable_wpa_service "${UPSTREAM_IFACE}"

# systemd-networkd se usa SOLO para el plan (enp4s0 estático). El upstream
# USB se gestiona con dhcpcd (subred/gateway reales del AP) + MAC .link.
systemctl unmask systemd-networkd 2>/dev/null || true
systemctl enable systemd-networkd

# Upstream: MAC persistente .link + dhcpcd toma el lease real del AP.
# Sin restart de networkd (eso cortaba el SSH). No se fuerza ninguna IP.
if setup_and_verify_upstream "${UPSTREAM_IFACE}" "${CHOSEN_MAC:-}"; then
    IP_CHECK="$(ip -o -4 addr show "${UPSTREAM_IFACE}" 2>/dev/null | awk '{print $4}' | head -1 || true)"
    log "INFO" "${UPSTREAM_IFACE} → IP: ${IP_CHECK:-?} (del AP, con internet)"
else
    log "WARN" "upstream sin internet — continúa el setup, revisa WiFi"
fi

# ===========================================================================
# MODO SERVIDOR: IP plan + forwarding + NAT
# ===========================================================================
if [[ "${INSTALL_MODE}" == "server" ]]; then
    echo ""
    log "INFO" "configurando IP plan y forwarding..."

    apply_static_ip "${PLAN_IFACE}" "${PLAN_CIDR}"
    write_networkd_static "${PLAN_IFACE}" "${PLAN_CIDR}" ""
    enable_ip_forward
    apply_nat "${UPSTREAM_IFACE}" "${PLAN_IFACE}"

    # Instalar servicio systemd de persistencia
    cat > /etc/systemd/system/wifi-setup-forward.service <<EOF
[Unit]
Description=wifi-setup: IP estática plan + NAT forwarding
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c '\
    ip addr flush dev ${PLAN_IFACE} 2>/dev/null || true; \
    ip link set ${PLAN_IFACE} up; \
    ip addr add ${PLAN_CIDR} dev ${PLAN_IFACE} 2>/dev/null || true; \
    sysctl -w net.ipv4.ip_forward=1; \
    iptables -t nat -C POSTROUTING -o ${UPSTREAM_IFACE} -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -o ${UPSTREAM_IFACE} -j MASQUERADE; \
    iptables -C FORWARD -i ${PLAN_IFACE} -o ${UPSTREAM_IFACE} -j ACCEPT 2>/dev/null || \
        iptables -A FORWARD -i ${PLAN_IFACE} -o ${UPSTREAM_IFACE} -j ACCEPT; \
    iptables -C FORWARD -i ${UPSTREAM_IFACE} -o ${PLAN_IFACE} -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
        iptables -A FORWARD -i ${UPSTREAM_IFACE} -o ${PLAN_IFACE} -m state --state RELATED,ESTABLISHED -j ACCEPT; \
    iw dev ${UPSTREAM_IFACE} set power_save off 2>/dev/null || true \
'
ExecStop=/bin/bash -c '\
    iptables -t nat -D POSTROUTING -o ${UPSTREAM_IFACE} -j MASQUERADE 2>/dev/null || true; \
    iptables -D FORWARD -i ${PLAN_IFACE} -o ${UPSTREAM_IFACE} -j ACCEPT 2>/dev/null || true; \
    iptables -D FORWARD -i ${UPSTREAM_IFACE} -o ${PLAN_IFACE} -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true \
'

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable wifi-setup-forward
    systemctl restart wifi-setup-forward
    log "INFO" "wifi-setup-forward activo y persistente"
fi

# ===========================================================================
# MODO CLIENTE: IP estática + ruta default
# ===========================================================================
if [[ "${INSTALL_MODE}" == "client" ]]; then
    echo ""
    log "INFO" "configurando IP estática cliente..."

    apply_static_ip "${STATIC_IFACE}" "${STATIC_CIDR}" "${GATEWAY}"
    write_networkd_static "${STATIC_IFACE}" "${STATIC_CIDR}" "${GATEWAY}"

    cat > /etc/systemd/system/wifi-setup-client.service <<EOF
[Unit]
Description=wifi-setup: IP estática cliente plan
After=network.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c '\
    ip addr flush dev ${STATIC_IFACE} 2>/dev/null || true; \
    ip link set ${STATIC_IFACE} up; \
    ip addr add ${STATIC_CIDR} dev ${STATIC_IFACE} 2>/dev/null || true; \
    ip route del default 2>/dev/null || true; \
    ip route add default via ${GATEWAY} dev ${STATIC_IFACE} \
'

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable wifi-setup-client
    systemctl restart wifi-setup-client
    log "INFO" "wifi-setup-client activo y persistente"
fi

# ===========================================================================
# TAILSCALE
# ===========================================================================
echo ""
install_tailscale
configure_tailscale_inactive

# ===========================================================================
# GUARDAR ESTADO
# ===========================================================================
mkdir -p "${STATE_DIR}"
UPSTREAM_MAC=""
if [[ -f "${STATE_DIR}/mac-${UPSTREAM_IFACE}.mac" ]]; then
    UPSTREAM_MAC="$(cat "${STATE_DIR}/mac-${UPSTREAM_IFACE}.mac")"
fi
cat > "${STATE_DIR}/install.state" <<EOF
# wifi-setup install state — generado automáticamente
INSTALL_MODE="${INSTALL_MODE}"
UPSTREAM_IFACE="${UPSTREAM_IFACE}"
WIFI_IFACE="${WIFI_IFACE}"
PLAN_IFACE="${PLAN_IFACE:-}"
PLAN_IP="${PLAN_IP:-}"
PLAN_CIDR="${PLAN_CIDR:-}"
CLIENT_IP="${CLIENT_IP:-}"
STATIC_IFACE="${STATIC_IFACE:-}"
STATIC_CIDR="${STATIC_CIDR:-}"
GATEWAY="${GATEWAY:-}"
UPSTREAM_MAC="${UPSTREAM_MAC}"
EOF
chmod 600 "${STATE_DIR}/install.state"

# ===========================================================================
# VERIFICACIÓN FINAL
# ===========================================================================
echo ""
log "INFO" "ejecutando verificación final..."
sleep 2
bash "${SCRIPT_DIR}/checks.sh" "${INSTALL_MODE}" || true

# ===========================================================================
# COMANDOS TAILSCALE
# ===========================================================================
source "${SCRIPT_DIR}/lib/tailscale.sh"
print_tailscale_commands "${INSTALL_MODE}"

echo -e "${C_GREEN}${C_BOLD}  Instalación completada.${C_RESET}"
echo -e "${C_GREEN}  Log    : ${LOG_DIR}/wifi-setup.log${C_RESET}"
echo -e "${C_GREEN}  Comando: wifi <subcomando> — ejecuta 'wifi help' para ver opciones${C_RESET}"
echo ""
