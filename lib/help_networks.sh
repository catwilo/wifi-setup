# shellcheck shell=bash
help_networks() {
    _help_title "wifi networks -- store central de redes WiFi"
    _help_usage "sudo wifi networks <list|show|pull <nm|iwd>|export|import|cleanup>"
    _help_intro ""
    _help_intro "Store: STATE_DIR/networks.tsv, una fila por (ssid, iface)."
    _help_intro "La PSK se guarda una vez por SSID y se propaga a todas las filas."
    printf '\n'
    _help_cmd "  " "list"              "tabla del store (ordenable)"
    _help_intro "     columnas: ssid, iface, auto, prio, nm, iwd"
    _help_intro "     --sort <col>  ordenar por columna (default: ssid)"
    _help_intro "     --reverse     descendente"
    _help_cmd "  " "show <ssid>"       "ficha completa de un SSID"
    _help_cmd "  " "pull nm"           "funde perfiles NM actuales al store (aditivo)"
        _help_cmd "  " "pull iwd"          "agrega al store las redes conocidas por iwd"
    _help_cmd "  " "export <path>"     "copia el store a <path> (backup)"
    _help_cmd "  " "import <path>"     "mergea desde <path> (aditivo)"
    _help_cmd "  " "cleanup"           "elimina filas huerfanas (con confirmacion)"
    printf '\n'
    _help_warn "todos los subcomandos requieren root (la DB contiene PSKs en claro)."
    _help_intro "import-iwd, export, import funcionan sin NM (util en fallback)."
    _help_intro "el resto requiere NM activo."
}

help_connect() {
    _help_title "wifi switch -- cambiar a un perfil guardado"
    _help_usage "sudo wifi connect <ssid> [iface]"
    printf '\n'
    _help_intro "Activa el perfil wifi-<iface>-<ssid> ya existente. Si no se"
    _help_intro "especifica iface, usa la PRIMARY."
    _help_note "para crear un perfil nuevo: wifi add <ssid>"
}

help_password() {
    _help_title "wifi passwd -- cambiar PSK de un perfil"
    _help_usage "sudo wifi password set <profile|ssid> [--pass P]"
    printf '\n'
    _help_intro "Acepta el nombre exacto del perfil ('wifi-<iface>-<ssid>')"
    _help_intro "o el SSID de la red; con el SSID se resuelve el primer"
    _help_intro "perfil WiFi que lo declare."
    _help_intro "Sin --pass pide la PSK nueva de forma interactiva."
    printf '\n'
    _help_intro "La PSK admite espacios al inicio y al final: se preservan"
    _help_intro "tal cual se escriben (no se recortan)."
    printf '\n'
    _help_intro "Tras aplicarla, reconecta el perfil y muestra la salida"
    _help_intro "real de nmcli (conecta o la causa del fallo)."
    _help_note "para ver perfiles disponibles: wifi networks"
}

help_showpass() {
    _help_title "wifi showpass -- PSK en claro de un perfil o SSID"
    _help_usage "sudo wifi showpass <perfil|ssid>"
    printf '\n'
    _help_intro "Busca la PSK en tres fuentes, en este orden:"
    _help_intro "  1. Perfil NM (si existe y NM esta corriendo)"
    _help_intro "  2. DB (STATE_DIR/networks.tsv)"
    _help_intro "  3. iwd (/var/lib/iwd/<ssid>.psk)"
    printf '\n'
    _help_intro "Funciona aunque NM este parado, si la red esta en la DB o en iwd."
    printf '\n'
    _help_warn "la salida contiene la clave en claro: no la pegues en logs compartidos."
}

help_profile() {
    _help_title "wifi rename -- renombrar un perfil guardado"
    _help_usage "sudo wifi profile rename <perfil-actual> <perfil-nuevo>"
    printf '\n'
    _help_intro "Cambia solo el nombre del perfil NM. UUID, PSK, MAC y"
    _help_intro "prioridad se preservan intactos."
    printf '\n'
    _help_note "para listar perfiles: wifi networks"
}

help_priority() {
    _help_title "wifi setpriority -- cambiar prioridad de un perfil"
    _help_usage "sudo wifi priority set <perfil|ssid> <N>"
    printf '\n'
    _help_intro "Mayor N = preferido. Cuando dos perfiles pueden conectar a"
    _help_intro "la misma antena, NM elige el de prioridad mas alta."
    _help_intro "Persistente: sobrevive reboot."
    printf '\n'
    _help_intro "Acepta el nombre del perfil ('wifi-<iface>-<ssid>') o el"
    _help_intro "SSID de la red."
    printf '\n'
    _help_note "valores tipicos: 0 (default), 100 (alta), 50 (media)"
}

help_delete() {
    _help_title "wifi delete -- borrar un perfil guardado"
    _help_usage "sudo wifi delete <perfil|ssid>"
    printf '\n'
    _help_intro "Elimina el perfil NM y sus filas en la DB del store."
    printf '\n'
    _help_warn "irreversible: la PSK del perfil desaparece con el."
    _help_note "para ver los perfiles: wifi networks"
}

help_mac() {
    _help_title "wifi setmac -- clonar MAC por perfil"
    _help_usage "sudo wifi mac set <profile> <mac|random|stable|permanent>"
    printf '\n'
    _help_intro "Valores aceptados:"
    printf '  %smac%s        MAC literal aa:bb:cc:dd:ee:ff\n' "${H_KEY}" "${H_RESET}"
    printf '  %srandom%s     MAC aleatoria en cada conexion\n' "${H_KEY}" "${H_RESET}"
    printf '  %sstable%s     MAC aleatoria estable por perfil\n' "${H_KEY}" "${H_RESET}"
    printf '  %spermanent%s  MAC de fabrica (equivale a no clonar)\n' "${H_KEY}" "${H_RESET}"
}

help_showmac() {
    _help_title "wifi showmac -- MAC clonada de un perfil"
    _help_usage "wifi showmac <profile>"
    printf '\n'
    _help_intro "Imprime 802-11-wireless.cloned-mac-address (WiFi) o"
    _help_intro "802-3-ethernet.cloned-mac-address (ethernet). 'permanent'"
    _help_intro "significa que no hay clonado."
}

help_autoconnect() {
    _help_title "wifi autoconnect -- autoconnect manual de un perfil"
    _help_usage "sudo wifi autoconnect set <profile> <on|off>"
    printf '\n'
    _help_intro "on   el perfil se activa solo cuando la antena ve la red."
    _help_intro "off  el perfil existe pero no se activa automaticamente."
    _help_note "el perfil LAN y los perfiles USB usan off por diseno."
}

