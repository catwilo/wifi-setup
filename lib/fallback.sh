#!/usr/bin/env bash
# lib/fallback.sh -- alterna entre NetworkManager (backbone) e iwd (fallback).
#
# RESPONSABILIDAD UNICA: apagar limpiamente NetworkManager y dejar iwd al
# mando con DHCP integrado, o revertir exactamente ese cambio.
#
# MODELO:
#   - fallback on:     para + enmascara NM, activa DHCP integrado de iwd
#                      (EnableNetworkConfiguration=true en /etc/iwd/main.conf),
#                      arranca + habilita iwd.
#   - fallback off:    para iwd, desenmascara + arranca NM.
#   - fallback status: reporta quien esta al mando ahora.
#
# Persistencia: STATE_DIR/fallback.state guarda el estado previo al "on"
# para que "off" restaure el estado original sin asumir nada.
#
# DHCP: iwd hace DHCP por si mismo cuando EnableNetworkConfiguration=true;
# no se necesita dhcpcd ni NM corriendo. Al volver a NM, NM toma su DHCP.
#
# Los perfiles NM NO se tocan: cuando NM vuelve, reconecta solo con ellos.
# iwd no ve esos perfiles; al arrancar por primera vez pide credenciales
# (iwctl) o espera configuracion. No se pierden credenciales.
#
# Requiere: common.sh + log.sh cargados antes.

FALLBACK_STATE="${STATE_DIR}/fallback.state"

# _fallback_svc_snapshot <svc> -- "active=X enabled=Y" compacto.
_fallback_svc_snapshot() {
    local svc="$1" active enabled
    active="$(systemctl is-active  "${svc}" 2>/dev/null || true)"
    enabled="$(systemctl is-enabled "${svc}" 2>/dev/null || true)"
    printf 'active=%s enabled=%s\n' "${active:-unknown}" "${enabled:-unknown}"
}

# _fallback_ensure_iwd_netconf -- garantiza que iwd haga DHCP por si mismo
# (sin dhcpcd ni NM corriendo). Escribe /etc/iwd/main.conf con la directiva
# EnableNetworkConfiguration=true. Idempotente: solo toca el archivo si
# falta la directiva. Preserva el resto de la config del usuario.
_fallback_ensure_iwd_netconf() {
    local conf="/etc/iwd/main.conf"
    local tmp
    mkdir -p /etc/iwd
    tmp="$(mktemp "${conf}.XXXXXX")"

    # Reescribe main.conf COMPLETO de forma atomica. Motivo: 'fallback on'
    # dos veces seguidas dejaba dos secciones [General] (la primera vacia);
    # iwd lee solo la primera y descarta la segunda, perdiendo
    # EnableNetworkConfiguration -> DHCP integrado apagado -> usuario
    # forzado a dhcpcd manual.
    #
    # Algoritmo: parsear bloques [Seccion]; eliminar toda clave gestionada
    # (donde este); eliminar secciones gestionadas que queden vacias;
    # agregar el bloque canonico UNA vez al final; escribir atomico.
    python3 - "${conf}" "${tmp}" <<'PY_IWD_CONF'
import os, sys

src, dst = sys.argv[1], sys.argv[2]
MANAGED = {"EnableNetworkConfiguration", "NameResolvingService", "DefaultInterface"}
SECTIONS = {"General", "Network", "DriverQuirks"}

blocks = []
cur_name, cur_lines = None, []
if os.path.exists(src):
    with open(src, "r", encoding="utf-8", errors="replace") as f:
        for raw in f:
            line = raw.rstrip("\n")
            s = line.strip()
            if s.startswith("[") and s.endswith("]"):
                if cur_name is not None or cur_lines:
                    blocks.append((cur_name, cur_lines))
                cur_name, cur_lines = s[1:-1].strip(), []
            else:
                cur_lines.append(line)
    if cur_name is not None or cur_lines:
        blocks.append((cur_name, cur_lines))

kept = []
for name, lines in blocks:
    if name in SECTIONS:
        lines = [
            l for l in lines
            if l.strip() and l.strip().split("=", 1)[0].strip() not in MANAGED
        ]
        if not any(l.strip() for l in lines):
            continue
    kept.append((name, lines))

kept.append(("General", ["EnableNetworkConfiguration=true"]))
kept.append(("Network", ["NameResolvingService=none"]))
kept.append(("DriverQuirks", ["DefaultInterface=?*"]))

with open(dst, "w", encoding="utf-8") as f:
    for name, lines in kept:
        if name is not None:
            f.write("[%s]\n" % name)
        for l in lines:
            f.write(l + "\n")
PY_IWD_CONF

    if [[ ! -s "${tmp}" ]]; then
        rm -f "${tmp}"
        err "iwd: no se pudo generar main.conf canonico"
        return 1
    fi
    chmod 644 "${tmp}"
    if [[ -f "${conf}" ]] && cmp -s "${tmp}" "${conf}"; then
        rm -f "${tmp}"
        ok "iwd: main.conf ya canonico (sin cambios)"
        return 0
    fi
    mv "${tmp}" "${conf}"
    ok "iwd: main.conf canonico (un solo bloque por clave)"
    return 0
}

# _fallback_wait_ip <timeout-s> -- espera a que alguna antena WiFi tenga IP.
# Verboso: en cada ciclo imprime el estado de cada antena (ip link state,
# nmcli dev status, a que red intenta conectar y si esta activa). Best-effort:
# no aborta si vence el timeout.
_fallback_wait_ip() {
    local timeout="${1:-30}" waited=0 ip w
    info "esperando IP en alguna antena WiFi (max ${timeout}s)..."
    printf '  %-10s %-12s %-16s %s\n' "IFACE" "STATE" "CONN" "IP" >&2
    while [[ "${waited}" -lt "${timeout}" ]]; do
        for w in /sys/class/net/*/wireless; do
            [[ -d "${w}" ]] || continue
            w="${w%/wireless}"; w="${w##*/}"
            local state conn
            state="$(nmcli -t -f DEVICE,STATE dev status 2>/dev/null \
                | awk -F: -v i="${w}" '$1==i {print $2; exit}')"
            conn="$(nmcli -t -f DEVICE,CONNECTION dev status 2>/dev/null \
                | awk -F: -v i="${w}" '$1==i {print $2; exit}')"
            ip="$(ip -4 -o addr show "${w}" 2>/dev/null | awk '{print $4}' | head -1)"
            printf '  %-10s %-12s %-16s %s\n' \
                "${w}" "${state:-?}" "${conn:-—}" "${ip:-—}" >&2
            if [[ -n "${ip}" ]]; then
                ok "IP asignada: ${w} ${ip}"
                return 0
            fi
        done
        sleep 3
        waited=$((waited + 3))
    done
    warn "ninguna antena obtuvo IP en ${timeout}s"

    # Diagnostico final: que perfiles existen, cuales estan activos, y
    # que dice NM sobre intentos fallidos.
    echo "" >&2
    info "perfiles NM conocidos:"
    nmcli -t -f NAME,TYPE con show 2>&1 | grep '802-11-wireless' >&2 || true
    echo "" >&2
    info "intentos fallidos (ultimos 5):"
    nmcli -f GENERAL.STATE,GENERAL.CONNECTION dev show 2>&1 | grep -E 'GENERAL\.' >&2 || true
    return 1
}

# fallback_status -- quien esta al mando.
fallback_status() {
    section "Fallback (iwd vs NetworkManager)"
    printf '  NetworkManager : %s\n' "$(_fallback_svc_snapshot NetworkManager)"
    printf '  iwd            : %s\n' "$(_fallback_svc_snapshot iwd)"

    local mode="?"
    if systemctl is-active iwd >/dev/null 2>&1; then
        mode="iwd (fallback)"
    elif systemctl is-active NetworkManager >/dev/null 2>&1; then
        mode="NetworkManager (backbone)"
    else
        mode="ninguno (sin gestor WiFi activo)"
    fi
    ok "gestor activo: ${mode}"

    if [[ -f "${FALLBACK_STATE}" ]]; then
        info "state previo guardado en ${FALLBACK_STATE}:"
        if [[ -r "${FALLBACK_STATE}" ]]; then
            while IFS= read -r _line; do
                printf '    %s\n' "${_line}"
            done < "${FALLBACK_STATE}"
        else
            printf '    (ilegible sin root -- corre: sudo cat %s)\n' "${FALLBACK_STATE}"
        fi
    fi
}

# fallback_on -- apagar NM, dejar iwd al mando con DHCP integrado.
fallback_on() {
    # Asegurar config de iwd SIEMPRE, incluso si ya estamos en fallback:
    # asi un 'wifi fallback on' repara el archivo si le falta algo
    # (por ejemplo, quitar un DefaultInterface=true invalido que un sed
    # manual pudo haber dejado).
    _fallback_ensure_iwd_netconf

    if systemctl is-active iwd >/dev/null 2>&1 \
       && ! systemctl is-active NetworkManager >/dev/null 2>&1; then
        ok "ya estas en fallback (iwd activo, NM parado)"
        info "reincidiendo iwd para aplicar cualquier cambio de config..."
        systemctl restart iwd 2>/dev/null || true
        _fallback_wait_ip 30 || true
        return 0
    fi

    mkdir -p "${STATE_DIR}"
    {
        printf 'NM_ACTIVE_BEFORE=%s\n'  "$(systemctl is-active  NetworkManager 2>/dev/null || true)"
        printf 'NM_ENABLED_BEFORE=%s\n' "$(systemctl is-enabled NetworkManager 2>/dev/null || true)"
        printf 'IWD_ACTIVE_BEFORE=%s\n' "$(systemctl is-active iwd 2>/dev/null || true)"
        printf 'IWD_ENABLED_BEFORE=%s\n' "$(systemctl is-enabled iwd 2>/dev/null || true)"
    } > "${FALLBACK_STATE}"
    chmod 600 "${FALLBACK_STATE}"

    section "Cambiando a iwd (fallback)"

    info "parando NetworkManager..."
    systemctl stop NetworkManager 2>/dev/null || true
    info "enmascarando NetworkManager (evita autostart en boot)..."
    systemctl mask NetworkManager 2>/dev/null || true

    info "habilitando iwd..."
    systemctl unmask iwd 2>/dev/null || true
    systemctl enable iwd 2>/dev/null || true
    info "arrancando iwd..."
    systemctl restart iwd 2>/dev/null || true

    if ! systemctl is-active iwd >/dev/null 2>&1; then
        err "iwd no arranco -- revisa: journalctl -u iwd -n 40"
        warn "para volver atras: wifi fallback off"
        return 1
    fi
    ok "iwd activo -- es el gestor WiFi ahora"

    _fallback_wait_ip 30 || true

    info "conecta con: iwctl station <iface> connect <ssid>"
    info "scan con:    iwctl station <iface> scan"
}

# fallback_off -- volver a NetworkManager (backbone).
fallback_off() {
    if systemctl is-active NetworkManager >/dev/null 2>&1 \
       && ! systemctl is-active iwd >/dev/null 2>&1; then
        ok "ya estas en NetworkManager (iwd parado)"
        return 0
    fi

    section "Volviendo a NetworkManager (backbone)"

    # Importar antes de parar iwd: las redes que el usuario conocio via
    # iwctl viven en /var/lib/iwd/*.psk. Se agregan a la DB ahora (solo
    # lee archivos + escribe TSV, no usa NM). Los perfiles NM se crean
    # despues de arrancar NM (networks_sync usa nmcli, que necesita NM
    # corriendo).
    if command -v iwctl >/dev/null 2>&1; then
        info "importando redes conocidas por iwd a la DB..."
        networks_pull_iwd
    fi

    info "parando iwd..."
    systemctl stop iwd 2>/dev/null || true
    info "deshabilitando iwd..."
    systemctl disable iwd 2>/dev/null || true

    info "desenmascarando NetworkManager..."
    systemctl unmask NetworkManager 2>/dev/null || true
    info "habilitando NetworkManager..."
    systemctl enable NetworkManager 2>/dev/null || true
    info "arrancando NetworkManager..."
    systemctl restart NetworkManager 2>/dev/null || true

    if ! systemctl is-active NetworkManager >/dev/null 2>&1; then
        err "NetworkManager no arranco -- revisa: journalctl -u NetworkManager -n 40"
        return 1
    fi
    ok "NetworkManager activo -- backbone restaurado"

    # Ahora que NM corre, materializar los perfiles desde la DB (incluye
    # los importados desde iwd). Idempotente: si el perfil ya esta y
    # coincide, no lo toca.
    if [[ -f "${STATE_DIR}/networks.tsv" ]]; then
        info "sincronizando perfiles NM desde la DB..."
        networks_sync || warn "networks_sync fallo -- NM arrancara sin los perfiles importados"
    fi

    echo "" >&2
    info "devices en NM tras sync:"
    nmcli dev status 2>&1 >&2 || true
    echo "" >&2
    info "conexiones activas ahora:"
    local _act
    _act="$(nmcli -t -f NAME,DEVICE,TYPE con show --active 2>&1 || true)"
    if [[ -n "${_act}" ]]; then
        printf '%s\n' "${_act}" >&2
    else
        printf '  (ninguna)\n' >&2
    fi

    # Reset de las antenas WiFi: al parar iwd las interfaces quedan en un
    # estado que NM no re-descubre (no dispara evento de re-deteccion).
    # SOLO 'up' + 'managed yes': 'ip link set down' rompe la USB (el bus
    # USB se resetea y wlx1 desaparece de /sys). Con UseDefaultInterface
    # / DefaultInterface=false en /etc/iwd/main.conf, ademas, iwd ya no
    # destruye la iface al pararse, asi que basta con devolverla a NM.
    local _w _if
    for _w in /sys/class/net/*/wireless; do
        [ -d "${_w}" ] || continue
        _if="${_w%/wireless}"; _if="${_if##*/}"
        info "devolviendo ${_if} a NM..."
        ip link set "${_if}" up 2>/dev/null || true
        nmcli dev set "${_if}" managed yes 2>/dev/null || true
    done

    # Scan + tabla de intentos. Muestra: que redes ve NM ahora, y cada
    # 2s por 20s, el estado de cada antena + a que red intenta conectar.
    # Con eso el usuario ve en vivo si NM esta intentando y en que falla.
    echo "" >&2
    info "escaneando redes visibles (nmcli dev wifi list)..."
    nmcli dev wifi list 2>&1 >&2 || warn "scan fallo (NM sin antenas?)"

    echo "" >&2
    info "siguiendo intentos de conexion (20s)..."
    printf '  %-10s %-14s %-30s %s\n' "IFACE" "STATE" "CONN" "IP" >&2
    local _t=0 _any_conn=0
    while [[ "${_t}" -lt 20 ]]; do
        _any_conn=0
        for _w in /sys/class/net/*/wireless; do
            [[ -d "${_w}" ]] || continue
            _if="${_w%/wireless}"; _if="${_if##*/}"
            local _st _cn _ip
            _st="$(nmcli -t -f DEVICE,STATE dev status 2>/dev/null | awk -F: -v i="${_if}" '$1==i {print $2; exit}')"
            _cn="$(nmcli -t -f DEVICE,CONNECTION dev status 2>/dev/null | awk -F: -v i="${_if}" '$1==i {print $2; exit}')"
            _ip="$(ip -4 -o addr show "${_if}" 2>/dev/null | awk '{print $4}' | head -1)"
            printf '  %-10s %-14s %-30s %s\n' "${_if}" "${_st:-?}" "${_cn:-—}" "${_ip:-—}" >&2
            [[ -n "${_cn}" ]] && _any_conn=1
            [[ -n "${_ip}" ]] && { ok "IP asignada: ${_if} ${_ip}"; _t=999; break; }
        done
        [[ "${_t}" -eq 999 ]] && break
        sleep 2
        _t=$((_t + 2))
    done

    if [[ "${_t}" -ne 999 ]]; then
        echo "" >&2
        warn "ninguna antena obtuvo IP en 20s"
        echo "" >&2
        info "ultimos 8 eventos de NetworkManager (causa del fallo):"
        journalctl -u NetworkManager -n 8 --no-pager 2>&1 >&2 || true
    fi

    rm -f "${FALLBACK_STATE}"
}
