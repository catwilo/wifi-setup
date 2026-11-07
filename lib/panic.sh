# shellcheck shell=bash
# lib/panic.sh -- panic_run: recuperacion de emergencia.
# Requiere common.sh + log.sh + nm.sh + radio.sh (via _load).

panic_run() {
    nm_require
    require_root
    warn "PANIC: reiniciando NetworkManager..."
    systemctl restart NetworkManager
    sleep 3
    local iface
    while IFS= read -r iface; do
        [[ -n "${iface}" ]] || continue
        info "reconectando ${iface}..."
        nmcli dev connect "${iface}" 2>/dev/null || true
    done < <(radio_ifaces)
    ok "recuperacion completa"
    nm_dev_list
}
