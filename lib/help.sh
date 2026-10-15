#!/usr/bin/env bash
# lib/help.sh -- help modular de wifi-setup.
#
# RESPONSABILIDAD UNICA: centralizar TODO el texto de ayuda, con una
# paleta de colores por categoria y una funcion help_<sub> por cada
# subcomando registrado en bin/wifi. El dispatcher llama help_<sub>
# cuando el usuario pide -h/--help, y help_index cuando el usuario
# invoca 'wifi help' sin argumento.
#
# CONVENCIONES:
#   - Toda funcion help_<sub> recibe cero argumentos y escribe a stdout.
#   - El dispatcher resuelve <sub> desde el primer argumento de
#     'wifi <sub> -h' (ver _cmd_help_for en bin/wifi).
#   - Ninguna funcion help_* ejecuta logica de negocio: solo imprime.
#
# PALETA POR CATEGORIA:
#   El color de una seccion depende de la familia funcional del bloque:
#   STATE, RADIO, NET, MAC, USB, LAN, VPN, MONITOR, DIAG, EMERGENCY.
#   El color de un comando dentro de un bloque depende de si es
#   lectura (green), mutacion (yellow), o peligroso (red).
#
# Requiere: common.sh sourceado antes (para C_* y terminal check).

# ---------------------------------------------------------------------------
# Paleta del help. Los colores se derivan de los de common.sh cuando
# stdout es terminal; si no, quedan vacios (ASCII plano).
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    H_TITLE="${C_BOLD}${C_CYAN}"
    H_SECTION="${C_BOLD}${C_YELLOW}"
    H_CMD="${C_GREEN}"
    H_ARG="${C_CYAN}"
    H_KEY="${C_BOLD}"
    H_WARN="${C_RED}"
    H_DIM="${C_DIM}"
    H_RESET="${C_RESET}"

    # Colores por categoria de bloque.
    H_CAT_STATE="${C_CYAN}"
    H_CAT_RADIO="${C_CYAN}"
    H_CAT_NET="${C_GREEN}"
    H_CAT_MAC="${C_YELLOW}"
    H_CAT_USB="${C_YELLOW}"
    H_CAT_LAN="${C_GREEN}"
    H_CAT_VPN="${C_GREEN}"
    H_CAT_MONITOR="${C_CYAN}"
    H_CAT_DIAG="${C_YELLOW}"
    H_CAT_EMERG="${C_RED}"
else
    H_TITLE='' H_SECTION='' H_CMD='' H_ARG='' H_KEY='' H_WARN=''
    H_DIM='' H_RESET=''
    H_CAT_STATE='' H_CAT_RADIO='' H_CAT_NET='' H_CAT_MAC='' H_CAT_USB=''
    H_CAT_LAN='' H_CAT_VPN='' H_CAT_MONITOR='' H_CAT_DIAG='' H_CAT_EMERG=''
fi

# ---------------------------------------------------------------------------
# Primitivas de impresion.
# ---------------------------------------------------------------------------

# _help_title <text> -- linea de titulo (nombre + version).
_help_title() {
    printf '%s%s%s\n' "${H_TITLE}" "$*" "${H_RESET}"
}

# _help_intro <text> -- linea de descripcion breve bajo el titulo.
_help_intro() {
    printf '%s\n' "$*"
}

# _help_usage <text> -- linea "USO" sin color.
_help_usage() {
    printf '\n%sUSO%s\n' "${H_SECTION}" "${H_RESET}"
    printf '  %s\n' "$*"
}

# _help_cat <category-tag> <text> -- encabezado de bloque con color
# segun la categoria. <category-tag> es una de las llaves H_CAT_*.
_help_cat() {
    local tag="$1"; shift
    local color
    eval "color=\"\${H_CAT_${tag}:-}\""
    printf '\n%s%s%s\n' "${color}" "$*" "${H_RESET}"
}

# _help_cmd <indent> <cmd> <desc> -- linea de comando con argumentos en
# color distinto al nombre del comando.
_help_cmd() {
    local indent="$1" cmd="$2" desc="$3"
    printf '%s%s%s%s  %s\n' \
        "${indent}" "${H_CMD}" "${cmd}" "${H_RESET}" "${desc}"
}

# _help_note <text> -- nota en dim.
_help_note() {
    printf '%s  %s%s\n' "${H_DIM}" "$*" "${H_RESET}"
}

# _help_warn <text> -- nota en rojo (peligro / perdida de acceso).
_help_warn() {
    printf '%s  %s%s\n' "${H_WARN}" "$*" "${H_RESET}"
}

# ---------------------------------------------------------------------------
# help_index -- ayuda top-level. Es la que se imprime con 'wifi help'
# o 'wifi -h' sin argumentos. Lista los subcomandos agrupados por
# categoria, con la misma paleta que el resto del help.
# ---------------------------------------------------------------------------
help_index() {
    _help_title "wifi-setup 2.0 -- WiFi + LAN + VPN sobre NetworkManager"
    _help_intro ""
    _help_intro "Backbone: NetworkManager. Fallback manual: iwd (parado)."
    _help_intro "Antenas: nativa (PCI) + USB externa; cada una con su perfil."

    _help_usage "sudo wifi <subcomando> [args]"
    _help_note  "cada subcomando acepta -h para su ayuda detallada"

    _help_cat STATE "ESTADO (solo lectura)"
    _help_cmd "  " "wifi status"                "NM, antenas, conexiones, LAN, VPN, internet"
    _help_cmd "  " "wifi ifaces"                "inventario fisico de antenas (kernel + NM)"
    _help_cmd "  " "wifi version"               "version del stack"

    _help_cat RADIO "ANTENAS (WiFi, nativa + USB)"
    _help_cmd "  " "wifi radio list"            "tabla: iface, tipo, estado, conexion, rol"
    _help_cmd "  " "sudo wifi radio primary <i>"   "persistente: i pasa a PRIMARY"
    _help_cmd "  " "sudo wifi radio secondary <i>" "persistente: i pasa a SECONDARY"
    _help_cmd "  " "sudo wifi radio use <i>"       "solo esta sesion (no persiste)"
    _help_cmd "  " "sudo wifi radio clear-session" "olvida override de sesion"
    _help_cmd "  " "sudo wifi radio up <i>"        "activa la antena"
    _help_cmd "  " "sudo wifi radio down <i>"      "desactiva la antena"

    _help_cat NET "REDES WiFi"
    _help_cmd "  " "sudo wifi scan [--iface X]"    "escaneo: redes visibles ahora"
    _help_cmd "  " "sudo wifi add [<ssid>]"        "crear + conectar (picker fzf)"
    _help_cmd "  " "wifi networks [list]"          "tabla unificada del store de redes"
    _help_cmd "  " "sudo wifi networks merge"      "funde perfiles NM al store"
    _help_cmd "  " "sudo wifi networks sync"       "regenera perfiles NM desde el store"
    _help_cmd "  " "sudo wifi switch <ssid>"       "cambia al perfil guardado"
    _help_cmd "  " "sudo wifi passwd <ssid|perfil>" "cambia PSK + reconecta"
    _help_cmd "  " "sudo wifi showpass <profile>"  "muestra PSK"
    _help_cmd "  " "sudo wifi autoconnect <profile> <on|off>" "autoconnect manual"

    _help_cat MAC "MAC (clonado por perfil)"
    _help_cmd "  " "sudo wifi setmac <profile> <mac|random|stable|permanent>" "clonar MAC"
    _help_cmd "  " "wifi showmac <profile>"        "MAC clonada o permanente"

    _help_cat USB "USB NAMING (MAC -> nombre de iface)"
    _help_cmd "  " "wifi usb-names"                "ver mappings y estado de .link"
    _help_cmd "  " "sudo wifi usb-names apply"     "aplicar mappings (proximo boot)"
    _help_cmd "  " "sudo wifi usb-names edit"      "editar config/usb-names.conf"

    _help_cat LAN "LAN (cable ethernet, activacion manual)"
    _help_cmd "  " "sudo wifi lan setup server --ip 1.2.3.2/24"   "IP estatica + NAT"
    _help_cmd "  " "sudo wifi lan setup client --ip 1.2.3.1/24 --gw 1.2.3.2" "IP estatica + gateway"
    _help_cmd "  " "sudo wifi lan setup router"    "DHCP del router, sin NAT"
    _help_cmd "  " "sudo wifi lan setup auto"      "DHCP, sin configuracion propia"
    _help_cmd "  " "sudo wifi lan up"              "activa perfil LAN"
    _help_cmd "  " "sudo wifi lan down"            "desactiva perfil LAN"
    _help_cmd "  " "wifi lan status"               "estado actual del perfil LAN"
    _help_cmd "  " "sudo wifi lan remove"          "borra perfil LAN"

    _help_cat VPN "VPN (Tailscale)"
    _help_cmd "  " "sudo wifi vpn install"         "instala + daemon (sin conectar)"
    _help_cmd "  " "sudo wifi vpn up"              "conecta"
    _help_cmd "  " "sudo wifi vpn up --routes 1.2.3.0/24" "conecta + anuncia subred"
    _help_cmd "  " "sudo wifi vpn up --advertise-exit-node" "conecta + exit node"
    _help_cmd "  " "sudo wifi vpn down"            "desconecta (daemon sigue)"
    _help_cmd "  " "wifi vpn status"               "estado y peers"

    _help_cat MONITOR "MODO MONITOR (una antena, las otras siguen)"
    _help_cmd "  " "sudo wifi monitor on <iface>"  "poner iface en monitor"
    _help_cmd "  " "sudo wifi monitor off <iface>" "devolver a managed"
    _help_cmd "  " "wifi monitor status"           "iface por modo"

    _help_cat DIAG "DIAGNOSTICO"
    _help_cmd "  " "sudo wifi doctor"              "reporte del stack (read-only)"
    _help_cmd "  " "sudo wifi doctor --fix"        "aplica fixes seguros"

    _help_cat EMERG "EMERGENCIA"
    _help_cmd "  " "sudo wifi panic"               "reinicia NM, reconecta antenas"

    _help_cat EMERG "FALLBACK (iwd vs NetworkManager)"
    _help_cmd "  " "sudo wifi fallback on"         "pasa a iwd (NM apagado)"
    _help_cmd "  " "sudo wifi fallback off"        "vuelve a NetworkManager"
    _help_cmd "  " "wifi fallback status"          "quien esta al mando"

    _help_cat STATE "INSTALACION"
    _help_cmd "  " "sudo wifi install"             "instala NM, perfiles, hardening, tailscale"
    _help_cmd "  " "sudo wifi uninstall"           "desinstala (iwd queda instalado, parado)"
    _help_cmd "  " "sudo wifi check"               "verifica estado post-install"

    printf '\n'
}

# ---------------------------------------------------------------------------
# help_<sub> -- ayuda por subcomando. Una funcion por cada entrada del
# dispatcher en bin/wifi.
# ---------------------------------------------------------------------------

help_status() {
    _help_title "wifi status -- estado del stack"
    _help_usage "wifi status"
    printf '\n'
    _help_intro "Reporte de lectura. No requiere root. Recorre:"
    printf '  %sNM%s  estado del servicio NetworkManager\n' "${H_KEY}" "${H_RESET}"
    printf '  %sAntenas%s  tabla de wifi-setup radio list\n' "${H_KEY}" "${H_RESET}"
    printf '  %sDevices NM%s  todos los devices conocidos por NM\n' "${H_KEY}" "${H_RESET}"
    printf '  %sConexiones%s  perfiles y autoconnect\n' "${H_KEY}" "${H_RESET}"
    printf '  %sLAN%s  estado del cable ethernet\n' "${H_KEY}" "${H_RESET}"
    printf '  %sVPN%s  estado de Tailscale\n' "${H_KEY}" "${H_RESET}"
    printf '  %sInternet%s  ping a 1.1.1.1\n' "${H_KEY}" "${H_RESET}"
    printf '\n'
    _help_note "para detalle por area: wifi radio list, wifi lan status, wifi vpn status"
}

help_ifaces() {
    _help_title "wifi ifaces -- inventario fisico de antenas WiFi"
    _help_usage "wifi ifaces"
    printf '\n'
    _help_intro "Solo lectura, no requiere root."
    _help_intro "Muestra la union de:"
    printf '  %s- kernel%s  ifaces con /sys/class/net/<iface>/wireless\n' "${H_KEY}" "${H_RESET}"
    printf '  %s- NM%s  ifaces WiFi reconocidas por NetworkManager\n' "${H_KEY}" "${H_RESET}"
    printf '  %s- huerfanos%s  adaptadores USB presentes sin driver de red\n' "${H_KEY}" "${H_RESET}"
    printf '\n'
    _help_intro "Columnas: IFACE, BUS (PCI/USB), DRIVER, MAC PERMANENTE, KERNEL, NM."
}

help_radio() {
    _help_title "wifi radio -- gestion de antenas WiFi"
    _help_usage "sudo wifi radio <sub> [args]"
    _help_intro ""
    _help_intro "Subcomandos:"
    _help_cmd "  " "list"                "tabla: iface, tipo, estado, conexion, rol"
    _help_cmd "  " "primary <iface>"     "persistente: iface pasa a PRIMARY"
    _help_cmd "  " "secondary <iface>"   "persistente: iface pasa a SECONDARY"
    _help_cmd "  " "use <iface> [--persist]" "solo esta sesion (o persistente con flag)"
    _help_cmd "  " "clear-session"       "olvida override de sesion"
    _help_cmd "  " "up <iface> [--persist]" "activa la antena (autoconnect on con --persist)"
    _help_cmd "  " "down <iface> [--persist]" "desactiva la antena (autoconnect off con --persist)"
    printf '\n'
    _help_intro "Modelo: PRIMARY/SECONDARY solo controlan la prioridad de ruta;"
    _help_intro "ambas antenas pueden estar activas simultaneamente."
}

help_scan() {
    _help_title "wifi scan -- escanear redes WiFi visibles"
    _help_usage "sudo wifi scan [--iface X] [--live] [--names]"
    printf '\n'
    _help_intro "Dispara un rescan sobre las antenas WiFi y lista las redes"
    _help_intro "visibles ahora. Solo lectura: no crea perfiles, no conecta."
    printf '\n'
    _help_intro "Modos de salida:"
    printf '  %s(sin flags)%s  tabla completa: IN-USE, BSSID, SSID, CHAN, SIGNAL, SECURITY\n' "${H_KEY}" "${H_RESET}"
    printf '  %s--names%s      lista plana: solo SSID, uno por linea, deduplicado\n' "${H_KEY}" "${H_RESET}"
    printf '\n'
    _help_intro "Modos de refresco:"
    printf '  %s(sin flags)%s  una sola foto: imprime y termina\n' "${H_KEY}" "${H_RESET}"
    printf '  %s--live%s       refresca cada 5s hasta Ctrl-C\n' "${H_KEY}" "${H_RESET}"
    printf '\n'
    _help_intro "Las dos dimensiones se combinan libremente:"
    printf '  %swifi scan --names%s          lista plana puntual\n' "${H_CMD}" "${H_RESET}"
    printf '  %swifi scan --live%s           tabla que se refresca\n' "${H_CMD}" "${H_RESET}"
    printf '  %swifi scan --live --names%s   lista plana que se refresca\n' "${H_CMD}" "${H_RESET}"
    printf '\n'
    _help_intro "Sin --iface: si hay PRIMARY persistida, escanea solo esa"
    _help_intro "antena. Si no hay PRIMARY, deja que NM escanee en todas."
    printf '\n'
    _help_intro "El rescan requiere root: nmcli dispara el escaneo via"
    _help_intro "la accion polkit org.freedesktop.NetworkManager.wifi.scan."
    printf '\n'
    _help_intro "Cada snapshot guarda la lista de SSID en STATE_DIR/last-scan.txt"
    _help_intro "para que 'wifi add' sin <ssid> la use como picker fzf."
    printf '\n'
    _help_intro "Columnas que emite nmcli dev wifi list:"
    printf '  %sIN-USE%s  * si la red esta en uso en esa antena\n' "${H_KEY}" "${H_RESET}"
    printf '  %sBSSID%s   MAC del punto de acceso\n' "${H_KEY}" "${H_RESET}"
    printf '  %sSSID%s    nombre de la red\n' "${H_KEY}" "${H_RESET}"
    printf '  %sCHAN%s    canal\n' "${H_KEY}" "${H_RESET}"
    printf '  %sSIGNAL%s  calidad 0-100\n' "${H_KEY}" "${H_RESET}"
    printf '  %sSECURITY%s  WPA1/2/3, WEP o abierta\n' "${H_KEY}" "${H_RESET}"
}

help_add() {
    _help_title "wifi add -- crear y conectar un perfil WiFi"
    _help_usage "sudo wifi add [<ssid>] [--iface X] [--pass P]"
    printf '\n'
    _help_intro "Sin <ssid>: si fzf esta instalado y existe un escaneo"
    _help_intro "previo (STATE_DIR/last-scan.txt), abre un picker sobre los"
    _help_intro "SSID visibles. Corre 'wifi scan' antes para poblarlo."
    _help_intro "Sin --iface usa la antena PRIMARY (o la unica disponible)."
    _help_intro "Sin --pass pide la PSK interactivo (min 8 caracteres)."
    printf '\n'
    _help_intro "La PSK admite espacios al inicio y al final: se preservan"
    _help_intro "tal cual se escriben."
    printf '\n'
    _help_intro "Tras crear el perfil, se intenta conectar de inmediato y"
    _help_intro "se muestra la salida real de nmcli (exito o causa de fallo)."
    _help_intro "El perfil queda con autoconnect=on y prioridad segun el rol"
    _help_intro "de la antena (PRIMARY=100, SECONDARY=50)."
}

help_networks() {
    _help_title "wifi networks -- store central de redes WiFi"
    _help_usage "sudo wifi networks <list|merge|sync>"
    _help_intro ""
    _help_intro "Store: STATE_DIR/networks.tsv, una fila por (ssid, iface)."
    _help_intro "La PSK se guarda una vez por SSID y se propaga a todas las filas."
    printf '\n'
    _help_cmd "  " "list"   "tabla unificada del store + presencia del perfil NM"
    _help_cmd "  " "merge"  "funde perfiles NM actuales al store (aditivo)"
    _help_cmd "  " "sync"   "regenera perfiles NM desde el store (idempotente)"
}

help_switch() {
    _help_title "wifi switch -- cambiar a un perfil guardado"
    _help_usage "sudo wifi switch <ssid> [iface]"
    printf '\n'
    _help_intro "Activa el perfil wifi-<iface>-<ssid> ya existente. Si no se"
    _help_intro "especifica iface, usa la PRIMARY."
    _help_note "para crear un perfil nuevo: wifi add <ssid>"
}

help_passwd() {
    _help_title "wifi passwd -- cambiar PSK de un perfil"
    _help_usage "sudo wifi passwd <profile|ssid> [--pass P]"
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
    _help_title "wifi showpass -- PSK en claro de un perfil"
    _help_usage "sudo wifi showpass <profile>"
    printf '\n'
    _help_intro "Muestra la PSK guardada en el perfil NM (requiere --show-secrets,"
    _help_intro "por eso root)."
    _help_warn "la salida contiene la clave en claro: no la pegues en logs compartidos."
}

help_setmac() {
    _help_title "wifi setmac -- clonar MAC por perfil"
    _help_usage "sudo wifi setmac <profile> <mac|random|stable|permanent>"
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
    _help_usage "sudo wifi autoconnect <profile> <on|off>"
    printf '\n'
    _help_intro "on   el perfil se activa solo cuando la antena ve la red."
    _help_intro "off  el perfil existe pero no se activa automaticamente."
    _help_note "el perfil LAN y los perfiles USB usan off por diseno."
}

help_monitor() {
    _help_title "wifi monitor -- modo monitor por antena"
    _help_usage "sudo wifi monitor <on|off|status> [iface]"
    _help_intro ""
    _help_cmd "  " "on <iface>"     "NM libera la iface y la deja en modo monitor"
    _help_cmd "  " "off <iface>"    "vuelve a managed; NM reconecta con su perfil"
    _help_cmd "  " "status"         "tabla: iface, tipo, estado en NM"
    printf '\n'
    _help_warn "si es la unica antena con conexion, ponerla en monitor corta el acceso remoto."
}

help_doctor() {
    _help_title "wifi doctor -- diagnostico + auto-fix del stack"
    _help_usage "sudo wifi doctor [--fix]"
    printf '\n'
    _help_intro "Sin flags: solo reporta. Read-only, no requiere root."
    _help_intro "Con --fix: aplica los fixes seguros (no destructivos)."
    printf '\n'
    _help_intro "Chequeos:"
    printf '  %s- servicios%s  NM activo, iwd/dhcpcd/networkd parados\n' "${H_KEY}" "${H_RESET}"
    printf '  %s- antenas%s  estado por iface, driver, MAC\n' "${H_KEY}" "${H_RESET}"
    printf '  %s- perfiles NM%s  huerfanos y prioridades\n' "${H_KEY}" "${H_RESET}"
    printf '  %s- renombrado USB%s  .link presentes y aplicados\n' "${H_KEY}" "${H_RESET}"
    printf '  %s- comando%s  symlink /usr/local/bin/wifi\n' "${H_KEY}" "${H_RESET}"
    printf '  %s- tailscale%s  instalado, daemon, conexion\n' "${H_KEY}" "${H_RESET}"
}

help_lan() {
    _help_title "wifi lan -- cable ethernet (activacion manual)"
    _help_usage "sudo wifi lan <setup|up|down|status|remove>"
    _help_intro ""
    _help_intro "Perfil unico wifi-setup-lan con autoconnect=off. Existe y"
    _help_intro "sobrevive reboot, pero NO se activa hasta: wifi lan up."
    printf '\n'
    _help_cmd "  " "setup server [--ip CIDR] [--iface X]"     "IP estatica + NAT (comparte internet)"
    _help_cmd "  " "setup client [--ip CIDR] [--gw IP]"       "IP estatica + gateway (recibe internet)"
    _help_cmd "  " "setup router"                            "DHCP del router, sin NAT"
    _help_cmd "  " "setup auto"                              "DHCP, sin configuracion propia"
    _help_cmd "  " "up"                                      "activa el perfil"
    _help_cmd "  " "down"                                    "desactiva el perfil"
    _help_cmd "  " "status"                                  "estado actual"
    _help_cmd "  " "remove"                                  "borra el perfil y el state"
}

help_usb_names() {
    _help_title "wifi usb-names -- MAC -> nombre de iface USB WiFi"
    _help_usage "sudo wifi usb-names <status|apply|edit>"
    _help_intro ""
    _help_intro "Fuente: config/usb-names.conf (una linea: <mac> <nombre>)."
    _help_intro "Al aplicar, se escribe un .link systemd por mapping. El rename"
    _help_intro "surte efecto en el proximo boot."
    printf '\n'
    _help_cmd "  " "status"  "ver mappings y si el .link existe"
    _help_cmd "  " "apply"   "escribir/actualizar los .link"
    _help_cmd "  " "edit"    "abrir el .conf en \$EDITOR"
}

help_vpn() {
    _help_title "wifi vpn -- Tailscale (instalacion + control manual)"
    _help_usage "sudo wifi vpn <install|up|down|status>"
    _help_intro ""
    _help_intro "install.sh deja el daemon activo sin conectar. La conexion"
    _help_intro "es siempre una decision explicita del usuario."
    printf '\n'
    _help_cmd "  " "install"                                "instalar + daemon (sin conectar)"
    _help_cmd "  " "up"                                     "conectar"
    _help_cmd "  " "up --routes 1.2.3.0/24"                 "conectar + anunciar subred"
    _help_cmd "  " "up --advertise-exit-node"                "conectar + exit node"
    _help_cmd "  " "down"                                   "desconectar (daemon sigue)"
    _help_cmd "  " "status"                                 "estado, version, peers, IP"
}

help_panic() {
    _help_title "wifi panic -- recuperacion de emergencia"
    _help_usage "sudo wifi panic"
    printf '\n'
    _help_intro "Reinicia NetworkManager, espera 3s, y reconecta todas las"
    _help_intro "antenas WiFi conocidas."
    _help_warn "corta la red brevemente. Si tu acceso es remoto y no hay otra"
    _help_warn "antena activa, podes perder la sesion SSH."
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

help_install() {
    _help_title "wifi install -- instalacion del stack"
    _help_usage "sudo wifi install"
    printf '\n'
    _help_intro "Auto-detecta antenas (USB=PRIMARY, nativa=SECONDARY), pregunta"
    _help_intro "SSID/PSK si no hay perfiles previos, y deja:"
    printf '  %s- NetworkManager%s como gestor de red\n' "${H_KEY}" "${H_RESET}"
    printf '  %s- iwd%s instalado y parado (fallback manual)\n' "${H_KEY}" "${H_RESET}"
    printf '  %s- perfiles WiFi%s por antena con prioridad\n' "${H_KEY}" "${H_RESET}"
    printf '  %s- SSH%s hardened en puerto 22\n' "${H_KEY}" "${H_RESET}"
    printf '  %s- Tailscale%s instalado y apagado\n' "${H_KEY}" "${H_RESET}"
    printf '\n'
    _help_intro "El cable LAN NO se configura: usa 'wifi lan setup' cuando lo necesites."
    _help_intro "Relaunch en tmux para sobrevivir cortes de SSH durante el install."
}

help_uninstall() {
    _help_title "wifi uninstall -- desinstalar el stack"
    _help_usage "sudo wifi uninstall"
    printf '\n'
    _help_intro "Revierte el install sin tocar los perfiles NM. iwd queda"
    _help_intro "instalado y parado; NM se deja como estaba."
    _help_warn "revisa el resumen final para confirmar que no quedo ningun servicio activo."
}

help_check() {
    _help_title "wifi check -- verificacion post-install"
    _help_usage "sudo wifi check"
    printf '\n'
    _help_intro "Chequeos PASS/FAIL con hint de causa/fix:"
    printf '  %s- NM%s  activo + habilitado en boot\n' "${H_KEY}" "${H_RESET}"
    printf '  %s- antenas%s  visibles por NM y estado\n' "${H_KEY}" "${H_RESET}"
    printf '  %s- conectividad%s  IP, ping, DNS\n' "${H_KEY}" "${H_RESET}"
    printf '  %s- SSH%s  sshd activo, puerto 22 escuchando\n' "${H_KEY}" "${H_RESET}"
    printf '  %s- iwd%s  parado (fallback listo)\n' "${H_KEY}" "${H_RESET}"
    printf '  %s- tailscale%s  instalado, daemon, conexion\n' "${H_KEY}" "${H_RESET}"
    printf '  %s- LAN%s  estado (informativo)\n' "${H_KEY}" "${H_RESET}"
}

help_version() {
    _help_title "wifi version -- version del stack"
    _help_usage "wifi version"
    printf '\n'
    _help_intro "Imprime la version de wifi-setup y el backbone usado."
}
