# shellcheck shell=bash
# lib/profiles.sh -- operaciones de usuario sobre perfiles WiFi.
# CRUD + password + tuning. No habla nmcli directo: usa nm.sh (wrappers)
# + networks.sh (store). Una sola responsabilidad.

# profile_resolve <profile|ssid> -- imprime el nombre del perfil NM.
profile_resolve() {
    local arg="$1" name ssid
    if nm_con_exists "${arg}"; then
        printf '%s\n' "${arg}"
        return 0
    fi
    # Tolerante a comillas: un perfil creado con '"Familia_Mora"' (bug de
    # picker pre-878ded0) se puede referenciar como 'Familia_Mora' para
    # que wifi delete/showpass/etc. lo limpien sin intervencion manual.
    local arg_stripped; arg_stripped="$(_profile_strip_ssid_quotes "${arg}")"
    while IFS= read -r name; do
        [[ -n "${name}" ]] || continue
        ssid="$(nmcli -t -g 802-11-wireless.ssid con show "${name}" 2>/dev/null || true)"
        if [[ "${ssid}" == "${arg}" ]] \
           || [[ "$(_profile_strip_ssid_quotes "${ssid}")" == "${arg_stripped}" ]]; then
            printf '%s\n' "${name}"
            return 0
        fi
    done < <(nmcli -t -f NAME,TYPE con show 2>/dev/null \
        | awk -F: '$2=="802-11-wireless"{print $1}')
    return 1
}

# _profile_strip_ssid_quotes <line> -- quita comillas dobles envolventes.
# scan.sh escribe last-scan.txt con printf '"%s"' para hacer visibles
# los espacios al inicio/fin; el picker fzf devuelve la linea con esas
# comillas y hay que despojarlas antes de usar el SSID como nombre real.
# Solo quita UNA comilla de cada extremo (no un strip global, para no
# romper SSIDs que las contengan internas).
_profile_strip_ssid_quotes() {
    local s="$1"
    if [[ "${#s}" -ge 2 && "${s:0:1}" == '"' && "${s: -1}" == '"' ]]; then
        s="${s:1:${#s}-2}"
    fi
    printf '%s' "${s}"
}

# profile_pick_ssid -- picker fzf sobre el ultimo scan guardado.
# Devuelve el SSID SIN las comillas envolventes que usa last-scan.txt.
profile_pick_ssid() {
    local cache="${STATE_DIR}/last-scan.txt"
    command -v fzf >/dev/null 2>&1 || return 0
    if [[ ! -s "${cache}" ]]; then
        warn "no hay escaneo previo -- corre 'wifi scan' para el picker fzf"
        return 0
    fi
    local picked
    picked="$(fzf --prompt='SSID> ' --height=40% < "${cache}")" || return 0
    [[ -n "${picked}" ]] || return 0
    _profile_strip_ssid_quotes "${picked}"
}

# profile_add <ssid> <iface> <pass> -- crear perfil (DB + NM + iwd) y
# conectar si NM corre. iface/pass vacios se resuelven aqui.
profile_add() {
    local ssid="$1" iface="$2" pass="$3"
    if [[ "${ssid}" =~ ^[[:space:]] || "${ssid}" =~ [[:space:]]$ ]]; then
        warn "el SSID tiene espacios al inicio o al final: '${ssid}'"
        warn "esto crea un perfil con espacios en el nombre (dificil de distinguir)"
        local _ans
        read -r -p "continuar igual? [s/N]: " _ans
        [[ "${_ans}" =~ ^[sS]$ ]] || die "cancelado"
    fi
    if [[ -z "${iface}" ]]; then
        _radio_load_state
        iface="${RADIO_PRIMARY:-$(radio_ifaces | head -1)}"
        [[ -n "${iface}" ]] || die "no hay antenas WiFi -- verifica hardware"
    fi
    radio_is_iface "${iface}" || die "'${iface}' no es WiFi"
    if [[ -z "${pass}" ]]; then
        IFS= read -r -s -p "PSK para '${ssid}' (min 8): " pass
        echo
    fi
    [[ "${#pass}" -ge 8 ]] || die "PSK minimo 8 caracteres"

    _networks_store_upsert "${ssid}" "${pass}" "${iface}" "yes" "0"
    networks_apply
    ok "red '${ssid}' agregada en ${iface} (DB + NM + iwd, autoconnect=yes)"

    if systemctl is-active NetworkManager >/dev/null 2>&1; then
        local profile="wifi-${iface}-${ssid}"
        info "intentando conectar a '${ssid}'..."
        local up_rc=0
        nm_con_up "${profile}" || up_rc=$?
        if [[ "${up_rc}" -eq 0 ]]; then
            ok "conectado a '${ssid}' via ${iface}"
        else
            err "no se pudo conectar a '${ssid}' (rc=${up_rc})"
            err "revisa: wifi status | wifi showpass '${profile}'"
        fi
    else
        info "NM no activo -- red guardada en la DB"
    fi
}

# profile_password_set <target> <pass> -- cambiar PSK en DB + backends y
# reconectar. pass vacio -> prompt interactivo.
profile_password_set() {
    local target="$1" pass="$2"
    [[ -n "${target}" ]] || die "uso: wifi password set <profile|ssid> [--pass P]"
    local profile
    profile="$(profile_resolve "${target}")" \
        || die "no hay perfil para '${target}' -- usa: wifi networks"
    if [[ -z "${pass}" ]]; then
        IFS= read -r -s -p "nuevo PSK para '${profile}' (min 8): " pass
        echo
    fi
    [[ "${#pass}" -ge 8 ]] || die "minimo 8 caracteres"

    local ssid
    ssid="$(nmcli -t -g 802-11-wireless.ssid con show "${profile}" 2>/dev/null | head -1 || true)"
    [[ -n "${ssid}" ]] || ssid="${target}"
    _networks_store_init
    if ! _networks_store_update_field "${ssid}" "*" psk "${pass}"; then
        local iface
        iface="$(nm_con_get "${profile}" connection.interface-name 2>/dev/null | head -1 || true)"
        _networks_store_upsert "${ssid}" "${pass}" "${iface:-}" "yes" "0"
    fi
    info "PSK de '${ssid}' actualizada en la DB"
    networks_apply
    ok "PSK actualizada en DB + NM + iwd"
    if systemctl is-active NetworkManager >/dev/null 2>&1; then
        info "reconectando '${profile}'..."
        local up_rc=0
        nm_con_up "${profile}" || up_rc=$?
        if [[ "${up_rc}" -eq 0 ]]; then
            ok "reconectado con la nueva PSK"
        else
            err "PSK actualizada, pero no reconecto (rc=${up_rc})"
        fi
    fi
}

# profile_password_show <target> -- PSK en claro. Precedencia:
# NM (si corre) > DB > iwd.
profile_password_show() {
    local target="$1"
    [[ -n "${target}" ]] || die "uso: wifi password show <perfil|ssid>"
    if systemctl is-active NetworkManager >/dev/null 2>&1 && nm_con_exists "${target}" 2>/dev/null; then
        local psk
        psk="$(nmcli -s -g 802-11-wireless-security.psk con show "${target}" 2>/dev/null | head -1 || true)"
        if [[ -n "${psk}" ]]; then
            printf 'perfil : %s\nfuente : NM\npsk    : %s\n' "${target}" "${psk}"
            return 0
        fi
    fi
    local db_psk
    db_psk="$(_networks_psk_for_ssid "${target}" || true)"
    if [[ -n "${db_psk}" ]]; then
        printf 'ssid   : %s\nfuente : DB\npsk    : %s\n' "${target}" "${db_psk}"
        return 0
    fi
    if [[ -r "${IWD_DIR}/${target}.psk" ]]; then
        local iwd_psk
        iwd_psk="$(_iwd_psk_for_ssid "${target}" || true)"
        if [[ -n "${iwd_psk}" ]]; then
            printf 'ssid   : %s\nfuente : iwd\npsk    : %s\n' "${target}" "${iwd_psk}"
            return 0
        fi
    fi
    die "no encontrado: '${target}' (ni como perfil NM, ni en la DB, ni en iwd)"
}

# profile_rename <old> <new> -- renombrar perfil NM. UUID, PSK, MAC y
# prioridad se preservan. Advierte si rompe wifi-<iface>-<ssid>.
profile_rename() {
    local old="$1" new="$2"
    [[ -n "${old}" && -n "${new}" ]] || die "uso: wifi profile rename <perfil-actual> <perfil-nuevo>"
    nm_con_exists "${old}" || die "perfil '${old}' no existe"
    if nm_con_exists "${new}"; then
        die "ya existe un perfil llamado '${new}'"
    fi
    local _iface _ssid
    _iface="$(nm_con_get "${old}" connection.interface-name 2>/dev/null | head -1 || true)"
    _ssid="$(nmcli -t -g 802-11-wireless.ssid con show "${old}" 2>/dev/null | head -1 || true)"
    if [[ -n "${_iface}" && -n "${_ssid}" ]]; then
        local expected="wifi-${_iface}-${_ssid}"
        if [[ "${new}" != "${expected}" ]]; then
            warn "renombrar a '${new}' rompe el patron wifi-<iface>-<ssid>"
            warn "el proximo 'wifi networks sync' puede recrear '${expected}'"
            local _ans
            read -r -p "continuar de todos modos? [s/N]: " _ans
            [[ "${_ans}" =~ ^[sS]$ ]] || die "cancelado"
        fi
    fi
    nmcli con mod "${old}" connection.id "${new}" >/dev/null
    ok "perfil renombrado: ${old} -> ${new}"
    info "la DB (indexada por ssid) no cambia"
}

# profile_priority_set <target> <N> -- prioridad autoconnect en NM y DB.
profile_priority_set() {
    local target="$1" prio="$2"
    [[ -n "${target}" && -n "${prio}" ]] || die "uso: wifi priority set <perfil|ssid> <N>"
    [[ "${prio}" =~ ^[0-9]+$ ]] || die "prioridad debe ser un numero entero (0..999)"
    local profile
    profile="$(profile_resolve "${target}")" \
        || die "no hay perfil para '${target}'"
    nm_con_set_priority "${profile}" "${prio}"
    ok "prioridad de '${profile}' = ${prio}"
    local ssid
    ssid="$(nmcli -t -g 802-11-wireless.ssid con show "${profile}" 2>/dev/null | head -1 || true)"
    if [[ -n "${ssid}" && -f "${NETWORKS_STORE}" ]]; then
        if _networks_store_update_field "${ssid}" "*" priority "${prio}"; then
            info "DB actualizada (SSID '${ssid}')"
        else
            warn "DB: SSID '${ssid}' no esta en el store (NM y DB desincronizados)"
        fi
    fi
}

# profile_delete <target> -- borrar perfil NM + filas del SSID en DB.
profile_delete() {
    local target="$1"
    [[ -n "${target}" ]] || die "uso: wifi delete <perfil|ssid>"
    local profile
    profile="$(profile_resolve "${target}")" \
        || die "no hay perfil para '${target}' -- usa: wifi networks"
    local ssid
    ssid="$(nmcli -t -g 802-11-wireless.ssid con show "${profile}" 2>/dev/null | head -1 || true)"
    nm_con_delete "${profile}"
    ok "perfil borrado: ${profile}"
    if [[ -n "${ssid}" ]]; then
        _networks_store_delete "${ssid}"
        info "DB: filas del SSID '${ssid}' eliminadas"
    fi
}

# profile_autoconnect_set <profile> <on|off> -- autoconnect en NM y en
# la fila (ssid, iface) de la DB para que sync no lo revierta.
profile_autoconnect_set() {
    local profile="$1" mode="$2"
    [[ -n "${profile}" && -n "${mode}" ]] || die "uso: wifi autoconnect set <profile> <on|off>"
    nm_con_exists "${profile}" || die "perfil '${profile}' no existe"
    local db_mode
    case "${mode}" in
        on|yes)   db_mode="yes" ;;
        off|no)   db_mode="no" ;;
        *) die "modo invalido: '${mode}' (on|off)" ;;
    esac
    nm_con_set_autoconnect "${profile}" "${db_mode}"
    local ssid iface
    ssid="$(nmcli -t -g 802-11-wireless.ssid con show "${profile}" 2>/dev/null | head -1 || true)"
    iface="$(nm_con_get "${profile}" connection.interface-name 2>/dev/null | head -1 || true)"
    if [[ -n "${ssid}" && -n "${iface}" && -f "${NETWORKS_STORE}" ]]; then
        if ! _networks_store_update_field "${ssid}" "${iface}" autoconnect "${db_mode}"; then
            warn "DB: fila (${ssid}, ${iface}) no esta en el store"
        fi
    fi
    ok "${profile} autoconnect=${db_mode} (NM + DB)"
}
