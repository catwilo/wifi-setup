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
#   STATE, RADIO, NET, MAC, USB, FALLBACK.
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
    H_CAT_EMERG="${C_RED}"
    H_CAT_FALLBACK="${C_YELLOW}"
    H_CAT_EMERG="${C_RED}"
else
    H_TITLE='' H_SECTION='' H_CMD='' H_ARG='' H_KEY='' H_WARN=''
    H_DIM='' H_RESET=''
    H_CAT_EMERG='' H_CAT_FALLBACK=''
    H_CAT_STATE='' H_CAT_RADIO='' H_CAT_NET='' H_CAT_MAC='' H_CAT_USB=''
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
    _help_title "wifi-setup 2.0 -- WiFi sobre NetworkManager"
    _help_intro ""
    _help_intro "Backbone: NetworkManager. Fallback manual: iwd (parado)."
    _help_intro "Antenas: nativa (PCI) + USB externa; cada una con su perfil."

    _help_usage "sudo wifi <subcomando> [args]"
    _help_note  "cada subcomando acepta -h para su ayuda detallada"

    _help_cat STATE "ESTADO (solo lectura)"
    _help_cmd "  " "wifi status"                "NM, antenas, conexiones, internet"
    _help_cmd "  " "wifi version"               "version del stack"
    _help_cmd "  " "sudo wifi clean"            "limpia residuos de instalaciones canceladas"
    _help_cmd "  " "sudo wifi ssh harden"       "hardening SSH (opt-in)"
    _help_cmd "  " "sudo wifi ssh status"       "estado del hardening SSH"
    _help_cmd "  " "sudo wifi ssh revert"       "deshacer hardening SSH"

    _help_cat RADIO "ANTENAS (WiFi, nativa + USB)"
    _help_cmd "  " "wifi radio list"            "tabla: iface, tipo, estado, conexion, rol"
    _help_cmd "  " "sudo wifi radio primary <i>"   "persistente: i pasa a PRIMARY"
    _help_cmd "  " "sudo wifi radio secondary <i>" "persistente: i pasa a SECONDARY"
    _help_cmd "  " "sudo wifi radio use <i>"       "solo esta sesion (no persiste)"
    _help_cmd "  " "sudo wifi radio session clear" "olvida override de sesion"
    _help_cmd "  " "sudo wifi radio up <i>"        "activa la antena"
    _help_cmd "  " "sudo wifi radio down <i>"      "desactiva la antena"

    _help_cat NET "REDES WiFi"
    _help_cmd "  " "sudo wifi scan [--iface X]"    "escaneo: redes visibles ahora"
    _help_cmd "  " "sudo wifi add [<ssid>]"        "crear + conectar (picker fzf)"
    _help_cmd "  " "wifi networks [list]"          "tabla unificada del store de redes"
    _help_cmd "  " "sudo wifi networks pull nm"   "funde perfiles NM al store"
    _help_cmd "  " "sudo wifi networks pull iwd"  "importa las redes conocidas por iwd"
    _help_cmd "  " "sudo wifi networks show <ssid>" "ficha completa de un SSID"
    _help_cmd "  " "sudo wifi networks export <p>" "backup del store a <p>"
    _help_cmd "  " "sudo wifi networks import <p>" "merge desde <p> (aditivo)"
    _help_cmd "  " "sudo wifi networks cleanup"   "elimina filas huerfanas"
    _help_cmd "  " "sudo wifi connect <ssid>"      "cambia al perfil guardado"
    _help_cmd "  " "sudo wifi password set <ssid|perfil>" "cambia PSK + reconecta"
    _help_cmd "  " "sudo wifi password show <profile>" "muestra PSK"
    _help_cmd "  " "sudo wifi profile rename <p> <p2>" "renombra un perfil"
    _help_cmd "  " "sudo wifi priority set <p> <N>" "cambia prioridad de autoconnect"
    _help_cmd "  " "sudo wifi delete <p>"          "borra un perfil"
    _help_cmd "  " "sudo wifi autoconnect set <profile> <on|off>" "autoconnect manual"

    _help_cat MAC "MAC (clonado por perfil)"
    _help_cmd "  " "sudo wifi mac set <profile> <mac|random|stable|permanent>" "clonar MAC"
    _help_cmd "  " "wifi mac show <profile>"       "MAC clonada o permanente"

    _help_cat USB "USB NAMING (MAC -> nombre de iface)"
    _help_cmd "  " "wifi usb status"               "ver mappings y estado de .link"
    _help_cmd "  " "sudo wifi usb apply"           "aplicar mappings (proximo boot)"
    _help_cmd "  " "sudo wifi usb edit"            "editar config/usb-names.conf"


    _help_cat EMERG "FALLBACK (iwd vs NetworkManager)"
    _help_cmd "  " "sudo wifi fallback on"         "pasa a iwd (NM apagado)"
    _help_cmd "  " "sudo wifi fallback off"        "vuelve a NetworkManager"
    _help_cmd "  " "wifi fallback status"          "quien esta al mando"


    printf '\n'
}

# ---------------------------------------------------------------------------
# help_<sub> -- ayuda por subcomando. Una funcion por cada entrada del
# dispatcher en bin/wifi.
# ---------------------------------------------------------------------------

