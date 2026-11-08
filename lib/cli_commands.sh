# shellcheck shell=bash
# lib/cli_commands.sh -- cuerpo de los _cmd_* de bin/wifi.
# Requiere: preamble de bin/wifi (_load, _maybe_help, _die) + lib/*.sh.

# --- dispatch de subcomandos ------------------------------------------
# Cada _cmd_*: _maybe_help + parseo de flags + _load + require_root + llamada.

_cmd_status() {
    _maybe_help status "$@"
    _load nm radio status
    status_run
}

_cmd_radio() {
    _maybe_help radio "$@"
    local sub="${1:-}"; shift || true
    [[ -n "${sub}" ]] || _die "uso: wifi radio <list|primary|secondary|use|clear-session|up|down> [args]"
    _load nm radio networks
    require_root
    case "${sub}" in
        boot) radio_boot ;;
        session)
            local ssub="${1:-}"; shift || true
            case "${ssub}" in
                clear) radio_clear_session ;;
                *) _die "uso: wifi radio session <clear>" ;;
            esac
            ;;
        *)
            nm_require
            case "${sub}" in
                list)      radio_list ;;
                primary)   radio_set_primary   "${1:-}" ;;
                secondary) radio_set_secondary "${1:-}" ;;
                use)       radio_use           "$@" ;;
                up)        radio_up            "$@" ;;
                down)      radio_down          "$@" ;;
                *) _die "subcomando desconocido: ${sub}" ;;
            esac
            ;;
    esac
}

_cmd_add() {
    _maybe_help add "$@"
    local ssid="" iface="" pass=""
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --iface) iface="${2:-}"; shift 2 ;;
            --pass)  pass="${2:-}";  shift 2 ;;
            -h|--help)
                echo "uso: wifi add [<ssid>] [--iface X] [--pass P]"
                echo ""
                echo "Crea un perfil WiFi y se conecta de inmediato."
                echo "Sin <ssid> y con fzf + wifi scan previo, abre un picker."
                echo "Sin --iface usa la antena PRIMARY (o la unica disponible)."
                echo "Sin --pass pide la PSK interactivo (min 8 caracteres)."
                exit 0 ;;
            *)
                if [[ -z "${ssid}" ]]; then ssid="$1"
                else _die "argumento inesperado: $1"; fi
                shift ;;
        esac
    done
    _load nm radio networks profiles
    require_root
    [[ -n "${ssid}" ]] || ssid="$(profile_pick_ssid || true)"
    [[ -n "${ssid}" ]] || _die "uso: wifi add [<ssid>] [--iface X] [--pass P]"
    profile_add "${ssid}" "${iface}" "${pass}"
}

_cmd_networks() {
    _maybe_help networks "$@"
    local sub="${1:-list}"; shift || true
    _load nm radio networks
    require_root
    case "${sub}" in
        list|"") nm_require; networks_list "$@" ;;
        show)    nm_require; networks_show "${1:-}" ;;
        pull)
            local pull_dst="${1:-}"
            case "${pull_dst}" in
                nm)  nm_require; networks_pull_nm ;;
                iwd) networks_pull_iwd ;;
                *) _die "uso: wifi networks pull <nm|iwd>" ;;
            esac
            ;;
        export)  networks_export "${1:-}" ;;
        import)  networks_import "${1:-}" ;;
        cleanup) nm_require; networks_cleanup ;;
        *) _die "uso: wifi networks <list|show|pull <nm|iwd>|export|import|cleanup>" ;;
    esac
}

_cmd_connect() {
    _maybe_help connect "$@"
    _load nm radio
    nm_require
    require_root
    local ssid="${1:-}" iface="${2:-}"
    [[ -n "${ssid}" ]] || _die "uso: wifi connect <ssid> [iface]"
    if [[ -z "${iface}" ]]; then
        _radio_load_state
        iface="${RADIO_PRIMARY:-$(radio_ifaces | head -1)}"
    fi
    local profile="wifi-${iface}-${ssid}"
    nm_con_exists "${profile}" \
        || _die "perfil '${profile}' no existe -- usa: wifi add ${ssid} --iface ${iface}"
    info "conectando ${iface}..."
    local up_rc=0
    nm_device_connect "${iface}" || up_rc=$?
    if [[ "${up_rc}" -eq 0 ]]; then
        ok "conectado via ${iface}"
    else
        err "no se pudo conectar via ${iface} (rc=${up_rc})"
    fi
}

_cmd_password() {
    _maybe_help password "$@"
    local sub="${1:-}"; shift || true
    _load nm networks profiles
    require_root
    case "${sub}" in
        set)
            nm_require
            local target="" pass=""
            while [[ "$#" -gt 0 ]]; do
                case "$1" in
                    --pass) pass="${2:-}"; shift 2 ;;
                    -h|--help)
                        echo "uso: wifi password set <profile|ssid> [--pass P]"
                        exit 0 ;;
                    *)
                        if [[ -z "${target}" ]]; then target="$1"
                        else _die "argumento inesperado: $1"; fi
                        shift ;;
                esac
            done
            [[ -n "${target}" ]] || _die "uso: wifi password set <profile|ssid> [--pass P]"
            profile_password_set "${target}" "${pass}"
            ;;
        show)
            local target="${1:-}"
            [[ -n "${target}" ]] || _die "uso: wifi password show <perfil|ssid>"
            profile_password_show "${target}"
            ;;
        *) _die "uso: wifi password <set|show> [args]" ;;
    esac
}

_cmd_priority() {
    _maybe_help priority "$@"
    local sub="${1:-}"; shift || true
    case "${sub}" in
        set)
            _load nm networks profiles
            nm_require; require_root
            local target="${1:-}" prio="${2:-}"
            [[ -n "${target}" && -n "${prio}" ]] || _die "uso: wifi priority set <perfil|ssid> <N>"
            profile_priority_set "${target}" "${prio}"
            ;;
        *) _die "uso: wifi priority set <perfil|ssid> <N>" ;;
    esac
}

_cmd_autoconnect() {
    _maybe_help autoconnect "$@"
    local sub="${1:-}"; shift || true
    case "${sub}" in
        set)
            _load nm networks profiles
            nm_require; require_root
            local profile="${1:-}" mode="${2:-}"
            [[ -n "${profile}" && -n "${mode}" ]] || _die "uso: wifi autoconnect set <perfil> <on|off>"
            profile_autoconnect_set "${profile}" "${mode}"
            ;;
        *) _die "uso: wifi autoconnect set <perfil> <on|off>" ;;
    esac
}

_cmd_mac() {
    _maybe_help mac "$@"
    local sub="${1:-}"; shift || true
    _load nm
    nm_require
    require_root
    case "${sub}" in
        set)
            local profile="${1:-}" mac="${2:-}"
            [[ -n "${profile}" && -n "${mac}" ]] || _die "uso: wifi mac set <profile> <mac|random|stable|permanent>"
            nm_con_exists "${profile}" || _die "perfil '${profile}' no existe"
            case "$(nm_con_get "${profile}" connection.type)" in
                802-11-wireless) nm_con_set_mac_wifi "${profile}" "${mac}" ;;
                802-3-ethernet)  nm_con_set_mac      "${profile}" "${mac}" ;;
                *) _die "tipo de perfil no soportado" ;;
            esac
            ok "MAC de '${profile}' -> ${mac}"
            ;;
        show)
            local profile="${1:-}"
            [[ -n "${profile}" ]] || _die "uso: wifi mac show <profile>"
            local type mac
            type="$(nm_con_get "${profile}" connection.type)"
            case "${type}" in
                802-11-wireless) mac="$(nm_con_get "${profile}" 802-11-wireless.cloned-mac-address)" ;;
                802-3-ethernet)  mac="$(nm_con_get "${profile}" 802-3-ethernet.cloned-mac-address)"  ;;
            esac
            echo "perfil : ${profile}"
            echo "cloned-mac-address : ${mac:-permanent}"
            ;;
        *) _die "uso: wifi mac <set|show> [args]" ;;
    esac
}

_cmd_profile() {
    _maybe_help profile "$@"
    local sub="${1:-}"; shift || true
    case "${sub}" in
        rename)
            _load nm networks profiles
            nm_require; require_root
            local old="${1:-}" new="${2:-}"
            [[ -n "${old}" && -n "${new}" ]] || _die "uso: wifi profile rename <perfil-actual> <perfil-nuevo>"
            profile_rename "${old}" "${new}"
            ;;
        *) _die "uso: wifi profile rename <perfil-actual> <perfil-nuevo>" ;;
    esac
}

_cmd_delete() {
    _maybe_help delete "$@"
    _load nm networks profiles
    nm_require
    require_root
    local target="${1:-}"
    [[ -n "${target}" ]] || _die "uso: wifi delete <perfil|ssid>"
    profile_delete "${target}"
}

_cmd_usb() {
    _maybe_help usb "$@"
    local sub="${1:-}"; shift || true
    _load nm
    require_root
    local cfg="${CONFIG_DIR}/usb-names.conf"
    [[ -f "${cfg}" ]] || cfg="${LIB_DIR}/../config/usb-names.conf"
    case "${sub}" in
        status|"")
            echo "usb-names.conf: ${cfg}"
            echo ""
            nm_usb_names_status "${cfg}"
            ;;
        apply)  nm_usb_names_apply "${cfg}" ;;
        edit)
            [[ -f "${cfg}" ]] || _die "no existe ${cfg} -- corre: sudo bash ${SCRIPTS_DIR}/install.sh primero"
            "${EDITOR:-vi}" "${cfg}"
            info "re-aplica con: wifi usb-names apply"
            ;;
        *) _die "uso: wifi usb-names <status|apply|edit>" ;;
    esac
}

_cmd_scan() {
    _maybe_help scan "$@"
    _load nm radio scan
    nm_require
    require_root
    scan_run "$@"
}

_cmd_fallback() {
    _maybe_help fallback "$@"
    local sub="${1:-status}"; shift || true
    _load nm radio networks fallback
    case "${sub}" in
        on)        require_root; fallback_on ;;
        off)       require_root; fallback_off ;;
        status|"") fallback_status ;;
        *) _die "uso: wifi fallback <on|off|status>" ;;
    esac
}

_cmd_ssh() {
    _maybe_help ssh "$@"
    local sub="${1:-status}"; shift || true
    _load ssh
    case "${sub}" in
        harden)  require_root; ssh_harden ;;
        revert)  require_root; ssh_revert ;;
        status|"") ssh_status ;;
        *) _die "uso: wifi ssh <harden|status|revert>" ;;
    esac
}

_cmd_clean() {
    _maybe_help clean "$@"
    _load clean
    require_root
    wifi_clean
}

_cmd_version() {
    echo "wifi-setup 2.0 (NetworkManager backbone)"
}

_cmd_help() {
    _load_help
    help_index
}
