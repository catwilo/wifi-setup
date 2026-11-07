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

    # Reescribe main.conf mergeando las claves canonicas en la PRIMERA
    # ocurrencia de cada seccion. El algoritmo anterior las anadia al
    # final del archivo, produciendo dos [General] (la primera vacia);
    # iwd lee solo la primera y descarta la segunda -> DHCP off -> sin IP
    # tras fallback on. Nuevo algoritmo: nunca duplica una seccion; si
    # no existe, la crea al final; si existe, inserta las claves dentro.
    # DefaultInterface=?* se elimina siempre: es sintaxis invalida para
    # iwd y rompe el bind en algunos drivers.
    python3 - "${conf}" "${tmp}" <<'PY_IWD_CONF'
import os, sys

src, dst = sys.argv[1], sys.argv[2]

CANONICAL = {
    "General": [("EnableNetworkConfiguration", "true")],
    "Network": [("NameResolvingService", "systemd")],
}
MANAGED_KEYS = {"EnableNetworkConfiguration", "NameResolvingService", "DefaultInterface"}

sections = []
cur_name, cur_lines = None, []
if os.path.exists(src):
    with open(src, "r", encoding="utf-8", errors="replace") as f:
        for raw in f:
            line = raw.rstrip("\n")
            s = line.strip()
            if s.startswith("[") and s.endswith("]"):
                if cur_name is not None or cur_lines:
                    sections.append((cur_name, cur_lines))
                cur_name, cur_lines = s[1:-1].strip(), []
            else:
                cur_lines.append(line)
    if cur_name is not None or cur_lines:
        sections.append((cur_name, cur_lines))

cleaned = []
for name, lines in sections:
    out = []
    for l in lines:
        s = l.strip()
        if not s or s.startswith("#"):
            out.append(l)
            continue
        key = s.split("=", 1)[0].strip()
        if key in MANAGED_KEYS:
            continue
        out.append(l)
    cleaned.append((name, out))

def find_first(name):
    for i, (n, _) in enumerate(cleaned):
        if n == name:
            return i
    return -1

for sec_name, kvs in CANONICAL.items():
    idx = find_first(sec_name)
    if idx == -1:
        cleaned.append((sec_name, [f"{k}={v}" for k, v in kvs]))
    else:
        n, lines = cleaned[idx]
        for k, v in kvs:
            lines.append(f"{k}={v}")
        cleaned[idx] = (n, lines)

with open(dst, "w", encoding="utf-8") as f:
    for name, lines in cleaned:
        if not any(l.strip() for l in lines):
            continue
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
# _fallback_fix_routes -- garantiza subred + default en la antena WiFi
# activa tras fallback on. Idempotente.
#
# Motivo: iwd con algunos drivers (brcmsmac) asigna IP via su DHCP pero
# no instala la ruta de subred. Sin ella, el kernel rechaza la default
# con "Nexthop has invalid gateway" y el nodo queda sin internet aunque
# la IP este asignada.
_fallback_fix_routes() {
    local w iface="" ipx cidr prefix a b c d mask ipn netn subnet gw_fallback gw current_gw
    for w in /sys/class/net/*/wireless; do
        [ -d "${w}" ] || continue
        w="${w%/wireless}"; w="${w##*/}"
        ipx="$(ip -4 -o addr show "${w}" 2>/dev/null | awk '{print $4}' | head -1)"
        if [[ -n "${ipx}" ]]; then
            iface="${w}"
            break
        fi
    done
    if [[ -z "${iface}" ]]; then
        info "fix-routes: ninguna antena con IP, nada que hacer"
        return 0
    fi

    cidr="${ipx}"
    prefix="${cidr#*/}"
    cidr="${cidr%/*}"
    a="${cidr%%.*}"; cidr="${cidr#*.}"
    b="${cidr%%.*}"; cidr="${cidr#*.}"
    c="${cidr%%.*}"; d="${cidr##*.}"

    case "${prefix}" in
        24) subnet="${a}.${b}.${c}.0/24"; gw_fallback="${a}.${b}.${c}.1" ;;
        16) subnet="${a}.${b}.0.0/16";    gw_fallback="${a}.${b}.0.1" ;;
        8)  subnet="${a}.0.0.0/8";        gw_fallback="${a}.0.0.1" ;;
        *)
            mask=$(( (0xFFFFFFFF << (32-prefix)) & 0xFFFFFFFF ))
            ipn=$(( (a<<24)+(b<<16)+(c<<8)+d ))
            netn=$(( ipn & mask ))
            subnet="$(( (netn>>24)&255 )).$(( (netn>>16)&255 )).$(( (netn>>8)&255 )).$(( netn&255 ))/${prefix}"
            gw_fallback=""
            ;;
    esac

    if ip -4 route show | grep -qF "${subnet} dev ${iface}"; then
        info "fix-routes: subred ${subnet} ya presente en ${iface}"
    else
        if ip route add "${subnet}" dev "${iface}" 2>/dev/null; then
            ok "fix-routes: subred ${subnet} anadida en ${iface}"
        else
            warn "fix-routes: no se pudo anadir subred ${subnet} en ${iface}"
        fi
    fi

    gw="$(iwctl station "${iface}" show 2>/dev/null \
        | awk -F': ' '/Gateway/ {gsub(/ /,"",$2); print $2; exit}')"
    [[ -z "${gw}" ]] && gw="${gw_fallback}"
    [[ -n "${gw}" ]] || { info "fix-routes: sin gateway conocido, default no tocada"; return 0; }

    current_gw="$(ip -4 route show default dev "${iface}" 2>/dev/null | awk '{print $3; exit}')"
    if [[ -n "${current_gw}" ]]; then
        info "fix-routes: default ya presente via ${current_gw}"
        return 0
    fi
    if ip route add default via "${gw}" dev "${iface}" 2>/dev/null; then
        ok "fix-routes: default via ${gw} dev ${iface} anadida"
    elif ip route add default via "${gw}" dev "${iface}" onlink 2>/dev/null; then
        ok "fix-routes: default via ${gw} dev ${iface} onlink anadida"
    else
        warn "fix-routes: no se pudo anadir default via ${gw} dev ${iface}"
    fi
}

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
        if ! _fallback_wait_ip 45; then
            err "iwd no obtuvo IP en 45s (ya estaba en fallback)"
            info "no se toca NM -- estado actual preservado"
            return 1
        fi
        _fallback_fix_routes || true
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

    if ! _fallback_wait_ip 45; then
        err "iwd no obtuvo IP en 45s -- revirtiendo a NetworkManager"
        warn "el nodo NO queda en fallback: NM restaurado con internet"
        fallback_off || err "rollback tambien fallo -- intervencion manual"
        return 1
    fi
    _fallback_fix_routes || true

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

    section "Volviendo a NetworkManager (backbone, atomico)"

    # ------------------------------------------------------------------
    # Paso 1: preparar NM (unmask + enable). No lo arrancamos aun.
    # ------------------------------------------------------------------
    if [[ "$(systemctl is-enabled NetworkManager 2>/dev/null || true)" == "masked" ]]; then
        info "desenmascarando NetworkManager..."
        systemctl unmask NetworkManager 2>/dev/null || true
    fi
    systemctl enable NetworkManager 2>/dev/null || true

    # ------------------------------------------------------------------
    # Paso 2: importar perfiles de iwd ANTES de parar iwd. Solo lee
    # archivos /var/lib/iwd/*.psk + escribe TSV, no requiere red.
    # ------------------------------------------------------------------
    if command -v iwctl >/dev/null 2>&1 && systemctl is-active iwd >/dev/null 2>&1; then
        info "importando redes conocidas por iwd a la DB..."
        networks_pull_iwd 2>/dev/null || warn "networks_pull_iwd fallo -- continuando"
    fi

    # ------------------------------------------------------------------
    # Paso 3: parar iwd. Esta es la unica ventana en la que el nodo
    # puede quedarse sin gestor. Todo lo que sigue es rapido.
    # ------------------------------------------------------------------
    info "parando iwd..."
    systemctl stop iwd 2>/dev/null || true

    # ------------------------------------------------------------------
    # Paso 4: arrancar NM. Si falla, rollback a iwd.
    # ------------------------------------------------------------------
    info "arrancando NetworkManager..."
    if ! systemctl start NetworkManager 2>/dev/null; then
        err "NetworkManager no pudo arrancar"
        _fallback_off_rollback "NM start fallo"
        return 1
    fi
    if ! systemctl is-active NetworkManager >/dev/null 2>&1; then
        err "NetworkManager no quedo activo"
        _fallback_off_rollback "NM no activo"
        return 1
    fi

    # ------------------------------------------------------------------
    # Paso 5: devolver interfaces WiFi a NM (up + managed yes).
    # Con iwd parado, las ifaces pueden haber quedado en estado raro.
    # ------------------------------------------------------------------
    local _w _if
    for _w in /sys/class/net/*/wireless; do
        [ -d "${_w}" ] || continue
        _if="${_w%/wireless}"; _if="${_if##*/}"
        ip link set "${_if}" up 2>/dev/null || true
        nmcli dev set "${_if}" managed yes 2>/dev/null || true
    done

    # ------------------------------------------------------------------
    # Paso 6: esperar IP. 45s con progreso cada 3s.
    # ------------------------------------------------------------------
    info "esperando IP en alguna antena WiFi (max 45s)..."
    printf '  %-10s %-14s %-24s %s\n' "IFACE" "STATE" "CONN" "IP" >&2
    local _ip="" _waited=0
    while [[ "${_waited}" -lt 45 ]]; do
        _ip=""
        for _w in /sys/class/net/*/wireless; do
            [ -d "${_w}" ] || continue
            _if="${_w%/wireless}"; _if="${_if##*/}"
            local _st _cn _ipx
            _st="$(nmcli -t -f DEVICE,STATE dev status 2>/dev/null \
                | awk -F: -v i="${_if}" '$1==i {print $2; exit}')"
            _cn="$(nmcli -t -f DEVICE,CONNECTION dev status 2>/dev/null \
                | awk -F: -v i="${_if}" '$1==i {print $2; exit}')"
            _ipx="$(ip -4 -o addr show "${_if}" 2>/dev/null \
                | awk '{print $4}' | head -1)"
            printf '  %-10s %-14s %-24s %s\n' \
                "${_if}" "${_st:-?}" "${_cn:--}" "${_ipx:--}" >&2
            [[ -n "${_ipx}" ]] && { _ip="${_ipx}"; break; }
        done
        [[ -n "${_ip}" ]] && break
        sleep 3
        _waited=$((_waited + 3))
    done

    if [[ -z "${_ip}" ]]; then
        warn "ninguna antena obtuvo IP en 45s"
        _fallback_off_rollback "sin IP tras 45s"
        return 1
    fi
    ok "NM activo, IP asignada: ${_ip}"

    # ------------------------------------------------------------------
    # Paso 7: iwd disable. Ya no hace falta.
    # ------------------------------------------------------------------
    systemctl disable iwd 2>/dev/null || true

    # ------------------------------------------------------------------
    # Paso 8: sincronizar perfiles NM desde la DB (incluye los importados
    # de iwd). Idempotente: si ya coinciden, no toca.
    # ------------------------------------------------------------------
    if [[ -f "${STATE_DIR}/networks.tsv" ]]; then
        info "sincronizando perfiles NM desde la DB..."
        networks_sync 2>/dev/null || warn "networks_sync fallo (NM tiene sus propios perfiles)"
    fi

    # ------------------------------------------------------------------
    # Paso 9: fallback.state ya no aplica.
    # ------------------------------------------------------------------
    rm -f "${FALLBACK_STATE}"

    ok "NetworkManager activo -- backbone restaurado"
}

# _fallback_off_rollback <reason> -- restaura iwd cuando fallback_off
# falla a mitad. El nodo queda en el estado previo (iwd al mando).
_fallback_off_rollback() {
    local reason="$1"
    err "fallback_off rollback: ${reason}"

    info "restaurando iwd..."
    systemctl unmask iwd 2>/dev/null || true
    systemctl enable iwd 2>/dev/null || true
    systemctl start iwd 2>/dev/null || true

    if ! systemctl is-active iwd >/dev/null 2>&1; then
        err "iwd NO arranco -- nodo sin red, revisar manualmente"
        err "  sudo journalctl -u iwd -n 40"
        err "  sudo journalctl -u NetworkManager -n 40"
        return 1
    fi
    ok "iwd restaurado (gestor anterior)"

    info "parando NetworkManager (rollback)..."
    systemctl stop NetworkManager 2>/dev/null || true
    systemctl disable NetworkManager 2>/dev/null || true

    err "fallback_off fallo. Estado actual: iwd al mando."
    err "Diagnostico: journalctl -u NetworkManager -n 40"
    return 1
}
