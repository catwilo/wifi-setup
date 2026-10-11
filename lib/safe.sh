#!/usr/bin/env bash
# lib/safe.sh -- proteccion contra perdida de acceso remoto.
#
# RESPONSABILIDAD UNICA: garantizar que cualquier cambio que pueda cortar
# el acceso SSH se revierta automaticamente si el acceso se pierde.
#
# Mecanismo: snapshot + canary + watchdog + rollback.
#
#   snapshot  guarda el estado de red completo antes del cambio.
#   canary    proceso background que pinguea un nodo externo (tx1 por
#             defecto) cada INTERVAL segundos. Si no responde FAILS veces
#             seguidas, asume que el cambio corto el acceso.
#   watchdog  cuando el canary detecta perdida, restaura el snapshot sin
#             esperar ordenes (porque no puede recibirlas).
#   rollback  restaura perfiles NM, wpa_supplicant, resolv.conf, y
#             reactiva los servicios que estaban activos.
#
# Este modulo es el UNICO autorizado a hacer cambios que afecten la
# conectividad sin confirmacion explicita del usuario.
#
# Requiere: common.sh sourceado antes (STATE_DIR/LOG_DIR/CONFIG_DIR,
# log.sh cargado, die/info/warn/ok disponibles).

SAFE_CANARY_INTERVAL=2
SAFE_CANARY_FAILS=3
SAFE_SNAPSHOTS_DIR="${STATE_DIR}/snapshots"
SAFE_CANARY_PID_FILE="${STATE_DIR}/canary.pid"
SAFE_CANARY_DEFAULT_FILE="${CONFIG_DIR}/canary.default"
SAFE_OPS_LOG="${LOG_DIR}/ops.log"

# ---------------------------------------------------------------------------
# _safe_canary_default -- canary por defecto.
# Prioridad: config persistida > variable de entorno > fallback.
# ---------------------------------------------------------------------------
_safe_canary_default() {
    if [[ -f "${SAFE_CANARY_DEFAULT_FILE}" ]]; then
        cat "${SAFE_CANARY_DEFAULT_FILE}"
        return 0
    fi
    echo "${WIFI_SETUP_CANARY:-100.103.104.19}"
}

# safe_canary_get -- imprime el canary activo.
safe_canary_get() {
    _safe_canary_default
}

# safe_canary_set <ip|alias> -- persiste un nuevo canary default.
safe_canary_set() {
    local new_canary="${1:-}"
    [[ -n "${new_canary}" ]] || die "uso: wifi canary set <ip|alias>"
    mkdir -p "${CONFIG_DIR}"
    printf '%s\n' "${new_canary}" > "${SAFE_CANARY_DEFAULT_FILE}"
    chmod 600 "${SAFE_CANARY_DEFAULT_FILE}"
    ok "canary default: ${new_canary}"
}

# ---------------------------------------------------------------------------
# safe_snapshot <label> -- guarda el estado de red.
# Imprime la ruta del snapshot por stdout.
# ---------------------------------------------------------------------------
safe_snapshot() {
    local label="${1:-manual}"
    local ts; ts="$(date +%Y%m%d-%H%M%S)"
    local dir="${SAFE_SNAPSHOTS_DIR}/${ts}-${label}"
    mkdir -p "${dir}"

    if command -v nmcli >/dev/null 2>&1; then
        nmcli con show > "${dir}/nmcli-con-show.txt" 2>&1 || true
        if [[ -d /etc/NetworkManager/system-connections ]]; then
            mkdir -p "${dir}/nm-system-connections"
            cp -a /etc/NetworkManager/system-connections/. \
                "${dir}/nm-system-connections/" 2>/dev/null || true
        fi
    fi

    if [[ -d /etc/wpa_supplicant ]]; then
        mkdir -p "${dir}/wpa_supplicant"
        cp -a /etc/wpa_supplicant/. "${dir}/wpa_supplicant/" 2>/dev/null || true
    fi

    [[ -f /etc/resolv.conf ]] && cp -a /etc/resolv.conf "${dir}/resolv.conf" 2>/dev/null || true

    ip addr show  > "${dir}/ip-addr.txt"  2>&1 || true
    ip route show > "${dir}/ip-route.txt" 2>&1 || true

    : > "${dir}/services.txt"
    for svc in NetworkManager iwd dhcpcd systemd-networkd wpa_supplicant; do
        printf '%s active=%s enabled=%s\n' \
            "${svc}" \
            "$(systemctl is-active  "${svc}" 2>&1)" \
            "$(systemctl is-enabled "${svc}" 2>&1)" \
            >> "${dir}/services.txt"
    done

    cat > "${dir}/meta.txt" <<META
label=${label}
timestamp=${ts}
host=$(hostname 2>/dev/null || echo unknown)
canary=$(_safe_canary_default)
META

    echo "${dir}"
}

# ---------------------------------------------------------------------------
# safe_rollback <snapshot_dir> -- restaura el estado del snapshot.
# ---------------------------------------------------------------------------
safe_rollback() {
    local dir="${1:-}"
    [[ -d "${dir}" ]] || die "safe_rollback: snapshot no encontrado: ${dir}"
    warn "ROLLBACK -- restaurando desde ${dir}"

    if [[ -d "${dir}/nm-system-connections" ]] \
       && [[ -d /etc/NetworkManager/system-connections ]]; then
        rm -f /etc/NetworkManager/system-connections/*.nmconnection 2>/dev/null || true
        cp -a "${dir}/nm-system-connections/." \
            /etc/NetworkManager/system-connections/ 2>/dev/null || true
        chmod 600 /etc/NetworkManager/system-connections/*.nmconnection 2>/dev/null || true
        nmcli con reload 2>/dev/null || true
    fi

    if [[ -d "${dir}/wpa_supplicant" ]] && [[ -d /etc/wpa_supplicant ]]; then
        cp -a "${dir}/wpa_supplicant/." /etc/wpa_supplicant/ 2>/dev/null || true
    fi

    [[ -f "${dir}/resolv.conf" ]] \
        && cp -a "${dir}/resolv.conf" /etc/resolv.conf 2>/dev/null || true

    if [[ -f "${dir}/services.txt" ]]; then
        local svc line active enabled
        while IFS= read -r line; do
            svc="${line%% *}"
            active="$(printf '%s\n' "${line}" | grep -oE 'active=[^ ]+' || true)"
            enabled="$(printf '%s\n' "${line}" | grep -oE 'enabled=[^ ]+' || true)"
            if [[ "${enabled}" == "enabled=enabled" ]]; then
                systemctl enable "${svc}" 2>/dev/null || true
            fi
            if [[ "${active}" == "active=active" ]]; then
                systemctl start "${svc}" 2>/dev/null || true
            fi
        done < "${dir}/services.txt"
    fi

    systemctl restart NetworkManager 2>/dev/null || true

    ok "rollback aplicado desde ${dir}"
}

# ---------------------------------------------------------------------------
# _safe_canary_watchdog <canary> <fails> <snapshot>
# Corre en background. Pinguea el canary; si falla FAILS veces seguidas,
# dispara rollback y sale.
# ---------------------------------------------------------------------------
_safe_canary_watchdog() {
    local canary="$1" fails="$2" snapshot="$3"
    local consecutive=0

    while true; do
        if ping -c1 -W2 "${canary}" >/dev/null 2>&1; then
            consecutive=0
        else
            consecutive=$((consecutive + 1))
            if [[ "${consecutive}" -ge "${fails}" ]]; then
                printf '[%s] canary LOST (%s fails) -- rollback\n' \
                    "$(date -Iseconds)" "${fails}" >> "${SAFE_OPS_LOG}"
                safe_rollback "${snapshot}" >> "${SAFE_OPS_LOG}" 2>&1 || true
                rm -f "${SAFE_CANARY_PID_FILE}"
                exit 0
            fi
        fi
        sleep "${SAFE_CANARY_INTERVAL}"
    done
}

# safe_canary_start <snapshot> -- arranca el watchdog en background.
safe_canary_start() {
    local snapshot="$1"
    local canary; canary="$(_safe_canary_default)"

    safe_canary_stop

    _safe_canary_watchdog "${canary}" "${SAFE_CANARY_FAILS}" "${snapshot}" &
    echo $! > "${SAFE_CANARY_PID_FILE}"
    disown 2>/dev/null || true
    info "canary: ${canary} (pid $(cat "${SAFE_CANARY_PID_FILE}"))"
}

# safe_canary_stop -- detiene el watchdog si esta corriendo.
safe_canary_stop() {
    if [[ -f "${SAFE_CANARY_PID_FILE}" ]]; then
        local pid; pid="$(cat "${SAFE_CANARY_PID_FILE}" 2>/dev/null || echo)"
        [[ -n "${pid}" ]] && kill "${pid}" 2>/dev/null || true
        rm -f "${SAFE_CANARY_PID_FILE}"
    fi
}

# safe_canary_status -- imprime estado del watchdog.
safe_canary_status() {
    if [[ -f "${SAFE_CANARY_PID_FILE}" ]] \
       && kill -0 "$(cat "${SAFE_CANARY_PID_FILE}" 2>/dev/null)" 2>/dev/null; then
        echo "watchdog activo (pid $(cat "${SAFE_CANARY_PID_FILE}"))"
    else
        echo "watchdog inactivo"
    fi
    echo "canary default: $(_safe_canary_default)"
}

# ---------------------------------------------------------------------------
# safe_run <label> <timeout> <cmd...>
#   Envuelve un comando critico: snapshot + canary + espera + rollback auto.
#   Si el canary se pierde durante <timeout> segundos, el watchdog restaura
#   el estado sin esperar ordenes. Si <timeout> pasa sin perdida, exito.
# ---------------------------------------------------------------------------
safe_run() {
    local label="$1" timeout="$2"
    shift 2
    [[ -n "${label}" ]]   || die "safe_run: label requerido"
    [[ -n "${timeout}" ]] || die "safe_run: timeout requerido"
    [[ "${#}" -gt 0 ]]    || die "safe_run: falta el comando"

    local snap; snap="$(safe_snapshot "${label}")"
    info "snapshot: ${snap}"

    printf '[%s] BEGIN %s timeout=%ss snapshot=%s\n' \
        "$(date -Iseconds)" "${label}" "${timeout}" "${snap}" >> "${SAFE_OPS_LOG}"

    safe_canary_start "${snap}"

    local rc=0
    "$@" || rc=$?

    if [[ "${rc}" -ne 0 ]]; then
        warn "comando fallo (rc=${rc}) -- parando canary"
        safe_canary_stop
        printf '[%s] END %s rc=%s (abort)\n' \
            "$(date -Iseconds)" "${label}" "${rc}" >> "${SAFE_OPS_LOG}"
        return "${rc}"
    fi

    info "esperando ${timeout}s para confirmar acceso..."
    local waited=0 pid
    while [[ "${waited}" -lt "${timeout}" ]]; do
        pid="$(cat "${SAFE_CANARY_PID_FILE}" 2>/dev/null || echo)"
        if [[ -z "${pid}" ]] || ! kill -0 "${pid}" 2>/dev/null; then
            warn "watchdog termino -- rollback se ejecuto"
            printf '[%s] END %s ROLLBACK\n' \
                "$(date -Iseconds)" "${label}" >> "${SAFE_OPS_LOG}"
            return 1
        fi
        sleep 2
        waited=$((waited + 2))
    done

    safe_canary_stop
    ok "${label} OK -- acceso confirmado (${timeout}s)"
    printf '[%s] END %s OK\n' \
        "$(date -Iseconds)" "${label}" >> "${SAFE_OPS_LOG}"
    return 0
}

# safe_log -- imprime el historico de operaciones con numeros de linea.
safe_log() {
    if [[ -f "${SAFE_OPS_LOG}" ]]; then
        cat -n "${SAFE_OPS_LOG}"
    else
        echo "sin operaciones registradas"
    fi
}

# safe_snapshots_list -- lista snapshots disponibles.
safe_snapshots_list() {
    if [[ -d "${SAFE_SNAPSHOTS_DIR}" ]]; then
        find "${SAFE_SNAPSHOTS_DIR}" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' \
            | sort
    else
        echo "sin snapshots"
    fi
}
