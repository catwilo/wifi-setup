# shellcheck shell=bash
help_status() {
    _help_title "wifi status -- estado general de la red"
    _help_usage "wifi status"
    printf '\n'
    _help_intro "Reporte de lectura. No requiere root. Funciona con NM o con"
    _help_intro "iwd como gestor activo (modo fallback)."
    printf '\n'
    _help_intro "Secciones:"
    printf '  %sGestor%s     NM o iwd activo (o ninguno)\n' "${H_KEY}" "${H_RESET}"
    printf '  %sInterfaces%s estado e IP por iface (kernel)\n' "${H_KEY}" "${H_RESET}"
    printf '  %sRuta%s       ruta por defecto actual\n' "${H_KEY}" "${H_RESET}"
    printf '  %sAntenas%s    antenas WiFi detectadas en /sys (kernel)\n' "${H_KEY}" "${H_RESET}"
    printf '  %sConexiones%s devices/conexiones del gestor activo\n' "${H_KEY}" "${H_RESET}"
    printf '  %sLAN%s        estado del perfil LAN (solo con NM)\n' "${H_KEY}" "${H_RESET}"
    printf '  %sVPN%s        estado de Tailscale\n' "${H_KEY}" "${H_RESET}"
    printf '  %sInternet%s   ping a 1.1.1.1\n' "${H_KEY}" "${H_RESET}"
    printf '\n'
    _help_note "para detalle por area: wifi ifaces, wifi radio list, wifi fallback status"
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
    _help_cmd "  " "session clear"       "olvida override de sesion"
    _help_cmd "  " "up <iface> [--persist]" "activa la antena (autoconnect on con --persist)"
    _help_cmd "  " "down <iface> [--persist]" "desactiva la antena (autoconnect off con --persist)"
    _help_cmd "  " "boot"               "fallback de arranque (interno, lo corre systemd)"
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

