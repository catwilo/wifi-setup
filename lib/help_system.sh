# shellcheck shell=bash
help_usb() {
    _help_title "wifi usb-names -- MAC -> nombre de iface USB WiFi"
    _help_usage "sudo wifi usb <status|apply|edit>"
    _help_intro ""
    _help_intro "Fuente: config/usb-names.conf (una linea: <mac> <nombre>)."
    _help_intro "Al aplicar, se escribe un .link systemd por mapping. El rename"
    _help_intro "surte efecto en el proximo boot."
    printf '\n'
    _help_cmd "  " "status"  "ver mappings y si el .link existe"
    _help_cmd "  " "apply"   "escribir/actualizar los .link"
    _help_cmd "  " "edit"    "abrir el .conf en \$EDITOR"
}

help_fallback() {
    _help_title "wifi fallback -- alterna a iwd como gestor WiFi"
    _help_usage "sudo wifi fallback <on|off|status>"
    printf '\n'
    _help_intro "Backbone normal: NetworkManager. Fallback: iwd."
    _help_intro "iwd queda instalado y disabled en el flujo normal; este"
    _help_intro "comando lo pone al mando o devuelve el control a NM."
    printf '\n'
    _help_cmd "  " "on"     "para + enmascara NM, arranca iwd"
    _help_cmd "  " "off"    "para iwd, desenmascara + arranca NM"
    _help_cmd "  " "status" "quien esta al mando ahora"
    printf '\n'
    _help_intro "El comando guarda el estado previo de NM e iwd antes de"
    _help_intro "tocar nada; 'off' restaura el estado original."
    _help_note "conecta con iwd: iwctl station <iface> connect <ssid>"
    _help_note "scan con iwd:   iwctl station <iface> scan"
}

help_ssh() {
    _help_title "wifi ssh -- hardening SSH (opt-in)"
    _help_usage "sudo wifi ssh <harden|status|revert>"
    printf '\n'
    _help_intro "Escribe /etc/ssh/sshd_config.d/99-wifi-setup.conf con"
    _help_intro "overrides conservadores (sin root login, sin empty pass,"
    _help_intro "keepalive, UseDNS no). No toca sshd_config base."
    printf '\n'
    _help_cmd "  " "harden" "aplica el drop-in, valida, reinicia ssh"
    _help_cmd "  " "status" "reporta si el drop-in esta aplicado y valido"
    _help_cmd "  " "revert" "borra el drop-in, valida, reinicia ssh"
    printf '\n'
    _help_note "sshd -t se corre antes de cada restart; si falla, se revierte"
}

help_clean() {
    _help_title "wifi clean -- limpia residuos de instalaciones canceladas"
    _help_usage "sudo wifi clean"
    printf '\n'
    _help_intro "Barre el estado que dejaron instalaciones a medias,"
    _help_intro "migraciones canceladas y procesos huerfanos. NO cambia"
    _help_intro "el gestor activo (iwd o NM); para eso: wifi fallback on/off."
    printf '\n'
    _help_intro "Limpia:"
    _help_cmd "  " "procesos"     "wpa_supplicant y dhcpcd huerfanos"
    _help_cmd "  " "servicios"    "wpa_supplicant.service + wpa_supplicant@*"
    _help_cmd "  " "leases"       "/var/lib/dhcpcd/wlan*.lease"
    _help_cmd "  " "perfiles"     "perfiles NM WiFi cuya iface no existe"
    _help_cmd "  " "interfaces"   "bloques de /etc/network/interfaces de ifaces inexistentes"
    printf '\n'
    _help_intro "Respeta:"
    _help_cmd "  " "gestor"       "el que este activo (iwd o NM)"
    _help_cmd "  " "red"          "la red activa (no desconecta nada)"
    _help_cmd "  " "perfiles"     "los perfiles NM activos y los de ifaces vivas"
    printf '\n'
    _help_note "idempotente: se puede correr mil veces"
}

help_version() {
    _help_title "wifi version -- version del stack"
    _help_usage "wifi version"
    printf '\n'
    _help_intro "Imprime la version de wifi-setup y el backbone usado."
}
